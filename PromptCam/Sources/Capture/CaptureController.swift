import AVFoundation
import Observation

enum CaptureMode: String {
    case single     // 单摄
    case dual       // 前后双摄画中画
}

/// 采集队列读的状态镜像。
///
/// `@Observable` 属性的 getter 会注册观察依赖，**不能在非主线程读**，
/// 而 `captureOutput` 每帧都要知道当前模式和主副关系。
/// 所以这些值单独存一份带锁的副本，由主线程同步过来。
private final class CaptureFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _mode: CaptureMode = .single
    private var _frontIsFullscreen = true
    private var _corner: PiPCorner = .topTrailing
    private var _size: PiPSize = .medium
    private var _aspect: PiPAspect = .portrait

    var mode: CaptureMode {
        lock.lock(); defer { lock.unlock() }; return _mode
    }
    var frontIsFullscreen: Bool {
        lock.lock(); defer { lock.unlock() }; return _frontIsFullscreen
    }
    var corner: PiPCorner {
        lock.lock(); defer { lock.unlock() }; return _corner
    }
    var size: PiPSize {
        lock.lock(); defer { lock.unlock() }; return _size
    }
    var aspect: PiPAspect {
        lock.lock(); defer { lock.unlock() }; return _aspect
    }

    func update(mode: CaptureMode? = nil,
                frontIsFullscreen: Bool? = nil,
                corner: PiPCorner? = nil,
                size: PiPSize? = nil,
                aspect: PiPAspect? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let mode { _mode = mode }
        if let frontIsFullscreen { _frontIsFullscreen = frontIsFullscreen }
        if let corner { _corner = corner }
        if let size { _size = size }
        if let aspect { _aspect = aspect }
    }
}

/// 相机会话编排。
///
/// **硬约束（勿改）**：麦克风只有 AVCaptureSession 这一个采集源，音频从
/// `AVCaptureAudioDataOutput` 出来后分两路——一路进 AVAssetWriter 写盘，
/// 一路经 `onAudioSampleBuffer` 旁路给语音识别。
/// 绝不能再起 AVAudioEngine 单独抓麦克风：会和本 session 争抢 audio session，
/// 表现为录音断流或识别收不到数据。
///
/// `@unchecked Sendable`：跨队列访问的可变状态由锁或串行队列保护，手动保证线程安全。
@Observable
final class CaptureController: NSObject, @unchecked Sendable {

    // MARK: - UI 状态

    var isSessionRunning = false
    var errorMessage: String?
    var permissionDenied = false

    /// 单摄 / 双摄
    private(set) var mode: CaptureMode = .single {
        didSet { flags.update(mode: mode) }
    }
    /// 单摄模式下用哪个摄像头
    var cameraPosition: AVCaptureDevice.Position = .front
    /// 双摄模式下前置是否占全屏（false = 后置全屏、前置在小窗）
    var frontIsFullscreen = true {
        didSet { flags.update(frontIsFullscreen: frontIsFullscreen) }
    }
    /// 小窗停靠的角
    var pipCorner: PiPCorner = Defaults.corner {
        didSet {
            flags.update(corner: pipCorner)
            UserDefaults.standard.set(pipCorner.rawValue, forKey: Defaults.cornerKey)
        }
    }
    /// 小窗大小
    var pipSize: PiPSize = Defaults.size {
        didSet {
            flags.update(size: pipSize)
            UserDefaults.standard.set(pipSize.rawValue, forKey: Defaults.sizeKey)
        }
    }
    /// 小窗宽高比
    var pipAspect: PiPAspect = Defaults.aspect {
        didSet {
            flags.update(aspect: pipAspect)
            UserDefaults.standard.set(pipAspect.rawValue, forKey: Defaults.aspectKey)
        }
    }

    /// 小窗偏好的读写。放静态区，避免属性初始化时碰 self。
    private enum Defaults {
        static let cornerKey = "pip.corner"
        static let sizeKey   = "pip.size"
        static let aspectKey = "pip.aspect"

        static var corner: PiPCorner {
            (UserDefaults.standard.string(forKey: cornerKey)).flatMap(PiPCorner.init) ?? .topTrailing
        }
        static var size: PiPSize {
            (UserDefaults.standard.string(forKey: sizeKey)).flatMap(PiPSize.init) ?? .medium
        }
        static var aspect: PiPAspect {
            (UserDefaults.standard.string(forKey: aspectKey)).flatMap(PiPAspect.init) ?? .portrait
        }
    }

