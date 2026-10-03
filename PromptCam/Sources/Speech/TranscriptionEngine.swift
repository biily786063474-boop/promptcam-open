import AVFoundation
import Observation
import Speech

/// iOS 26 `SpeechAnalyzer` 的封装：纯本地、低延迟、无时长限制。
///
/// 不做 SFSpeechRecognizer 回退——旧引擎每约 60 秒必须重启识别任务，
/// 重启瞬间的丢词会让跟读锚点跳变，长口播体验明显退化。
@Observable
final class TranscriptionEngine: @unchecked Sendable {

    enum Status: Equatable {
        case idle
        case preparing
        case downloading(Double)
        case running
        case unsupported(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .downloading: return true
            default: return false
            }
        }
    }

    private(set) var status: Status = .idle

    /// 已定稿文本的**尾部**（有界）。对齐只看最近几十个字，
    /// 完整累积会让长录制的字符串拼接退化成 O(n²)。
    @ObservationIgnored private var finalizedTail = ""
    private(set) var volatileText = ""

    /// 交给对齐算法的文本：定稿尾部 + 当前未定稿片段
    var recentTranscript: String { finalizedTail + volatileText }

    /// 尾部保留长度，需大于对齐器的 tailCharacters
    private static let tailLimit = 160

    /// 识别结果更新。参数：全文、本段音频时间范围、是否已定稿。
    /// 在主线程回调。
    var onUpdate: ((String, CMTimeRange, Bool) -> Void)?

    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var transcriber: SpeechTranscriber?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private let pipeline = AudioPipeline()
    /// 麦克风直采路径的样本游标，每次 start 归零（见 `append(pcm:)`）
    @ObservationIgnored private var micSamplePosition: Int64 = 0

    /// `append` 在采集队列调用，continuation 必须加锁访问。
    /// 锁的存取一律走下面三个同步方法 —— NSLock 不能跨 await 持有。
    @ObservationIgnored private let contLock = NSLock()
    @ObservationIgnored private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    private func setContinuation(_ c: AsyncStream<AnalyzerInput>.Continuation?) {
        contLock.lock(); defer { contLock.unlock() }
        continuation = c
    }

    private func currentContinuation() -> AsyncStream<AnalyzerInput>.Continuation? {
        contLock.lock(); defer { contLock.unlock() }
        return continuation
    }

    private func takeContinuation() -> AsyncStream<AnalyzerInput>.Continuation? {
        contLock.lock(); defer { contLock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }

    // MARK: - 生命周期

    func start(locale: Locale) async {
        await stop()
        micSamplePosition = 0       // 时间戳必须从头开始，否则新一轮识别一开口就倒退
        await set(.preparing)

        guard SpeechTranscriber.isAvailable else {
            await set(.unsupported(String(localized: "这台设备不支持本地语音识别")))
            return
        }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            await set(.unsupported(String(localized: "暂不支持该语言的跟读")))
            return
        }

        let module = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            // volatileResults = 边说边出增量；fastResults = 牺牲一点精度换最低延迟。
            // 跟读要的是"话音刚落字就跟上"，精度由对齐算法的拼音容错去补。
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]     // 每段带时间范围，供时间轴导出
        )

        guard await ensureModelInstalled(for: module) else { return }

        guard let format = await SpeechAnalyzer
            .bestAvailableAudioFormat(compatibleWith: [module]) else {
            await set(.failed(String(localized: "拿不到兼容的音频格式")))
            return
        }
        pipeline.setTarget(format)

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let engine = SpeechAnalyzer(modules: [module])

        // 整个循环跑在主线程：每条结果都 await MainActor.run 会多一次调度跳转，
        // 而结果每 100ms 就来一条，跟读对这点延迟很敏感。
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in module.results {
                    guard let self else { return }
                    let piece = String(result.text.characters)

                    if result.isFinal {
                        self.finalizedTail = String(
                            (self.finalizedTail + piece).suffix(Self.tailLimit)
                        )
                        self.volatileText = ""
                    } else {
                        self.volatileText = piece
                    }
                    self.onUpdate?(self.recentTranscript, result.range, result.isFinal)
                }
            } catch {
                self?.status = .failed(String(localized: "识别中断：\(error.localizedDescription)"))
            }
        }

        analyzer = engine
        transcriber = module

        // **顺序很关键**：先把输入通道交出去，再启动分析。
        // start(inputSequence:) 消费的就是这个 stream，它不保证立即返回；
        // 若等它返回后才设 continuation，append 会一直在 guard 处丢帧，
        // 一帧音频都进不去，识别永远没有结果。
        setContinuation(cont)
        await set(.running)
        print("[asr] running, format=\(format.sampleRate)Hz ch=\(format.channelCount)")

        do {
            try await engine.start(inputSequence: stream)
            print("[asr] analyzer.start returned")
        } catch {
            print("[asr] start failed: \(error)")
            setContinuation(nil)
            resultsTask?.cancel()
            resultsTask = nil
            await set(.failed(String(localized: "识别启动失败：\(error.localizedDescription)")))
        }
    }

    func stop() async {
        let cont = takeContinuation()
        cont?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        await set(.idle)
    }

    /// 清空已识别文本（换脚本 / 重新开始时）
    @MainActor
    func resetTranscript() {
        finalizedTail = ""
        volatileText = ""
    }

    // MARK: - 喂音频（采集队列调用）

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let cont = currentContinuation(),
              let buffer = pipeline.convert(sampleBuffer) else { return }

        // bufferStartTime 用采集时间戳，让识别结果的 audioTimeRange
        // 与视频时间轴同源 —— 这是时间轴导出能成立的前提
        cont.yield(AnalyzerInput(buffer: buffer,
                                 bufferStartTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    /// 麦克风直采入口（悬浮提词的后台跟读走这条）。
    ///
    /// **时间戳自己按样本数累加，不用 AVAudioTime 的 hostTime。**
    /// tap 回调给的 `AVAudioTime` 在部分设备/音频路由下 `isHostTimeValid`
    /// 是 false，拿它去 `CMClockMakeHostTimeFromSystemUnits` 会得到非法或
    /// 倒退的时间戳，`SpeechAnalyzer` 直接报 "Audio input timestamps…"
    /// 然后中断识别（真机踩到过）。
    ///
    /// 代价是这条路的时间戳不与真实时钟对齐，但悬浮提词不导出字幕，用不到。
    func append(pcm buffer: AVAudioPCMBuffer) {
        guard let cont = currentContinuation(),
              let converted = pipeline.convert(buffer) else { return }

        let pts = CMTime(value: micSamplePosition,
                         timescale: CMTimeScale(converted.format.sampleRate))
        micSamplePosition += Int64(converted.frameLength)
        cont.yield(AnalyzerInput(buffer: converted, bufferStartTime: pts))
    }

    // MARK: - 模型

    private func ensureModelInstalled(for module: SpeechTranscriber) async -> Bool {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return true
        case .unsupported:
            await set(.unsupported(String(localized: "这台设备没有该语言的识别模型")))
            return false
        case .supported, .downloading:
            do {
                guard let request = try await AssetInventory
                    .assetInstallationRequest(supporting: [module]) else { return true }

                let progressTask = Task { [weak self] in
                    while !Task.isCancelled {
                        let f = request.progress.fractionCompleted
                        await self?.set(.downloading(f))
                        if f >= 1.0 { break }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
                try await request.downloadAndInstall()
                progressTask.cancel()
                return true
            } catch {
                await set(.failed(String(localized: "语言模型下载失败：\(error.localizedDescription)")))
                return false
            }
        @unknown default:
            return true
        }
    }

    @MainActor
    private func set(_ new: Status) {
        status = new
    }
}
