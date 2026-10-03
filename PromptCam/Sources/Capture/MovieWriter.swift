import AVFoundation

/// 用 AVAssetWriter 而不是 AVCaptureMovieFileOutput。
///
/// 理由（硬约束，勿改）：MovieFileOutput 拿不到 sample buffer，
/// 而我们必须从同一路音频里分一份出来喂语音识别；同时它也挡住 v2 的分段拼接。
final class MovieWriter {

    enum WriterError: Error {
        case cannotAddInput
        case notWriting
    }

    let url: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput

    /// video / audio 回调来自两个不同的串行队列，append 必须加锁
    private let lock = NSLock()
    private var sessionStarted = false

    /// `finish()` 已经开始收尾。**必须挡在 `append` 前面**：`markInputsFinished()`
    /// 到 `finishWriting` 的完成回调之间，`writer.status` 仍然是 `.writing`
    /// （状态要等异步的 `finishWriting` 回调触发才会变成 `.completed`），
    /// 光靠 `writer.status == .writing` 挡不住——停录那一刻上一批渲染/合成
    /// 产生的 command buffer 可能还有 1~2 个在飞，它们的 completion handler
    /// 几毫秒后才调 `append`，此时 `markAsFinished()` 已经调过，
    /// `AVAssetWriterInput.append` 会抛 `NSInternalInconsistencyException`
    /// 崩溃（"Cannot append ... input is marked as finished"）。
    /// `isReadyForMoreMediaData` 挡不住这个窗口——它是未文档化行为，不能当契约用。
    /// Task 5 复审 C2：两条采集链路共用这个类，旧的同步 AVCapture append
    private var finished = false

    private(set) var startPTS: CMTime = .invalid
    private(set) var lastPTS: CMTime  = .invalid

    /// 双摄合成帧走 adaptor 通道；单摄为 nil，直接 append sample buffer（更省一次拷贝）
    private let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    init(url: URL,
         videoSettings: [String: Any],
         audioSettings: [String: Any],
         pixelBufferInput: Bool = false) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        if pixelBufferInput {
            var attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            if let w = videoSettings[AVVideoWidthKey], let h = videoSettings[AVVideoHeightKey] {
                attrs[kCVPixelBufferWidthKey as String]  = w
                attrs[kCVPixelBufferHeightKey as String] = h
            }
            pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: attrs
            )
        } else {
            pixelAdaptor = nil
        }

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw WriterError.cannotAddInput
        }
        writer.add(videoInput)
        writer.add(audioInput)
    }

    /// 从 adaptor 的池子里借一个输出缓冲。**必须在 start() 之后调用**，
    /// pixelBufferPool 在 startWriting 前是 nil。
    func dequeuePixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelAdaptor?.pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess else {
            return nil
        }
        return pb
    }

    /// 双摄：写入已合成好的一帧
    func append(pixelBuffer: CVPixelBuffer, at pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, writer.status == .writing, let adaptor = pixelAdaptor else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            startPTS = pts
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: pts)
        lastPTS = pts
    }

    func start() {
        writer.startWriting()
    }

    /// 第一帧视频负责开 session —— 音频在此之前到达的一律丢弃，
    /// 否则 writer 会因为 source time 早于 session start 而报错。
    func append(video sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, writer.status == .writing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            startPTS = pts
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sb)
        lastPTS = pts
    }

    func append(audio sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, writer.status == .writing, sessionStarted else { return }
        guard audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sb)
    }

    /// 加锁段单独抽出：NSLock 不能跨 await 持有。
    /// 在锁内把 `finished` 一并置位——见其声明处的注释，这是挡住
    /// 「in-flight completion handler 往已 finish 的 input 里 append」的关键。
    private func markInputsFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard writer.status == .writing else { return false }
        finished = true
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        return true
    }

    /// 返回成品 URL；失败返回 nil（调用方负责报错，不要吞）
    func finish() async -> URL? {
        guard markInputsFinished() else { return nil }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        return writer.status == .completed ? url : nil
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    var failureDescription: String? {
        writer.error?.localizedDescription
    }

    /// 已录时长
    var duration: CMTime {
        guard startPTS.isValid, lastPTS.isValid else { return .zero }
        return CMTimeSubtract(lastPTS, startPTS)
    }
}
