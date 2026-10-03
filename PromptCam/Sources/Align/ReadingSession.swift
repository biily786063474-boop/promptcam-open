import CoreMedia
import Foundation
import Observation
import QuartzCore

/// 把「语音识别」和「跟读对齐」串成一个整体：
/// 采集音频 → 识别 → 对齐 → 当前句号。View 只需要读 `currentSentence` / `isOffScript`。
///
/// 整个类锁在主线程：aligner 的状态机不做并发保护，
/// 跨线程调用会在真机上表现为随机的锚点错乱。
@MainActor
@Observable
final class ReadingSession {

    private(set) var script: ParsedScript = .empty
    /// 朗读到第几句。-1 = 无脚本。（时间轴导出按句走）
    private(set) var currentSentence = -1
    /// 已读到的字符位置（utf16 偏移）。逐字高亮与逐行滚动都看这个。
    private(set) var readOffset = 0
    private(set) var isOffScript = false
    private(set) var confidence: Double = 0

    let speech = TranscriptionEngine()

    /// 本次录制的「原稿句 ↔ 时间」记录，停止录制时落盘成 sidecar
    @ObservationIgnored let timeline = ReadingTimelineRecorder()

    @ObservationIgnored private var aligner: ReadingAligner?

    init() {
        // TranscriptionEngine 保证在主线程回调，这里据此断言隔离
        speech.onUpdate = { [weak self] transcript, range, isFinal in
            MainActor.assumeIsolated {
                self?.handle(transcript, range: range, isFinal: isFinal)
            }
        }
    }

    /// 接上相机的音频旁路。识别只在录制期间开启，未开启时 append 会直接丢弃。
    ///
    /// 闭包在采集队列执行，所以只捕获 TranscriptionEngine（它自己做了线程保护），
    /// 不捕获 self —— session 是主线程隔离的，碰不得。
    func attach(to capture: CaptureController) {
        let engine = speech
        capture.onAudioSampleBuffer = { [weak engine] sampleBuffer in
            engine?.append(sampleBuffer)
        }
    }

    func load(_ parsed: ParsedScript) {
        let languageChanged = parsed.language != script.language
        script = parsed
        aligner = parsed.isEmpty ? nil : ReadingAligner(script: parsed)
        currentSentence = parsed.isEmpty ? -1 : 0
        readOffset = 0
        isOffScript = false
        confidence = 0

        // SpeechTranscriber 在构造时绑定 locale，中途换不了。
        // 正在跟读时换成另一种语言的脚本，必须整个引擎重来一遍；
        // 语言没变就不动，避免无谓的识别中断。
        if languageChanged, !parsed.isEmpty, speech.status == .running {
            Task { await startFollowing() }
        }
    }

    func startFollowing() async {
        guard !script.isEmpty else { return }
        speech.resetTranscript()        // 同为主线程隔离，无需 await
        aligner?.reset(now: CACurrentMediaTime())
        timeline.reset()
        // start 内部会先 stop，所以每次都是以当前脚本语言重建引擎
        await speech.start(locale: script.language.speechLocale)
    }

    func stopFollowing() async {
        await speech.stop()
    }

    /// 用户点了提词面板上的某一行，把锚点拉到那个字符位置
    func jump(toCharOffset offset: Int) {
        guard let aligner else { return }
        // 找到该字符位置对应的第一个 token
        let anchor = script.tokens.firstIndex { $0.offset >= offset } ?? script.tokens.count
        aligner.jump(toToken: anchor, now: CACurrentMediaTime())
        apply(aligner.snapshot)
    }

    // MARK: -

    /// 调用方（TranscriptionEngine.onUpdate）保证在主线程
    private func handle(_ transcript: String, range: CMTimeRange, isFinal: Bool) {
        guard let aligner else { return }
        let snapshot = aligner.consume(transcript, now: CACurrentMediaTime())
        apply(snapshot)

        // 只用定稿结果记时间轴：volatile 会被后续修正，时间不可靠
        guard isFinal, snapshot.sentenceIndex >= 0 else { return }
        let seconds = CMTimeGetSeconds(range.end)
        guard seconds.isFinite else { return }
        timeline.note(sentence: snapshot.sentenceIndex,
                      atSeconds: seconds,
                      confidence: snapshot.confidence,
                      offScript: snapshot.isOffScript)
    }

    private func apply(_ snapshot: AlignmentSnapshot) {
        currentSentence = snapshot.sentenceIndex
        readOffset = script.readOffset(forAnchor: snapshot.tokenAnchor)
        isOffScript = snapshot.isOffScript
        confidence = snapshot.confidence
    }
}