    /// 前置录制是否镜像输出。默认开——口播自拍所见即所得。
    var mirrorFrontOutput = true

    var isDualSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }
    /// 最近一次配置后的硬件占用（双摄时有意义，>1 跑不动）
    private(set) var hardwareCost: Float = 0

    /// 采集队列专用的状态副本
    @ObservationIgnored private let flags = CaptureFlags()

    // MARK: - 预览层
    //
    // 主副互换只是换这两层在 UI 里的位置，不动任何 connection，所以是瞬时的。

    // 预览层**不跨会话复用**。AVCaptureVideoPreviewLayer 的 attach/detach 状态机
    // 不支持在「普通 session ↔ MultiCam session」之间改挂，硬改会命中内部断言
    // （figCaptureSession == NULL / == _internal->figCaptureSession）直接闪退。
    // 每次重建会话就换一对全新的 layer，旧的随旧会话一起释放。

    /// 单摄模式承载唯一那一路；双摄模式恒为「前置」
    private(set) var previewA = AVCaptureVideoPreviewLayer()
    /// 仅双摄模式使用，恒为「后置」
    private(set) var previewB = AVCaptureVideoPreviewLayer()

    var fullscreenLayer: AVCaptureVideoPreviewLayer {
        (mode == .dual && !frontIsFullscreen) ? previewB : previewA
    }
    var pipPreviewLayer: AVCaptureVideoPreviewLayer {
        frontIsFullscreen ? previewB : previewA
    }

    // MARK: - 会话

    /// 只在 sessionQueue 上换实例，UI 不直接读它（UI 用 previewLayer），故不参与观察
    @ObservationIgnored private(set) var session: AVCaptureSession = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "promptcam.session")
    private let videoQueue   = DispatchQueue(label: "promptcam.video")
    private let audioQueue   = DispatchQueue(label: "promptcam.audio")

    /// 单摄：唯一输出。双摄：A=前置 B=后置
    private var videoOutputA = AVCaptureVideoDataOutput()
    private var videoOutputB = AVCaptureVideoDataOutput()
    private var audioOutput  = AVCaptureAudioDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?

    // MARK: - 录制

    /// 录制生命周期委托给 RecordingCoordinator
    let recording = RecordingCoordinator()

    private let compositor = PiPCompositor()
    private let auxLock = NSLock()
    private var latestAuxBuffer: CVPixelBuffer?

    /// 音频旁路给语音识别。这里始终投递，但识别引擎只在录制期间开启——
    /// 没开时 TranscriptionEngine 会在第一道 guard 直接丢掉，不做重采样，零开销。
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    override init() {
        super.init()
        // 属性初始化不会触发 didSet，这里把持久化下来的小窗偏好补同步给采集队列
        flags.update(corner: pipCorner, size: pipSize, aspect: pipAspect)
        recording.onError = { [weak self] message in self?.report(message) }
    }

    // MARK: - 权限

    func requestPermissions() async -> Bool {
        let cam = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let ok = cam && mic
        await MainActor.run { self.permissionDenied = !ok }
        return ok
    }

    // MARK: - 配置

    func configure(mode newMode: CaptureMode) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if newMode == .dual, !AVCaptureMultiCamSession.isMultiCamSupported {
                self.report(String(localized: "这台设备不支持前后双摄"))
                return
            }

            if self.session.isRunning { self.session.stopRunning() }

            // 换模式要整体重建：MultiCam 会话即便只跑一路也按双路计 hardwareCost，
            // 单摄时用普通 session 更省电。预览层随会话一起换新，不做改挂。
            let built: Built? = (newMode == .dual)
                ? self.buildDualSession()
                : self.buildSingleSession()

            guard let built else { return }

            self.session = built.session
            // 先同步给采集队列，再更新 UI —— 第一帧可能早于主线程回调到达
            self.flags.update(mode: newMode)

            built.session.startRunning()
            let running = built.session.isRunning
            let cost = built.session.hardwareCost
            if newMode == .dual { print("[dual] 3/3 running=\(running)") }

            Task { @MainActor in
                // 换上新预览层，旧的连同旧会话一起释放
                self.previewA = built.previewA
                self.previewB = built.previewB ?? AVCaptureVideoPreviewLayer()
                self.mode = newMode
                self.hardwareCost = cost
                self.isSessionRunning = running
            }

            // hardwareCost > 1 时会话跑不起来，但不会抛错，只会黑屏。必须说清楚。
            if newMode == .dual, !running {
                self.report(cost > 1
                    ? String(localized: "双摄硬件负载超限（\(String(format: "%.2f", cost))），已退回单摄")
                    : String(localized: "双摄启动失败，已退回单摄"))
                self.configure(mode: .single)
            }
        }
    }

    /// 一次构建的产物：会话 + 与之绑定的全新预览层
    private struct Built {
        let session: AVCaptureSession
        let previewA: AVCaptureVideoPreviewLayer
        let previewB: AVCaptureVideoPreviewLayer?
    }

    // MARK: 单摄

    private func buildSingleSession() -> Built? {
        let s = AVCaptureSession()
        s.beginConfiguration()
        s.sessionPreset = .hd1920x1080

        guard let device = Self.camera(at: cameraPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              s.canAddInput(input) else {
            s.commitConfiguration()
            report(String(localized: "找不到可用的摄像头"))
            return nil
        }
        s.addInput(input)
        videoDeviceInput = input

        addAudio(to: s)

        videoOutputA = AVCaptureVideoDataOutput()
        videoOutputA.alwaysDiscardsLateVideoFrames = true
        videoOutputA.setSampleBufferDelegate(self, queue: videoQueue)
        if s.canAddOutput(videoOutputA) { s.addOutput(videoOutputA) }

        if let conn = videoOutputA.connection(with: .video) {
            apply(rotationAndMirror: conn, isFront: device.position == .front)
        }
        // 必须在 commit 之前挂好，理由见 makeAttachedPreview
        let layer = makeAttachedPreview(for: s, port: nil)

        s.commitConfiguration()
        return Built(session: s, previewA: layer, previewB: nil)
    }

    // MARK: 双摄

    private func buildDualSession() -> Built? {
        // MultiCam 只认广角镜头。用 DiscoverySession 的默认结果可能拿到 triple camera，
        // 它未必有 isMultiCamSupported 的 format，接进来就是崩溃。
        guard let front = Self.wideAngleCamera(at: .front),
              let back  = Self.wideAngleCamera(at: .back) else {
            report(String(localized: "双摄需要同时拿到前后广角摄像头"))
            return nil
        }

        // format 必须**先于** canAddInput 设好 —— 兼容性判断依据的就是 activeFormat。
        // 720p 双路是发热与画质的平衡点，1080p 双路 hardwareCost 容易超 1。
        guard Self.applyMultiCamFormat(front, targetWidth: 1280),
              Self.applyMultiCamFormat(back,  targetWidth: 1280) else {
            report(String(localized: "这台设备的摄像头不支持双路采集"))
            return nil
        }

        guard let frontInput = try? AVCaptureDeviceInput(device: front),
              let backInput  = try? AVCaptureDeviceInput(device: back) else {
            report(String(localized: "无法打开前后摄像头"))
            return nil
        }

        let s = AVCaptureMultiCamSession()
        s.beginConfiguration()
        defer { s.commitConfiguration() }

        // 逐个「检查→添加」。绝不能先连着检查两个再连着添加：
        // 第二个 canAddInput 是在第一个尚未占用硬件预算时问的，答案不作数，
        // 而 addInputWithNoConnections 失败时抛的是 ObjC 异常，Swift 接不住。
        // 前置/后置不能靠拼接构句 —— 拼出来的半句没法整句翻译，
        // 两条完整文案分开写
        for (input, isFront) in [(frontInput, true), (backInput, false)] {
            guard s.canAddInput(input) else {
                report(isFront
                       ? String(localized: "无法接入前置摄像头（硬件资源不足）")
                       : String(localized: "无法接入后置摄像头（硬件资源不足）"))
                return nil
            }
            s.addInputWithNoConnections(input)
        }

        videoOutputA = makeDualVideoOutput()
        videoOutputB = makeDualVideoOutput()
        for output in [videoOutputA, videoOutputB] {
            guard s.canAddOutput(output) else {
                report(String(localized: "无法为双摄建立视频输出"))
                return nil
            }
            s.addOutputWithNoConnections(output)
        }

        guard let frontPort = frontInput.ports(for: .video,
                                               sourceDeviceType: front.deviceType,
                                               sourceDevicePosition: .front).first,
              let backPort = backInput.ports(for: .video,
                                             sourceDeviceType: back.deviceType,
                                             sourceDevicePosition: .back).first else {
            report(String(localized: "拿不到摄像头视频端口"))
            return nil
        }

        // 数据输出连接
        for (port, output, isFront) in [(frontPort, videoOutputA, true),
                                        (backPort,  videoOutputB, false)] {
            let conn = AVCaptureConnection(inputPorts: [port], output: output)
            guard s.canAddConnection(conn) else {
                report(String(localized: "无法建立双摄视频连接"))
                return nil
            }
            s.addConnection(conn)
            apply(rotationAndMirror: conn, isFront: isFront)
        }

        addAudio(to: s, withNoConnections: true)

        let fd = CMVideoFormatDescriptionGetDimensions(front.activeFormat.formatDescription)
        let bd = CMVideoFormatDescriptionGetDimensions(back.activeFormat.formatDescription)
        print("[dual] 1/3 io ok front=\(fd.width)x\(fd.height) back=\(bd.width)x\(bd.height) cost=\(s.hardwareCost)")

        // 仍在配置事务内：MultiCam 不做隐式预览连接，必须手动建
        let layerA = makeAttachedPreview(for: s, port: frontPort)
        let layerB = makeAttachedPreview(for: s, port: backPort)
        print("[dual] 2/3 previews attached")

        return Built(session: s, previewA: layerA, previewB: layerB)
    }

    /// 造一个**全新**的预览层并绑定到会话。**必须同步、且在 commitConfiguration 之前调用。**
    ///
    /// 为什么每次都新建而不复用：`AVCaptureVideoPreviewLayer` 的 attach/detach
    /// 状态机不支持在会话之间改挂，无论先解绑与否都会命中内部断言
    /// （attach 侧要求 figCaptureSession == NULL，detach 侧要求两者相等）。
    /// 换新层把这个状态机彻底绕开，旧层随旧会话一起释放。
    ///
    /// 为什么用 main.sync：CALayer 只能主线程碰，而建立连接算配置变更、
    /// 必须落在当前配置事务里。改成 `Task { @MainActor }` 异步做的话，
    /// 它隐式开的配置事务会和采集队列上随后的 startRunning 撞车。
    /// 这里不会死锁——主线程从不同步等待 sessionQueue，依赖是单向的。
    ///
    /// - Parameter port: nil = 单摄（隐式连接）；非 nil = MultiCam（手动连接）
    private func makeAttachedPreview(for s: AVCaptureSession,
                                     port: AVCaptureInput.Port?) -> AVCaptureVideoPreviewLayer {
        var layer: AVCaptureVideoPreviewLayer!
        let work = {
            layer = AVCaptureVideoPreviewLayer()
            layer.videoGravity = .resizeAspectFill

            if let port {
                layer.setSessionWithNoConnection(s)
                let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
                guard s.canAddConnection(conn) else { return }
                s.addConnection(conn)
                // 加入会话后再设方向：未加入时属性查询不可靠
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            } else {
                layer.session = s       // 隐式建连接
                if let conn = layer.connection,
                   conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return layer
    }

    private func makeDualVideoOutput() -> AVCaptureVideoDataOutput {
        let o = AVCaptureVideoDataOutput()
        o.alwaysDiscardsLateVideoFrames = true
        // 合成走 Core Image，BGRA 最省事；单摄不合成所以保留默认 420v
        o.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        o.setSampleBufferDelegate(self, queue: videoQueue)
        return o
    }

    // MARK: 公共装配

    private func addAudio(to s: AVCaptureSession,
                          withNoConnections: Bool = false) {
        guard let mic = AVCaptureDevice.default(for: .audio),
              let micInput = try? AVCaptureDeviceInput(device: mic),
              s.canAddInput(micInput) else {
            report(String(localized: "找不到可用的麦克风"))
            return
        }

        audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)

        if withNoConnections {
            s.addInputWithNoConnections(micInput)
            guard s.canAddOutput(audioOutput) else { return }
            s.addOutputWithNoConnections(audioOutput)
            if let port = micInput.ports(for: .audio,
                                         sourceDeviceType: mic.deviceType,
                                         sourceDevicePosition: .unspecified).first {
                let conn = AVCaptureConnection(inputPorts: [port], output: audioOutput)
                if s.canAddConnection(conn) { s.addConnection(conn) }
            }
        } else {
            s.addInput(micInput)
            if s.canAddOutput(audioOutput) { s.addOutput(audioOutput) }
        }
    }

    private func apply(rotationAndMirror conn: AVCaptureConnection, isFront: Bool) {
        if conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90        // 竖屏
        }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = isFront && mirrorFrontOutput
        }
    }

    /// 返回是否成功切到一个支持双路采集的 format。失败说明这台设备/这颗镜头跑不了双摄。
    private static func applyMultiCamFormat(_ device: AVCaptureDevice, targetWidth: Int32) -> Bool {
        let candidates = device.formats.filter(\.isMultiCamSupported)
        guard !candidates.isEmpty else { return false }

        func width(_ f: AVCaptureDevice.Format) -> Int32 {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription).width
        }
        // 优先精确命中；否则取不超过目标宽度里最大的一个，避免挑到过高分辨率把预算吃爆
        let picked = candidates.first { width($0) == targetWidth }
            ?? candidates.filter { width($0) <= targetWidth }.max { width($0) < width($1) }
            ?? candidates.min { width($0) < width($1) }

        guard let format = picked,
              (try? device.lockForConfiguration()) != nil else { return false }
        device.activeFormat = format
        device.unlockForConfiguration()
        return true
    }

    /// 双摄专用：MultiCam 只在广角镜头上有可用 format
    private static func wideAngleCamera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        ).devices.first
    }

    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera],
            mediaType: .video,
            position: position
        ).devices.first
    }

    // MARK: - 启停

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            let running = self.session.isRunning
            Task { @MainActor in self.isSessionRunning = running }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            Task { @MainActor in self.isSessionRunning = false }
        }
    }

    // MARK: - 切换

    /// 单摄：前后互换（重建 session）。双摄：主副互换（纯 UI，瞬时）
    func flipCamera() {
        if mode == .dual {
            frontIsFullscreen.toggle()
            Haptic.light()
            return
        }
        cameraPosition = (cameraPosition == .front) ? .back : .front
        configure(mode: .single)
    }

    func toggleMode() {
        configure(mode: mode == .single ? .dual : .single)
    }

    func cyclePiPCorner() {
        pipCorner = pipCorner.next
        Haptic.light()
    }

    func refreshMirroring() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            for output in [self.videoOutputA, self.videoOutputB] {
                guard let conn = output.connection(with: .video) else { continue }
                let isFront = conn.inputPorts.contains {
                    $0.sourceDevicePosition == .front
                }
                self.apply(rotationAndMirror: conn, isFront: isFront)
            }
            self.session.commitConfiguration()
        }
    }

    // MARK: - 录制

    func startRecording() {
        guard !recording.isRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }

            let isDual = self.flags.mode == .dual
            let mainOutput = isDual
                ? (self.flags.frontIsFullscreen ? self.videoOutputA : self.videoOutputB)
                : self.videoOutputA

            guard let vs = mainOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov) else {
                self.report(String(localized: "拿不到视频编码参数"))
                return
            }
            guard let asr = self.audioOutput
                    .recommendedAudioSettingsForAssetWriter(writingTo: .mov) else {
                self.report(String(localized: "拿不到音频编码参数"))
                return
            }
            self.recording.begin(videoSettings: vs, audioSettings: asr, pixelBufferInput: isDual)
        }
    }

    func stopRecording() {
        guard recording.isRecording else { return }
        recording.end()
    }

    // MARK: - 工具

    private func report(_ message: String) {
        Task { @MainActor in
            self.errorMessage = message
            Haptic.warning()
        }
    }
}

