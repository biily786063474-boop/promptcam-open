import AVFoundation
import Observation
import Photos
import UIKit

/// 录制生命周期：writer 创建 → 计时 → 收尾 → 存相册。
///
/// 不负责：会话配置、sample buffer 分发、编码参数的产生（由调用方给）。
///
/// `@unchecked Sendable`：`_writer` 由 `writerLock` 保护，UI 状态只在主线程改。
@Observable
final class RecordingCoordinator: @unchecked Sendable {

    // MARK: - UI 状态（只在主线程改）

    var isRecording = false
    var recordedDuration: TimeInterval = 0
    var lastSavedURL: URL?

    /// 上一段录制第一帧视频的 PTS（秒）。识别结果的时间戳同属采集时钟，
    /// 减掉它就得到「视频内时间」——时间轴导出的基准。
    private(set) var lastRecordingOriginSeconds: Double?

    /// 错误上报。调用方接到后自己决定怎么呈现。
    /// 只允许在构造期赋值一次（`CaptureController.init` 就是这么用的）——
    /// 之后会被采集队列 / 后台 Task 只读地调用，没有同步保护，运行期间再改会有数据竞争。
    @ObservationIgnored var onError: ((String) -> Void)?

    // MARK: - writer

    @ObservationIgnored private let writerLock = NSLock()
    @ObservationIgnored private var _writer: MovieWriter?

    /// 「正在建但还没建完」的占位标记，与 `_writer` 同受 `writerLock` 保护。
    /// 光靠 `_writer == nil` 判断「能不能开始建」是不够的——从判断通过到真的把
    /// 建好的 writer 写回 `_writer` 之间，要跑一次 `MovieWriter(url:...)`（含磁盘 I/O），
    /// 这段时间如果不占位，第二个 `begin()` 会看到 `_writer` 还是 nil 也跟着建。
    /// 见 `reserveSlot()` 里为什么这个坑必须堵在「建 writer 之前」而不是「建完之后」。
    @ObservationIgnored private var _reserving = false

    /// 采集/渲染队列每帧都要读，必须走锁，不能是 @Observable 属性。
    /// 只读——写入只能通过 `reserveSlot` / `commitReservation` / `releaseReservation` /
    /// `takeWriter` 这几个锁内一次性操作，不能对外暴露 setter（见 begin/end 的并发说明）。
    var writer: MovieWriter? {
        writerLock.lock(); defer { writerLock.unlock() }; return _writer
    }

    /// 锁内占位：`_writer == nil && !_reserving` 才通过，通过后立刻置 `_reserving = true`。
    ///
    /// **为什么不能「先建 MovieWriter 再抢占位，输的一方 cancel() 掉」**——这是上一轮的
    /// 实现方式，是个很隐蔽的坑，专门记录一下避免再犯：
    /// - `timestampName()` 曾经是秒级粒度，没有唯一性后缀；
    /// - `isRecording` 在 MainActor 上异步置位，快速双击录制键会让两次 `begin()` 都通过
    ///   调用方的 `guard !recording.isRecording`；
    /// - `sessionQueue` 是**串行**队列，两次 `begin()` 背靠背执行，**确定性地**落在
    ///   同一秒（毫秒级格式化之后是同一毫秒），算出**逐字节相同**的 URL；
    /// - `AVAssetWriter(outputURL:)` 针对一个已经被另一个 writer 占用的 URL 初始化
    ///   **不会报错**，静默成功——于是两个 writer 指向同一个文件；
    /// - 输的那一方调用 `cancel()`，内部 `removeItem(at: url)` 删掉的其实是
    ///   **赢家正在写的那份文件**（URL 相同，不是自己的）——bug 从「留一个空文件」
    ///   变成「静默销毁一段本该成功的录制」，而且普通用户操作（快速双击）就能确定性触发。
    ///
    /// 所以互斥必须堵在**创建 `MovieWriter` 之前**：占位失败就直接返回，压根不会走到
    /// `MovieWriter(url:...)` 那一步，也就没有文件、没有 URL 冲突、不需要 `cancel()`。
    private func reserveSlot() -> Bool {
        writerLock.lock(); defer { writerLock.unlock() }
        guard _writer == nil, !_reserving else { return false }
        _reserving = true
        return true
    }

    /// 建 writer 成功：占位转正。
    private func commitReservation(_ w: MovieWriter) {
        writerLock.lock(); defer { writerLock.unlock() }
        _writer = w
        _reserving = false
    }

    /// 建 writer 失败：必须放开占位，否则这一次失败会把录制功能永久锁死——
    /// 之后所有 `begin()` 调用都会卡在 `reserveSlot()`，因为 `_reserving` 再也不会被清掉。
    private func releaseReservation() {
        writerLock.lock(); defer { writerLock.unlock() }
        _reserving = false
    }