// MARK: - Sample buffer 分发

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate,
                             AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        if output === audioOutput {
            recording.writer?.append(audio: sampleBuffer)     // 一份写盘
            onAudioSampleBuffer?(sampleBuffer)      // 一份给识别，不受是否录制影响
            return
        }

        guard flags.mode == .dual else {
            recording.writer?.append(video: sampleBuffer)     // 单摄：直接写，不经合成
            return
        }

        // 双摄：主路负责合成落盘，副路只缓存最新一帧
        let mainOutput = flags.frontIsFullscreen ? videoOutputA : videoOutputB
        if output === mainOutput {
            composeAndAppend(sampleBuffer)
        } else if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            auxLock.lock()
            latestAuxBuffer = pb
            auxLock.unlock()
        }
    }

    private func composeAndAppend(_ sb: CMSampleBuffer) {
        guard let w = recording.writer,
              let primary = CMSampleBufferGetImageBuffer(sb),
              let out = w.dequeuePixelBuffer() else { return }

        auxLock.lock()
        let aux = latestAuxBuffer
        auxLock.unlock()

        compositor.compose(primary: primary,
                           secondary: aux,
                           corner: flags.corner,
                           size: flags.size,
                           aspect: flags.aspect,
                           into: out)
        w.append(pixelBuffer: out, at: CMSampleBufferGetPresentationTimeStamp(sb))
    }
}