    /// 锁内一次性取出并清空。
    ///
    /// 为什么不能拆成「读一次 + 写一次」两次加锁：中间的窗口会让并发调用 `end()`
    /// （比如用户按停止是主线程，中断回调可能来自另一个队列）
    /// 都拿到同一个 writer，各自 `await w.finish()` 一次——`AVAssetWriter.finishWriting`
    /// 不允许被调用两次，第二次直接抛 `NSInternalInconsistencyException` 崩溃。
    private func takeWriter() -> MovieWriter? {
        writerLock.lock(); defer { writerLock.unlock() }
        let w = _writer
        _writer = nil
        return w
    }

    @ObservationIgnored private var durationTimer: Timer?

    // MARK: - 起止

    /// 建 writer 并开写。可在任意队列调用；UI 状态自己切主线程。
    func begin(videoSettings: [String: Any],
               audioSettings: [String: Any],
               pixelBufferInput: Bool) {
        // 先占位，失败直接退出——不创建任何 MovieWriter，也就没有文件、没有 URL 冲突。
        // 见 reserveSlot() 里为什么这一步必须排在 MovieWriter(url:...) 之前。
        guard reserveSlot() else { return }

        let url = Self.recordingsDirectory()
            .appendingPathComponent("\(Self.timestampName()).mov")
        let w: MovieWriter
        do {
            w = try MovieWriter(url: url,
                                videoSettings: videoSettings,
                                audioSettings: audioSettings,
                                pixelBufferInput: pixelBufferInput)
        } catch {
            releaseReservation()
            onError?(String(localized: "无法开始录制：\(error.localizedDescription)"))
            return
        }

        // start() 放在 commitReservation() 之前：commitReservation 一旦返回，
        // 其他线程经 `writer` 读到的就是这个实例，必须保证那时它已经 start() 过——
        // MovieWriter.dequeuePixelBuffer() 明确要求「必须在 start() 之后调用」，
        // pixelBufferPool 在 startWriting 前是 nil。
        w.start()
        commitReservation(w)

        Task { @MainActor in
            self.isRecording = true
            self.recordedDuration = 0
            UIApplication.shared.isIdleTimerDisabled = true
            self.startDurationTimer()
            Haptic.medium()
        }
    }

    /// 收尾并存相册。幂等：没在录时直接返回。
    func end() {
        guard let w = takeWriter() else { return }

        // 趁 writer 还在，取出录制起点（finish 之后就读不到了）
        let origin = w.startPTS.isValid && w.startPTS.isNumeric
            ? CMTimeGetSeconds(w.startPTS) : nil

        Task { @MainActor in
            self.isRecording = false
            self.stopDurationTimer()
            UIApplication.shared.isIdleTimerDisabled = false
        }

        Task {
            guard let url = await w.finish() else {
                self.onError?(String(localized: "录制收尾失败：\(w.failureDescription ?? String(localized: "未知原因"))"))
                return
            }
            // 起点必须在 lastSavedURL 之前就位：观察者靠后者触发写时间轴
            await MainActor.run {
                self.lastRecordingOriginSeconds = origin
                self.lastSavedURL = url
            }
            await self.saveToPhotoLibrary(url)
        }
    }

    // MARK: - 相册

    private func saveToPhotoLibrary(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            onError?(String(localized: "没有相册写入权限，视频已留在 App 内"))
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .video, fileURL: url, options: nil)
            }
            await MainActor.run { Haptic.success() }
        } catch {
            onError?(String(localized: "存相册失败：\(error.localizedDescription)"))
        }
    }

    // MARK: - 计时

    @MainActor
    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let w = self.writer else { return }
            let d = w.duration
            if d.isValid && d.isNumeric {
                self.recordedDuration = CMTimeGetSeconds(d)
            }
        }
    }

    @MainActor
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - 工具

    static func recordingsDirectory() -> URL {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 毫秒级粒度（不是秒级）：秒级格式化在「串行队列背靠背执行的两次 begin()」
    /// 和「同一秒内 stop 后立刻重新 start」这两条路径下都会算出相同 URL，见
    /// `reserveSlot()` 的说明。`RecordingsStore` 按 `creationDate` 排序、不解析文件名，
    /// 时间轴 sidecar 也是从 movie URL 派生 basename，格式变化不影响这两处。
    private static func timestampName() -> String {
        let f = DateFormatter()
        // 设备语言是阿拉伯语/波斯语这类日历不是公历、数字不是 ASCII 的
        // locale 时，不设 `.locale` 会让 `dateFormat` 按系统 locale 解释，
        // 文件名变成回历年份 + 非 ASCII 数字（`٢٠٢٦٠٨٢٣` 这类）——固定用
        // `en_US_POSIX`，格式化结果只由 `dateFormat` 决定，不随设备语言变化
        // （Apple 官方推荐的「机器可读字符串」locale，`ISO8601DateFormatter`
        // 内部同样这么做）。Task 10 最终审查授权修改（本文件其余部分不动）。
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }
}
