import SwiftUI
import SwiftData
import UIKit

struct CameraScreen: View {

    @State private var capture  = CaptureController()
    @State private var settings = PrompterSettings()
    /// 语音识别 + 跟读对齐
    @State private var session  = ReadingSession()

    @State private var script: Script?

    /// 两档拍摄模式（单摄 / 双摄）的互斥切换与录制路由。
    /// 建于 `setUpIfNeeded()`（需要 `session` 已存在）。
    @State private var shooting: ShootingModeCoordinator?

    /// 本机录制索引（回看入口用）
    @State private var recordings = RecordingsStore()
    @State private var latestThumbnail: UIImage?

    @State private var showScripts    = false
    @State private var showSettings   = false
    @State private var showRecordings = false
    @State private var showLightPanel = false
    /// 通用提示条。开悬浮提词这类"看不见结果"的操作必须给回馈，
    /// 否则用户点完不知道有没有生效。
    @State private var toast: String?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bgDeep.ignoresSafeArea()

                CameraLayerView(previewLayer: capture.fullscreenLayer)
                    .ignoresSafeArea()
                    .opacity(capture.isSessionRunning ? 1 : 0)
                    .animation(Theme.ease(0.4), value: capture.isSessionRunning)

                // 面板开着时点画面任意处收起它。
                // 故意压在 overlayUI 之下：放上面会吃掉录制按钮那一次点击。
                if showLightPanel {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(Theme.spring) { showLightPanel = false }
                        }
                }

                // 摄像头之上、小窗和 UI 之下：压在提词器上会把字糊掉
                if settings.fillLight {
                    RingLight(level: settings.fillLightLevel,
                              warmth: settings.fillLightWarmth,
                              width: settings.fillLightWidth)
                }

                if shooting?.mode == .dual {
                    PiPWindow(
                        previewLayer: capture.pipPreviewLayer,
                        corner: $capture.pipCorner,
                        size: capture.pipSize,
                        aspect: capture.pipAspect,
                        container: geo.size,
                        topInset: prompterOccupiedHeight(geo) + 10,
                        bottomInset: 168,
                        onSwap: { withAnimation(Theme.spring) { capture.flipCamera() } }
                    )
                }

                overlayUI(geo)

                if let toast {
                    Toast(text: toast)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if case .downloading(let p) = session.speech.status {
                    ModelDownloadOverlay(progress: p)
                }

                if capture.permissionDenied {
                    PermissionOverlay()
                }
            }
        }
        .task { await setUpIfNeeded() }
        .onChange(of: scenePhase) { _, phase in handle(phase) }
        .onChange(of: settings.autoScroll) { _, on in
            guard shooting?.isRecording == true else { return }
            Task {
                if on { await session.startFollowing() }
                else  { await session.stopFollowing() }
            }
        }
        .onChange(of: settings.fillLight) { _, on in
            // 光带只是"看起来白"，真正照亮脸的是背光强度
            if on { ScreenBrightness.boost() } else { ScreenBrightness.restore() }
        }
        .onChange(of: capture.recording.lastSavedURL) { _, url in
            handleSaved(url, origin: capture.recording.lastRecordingOriginSeconds)
        }
        .task(id: recordings.latest?.url) {
            guard let latest = recordings.latest else {
                latestThumbnail = nil
                return
            }
            latestThumbnail = await recordings.thumbnail(for: latest.url)
        }
        .sheet(isPresented: $showScripts) {
            ScriptListView { picked in load(picked) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(settings: settings, capture: capture)
        }
        .sheet(isPresented: $showRecordings) {
            RecordingsView(store: recordings)
        }
        .alert("出错了", isPresented: Binding(
            get: { capture.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    capture.errorMessage = nil
                }
            }
        )) {
            Button("知道了", role: .cancel) {
                capture.errorMessage = nil
            }
        } message: {
            Text(capture.errorMessage ?? "")
        }
    }

    // MARK: - 悬浮 UI

    private func overlayUI(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // 始终显示：设置入口不能依赖"已选脚本"，否则双摄等功能没法调
            topBar
                .padding(.horizontal, 18)
                .padding(.top, 8)

            if !session.script.isEmpty {
                TeleprompterPanel(
                    script: session.script,
                    readOffset: session.readOffset,
                    isOffScript: session.isOffScript,
                    onTapOffset: { session.jump(toCharOffset: $0) },
                    screenHeight: geo.size.height,
                    settings: settings
                )
            }

            Spacer(minLength: 0)

            if showLightPanel {
                LightPanel(settings: settings) {
                    withAnimation(Theme.spring) { showLightPanel = false }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 10)
            }

            HStack(spacing: 8) {
                modeSwitcher
            }
            .padding(.bottom, 12)

            RecordingBadge(isRecording: shooting?.isRecording ?? false,
                           duration: shooting?.recordedDuration ?? 0)
                .padding(.bottom, 12)

            RecordControls(
                isRecording: shooting?.isRecording ?? false,
                canFlip: canFlipCamera,
                flipIcon: shooting?.mode == .dual
                    ? "arrow.left.arrow.right"
                    : "arrow.triangle.2.circlepath",
                canStartRecording: shooting?.canStartRecording ?? true,
                libraryThumbnail: latestThumbnail,
                onToggleRecord: toggleRecord,
                onFlip: { withAnimation(Theme.spring) { capture.flipCamera() } },
                onOpenLibrary: { showRecordings = true }
            )
            .padding(.bottom, 26)
        }
    }

    /// 提词区实际占掉的高度，用来把 PiP 小窗挡在它下面
    private func prompterOccupiedHeight(_ geo: GeometryProxy) -> CGFloat {
        let toolbar: CGFloat = 44          // 常驻工具条
        guard !session.script.isEmpty else { return toolbar }
        return geo.size.height * settings.heightRatio
            + TeleprompterPanel.handleHeight
            + toolbar
    }

    private var canFlipCamera: Bool {
        switch shooting?.mode {
        case .dual:            return true
        case .single:          return !(shooting?.isRecording ?? false)
        case nil:              return false
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 3) {
            modeChip("单摄", active: shooting?.mode == .single) {
                shooting?.switchTo(.single)
            }
            modeChip("双摄", active: shooting?.mode == .dual) {
                shooting?.switchTo(.dual)
            }
            .opacity(capture.isDualSupported ? 1 : 0.3)
            .disabled(!capture.isDualSupported)
        }
        .padding(3)
        // 同上：亮背景下"单摄/双摄"的灰字会糊进玻璃里
        .background(Capsule().fill(Color.black.opacity(0.34)))
        .glassEffect(.regular, in: .capsule)
        // 切模式要重建 session，录制中断流会丢片，直接禁掉。
        // `ShootingModeCoordinator.switchTo` 内部也会挡（双重保险，UI 层
        // 禁用是给用户看的，协调器的 guard 是给代码路径兜底的）。
        .opacity(shooting?.isRecording == true ? 0.3 : 1)
        .disabled(shooting?.isRecording == true)
        .animation(Theme.ease(0.25), value: shooting?.isRecording)
    }

    private func modeChip(_ title: LocalizedStringKey,
                          active: Bool,
                          action: @escaping () -> Void) -> some View {
        Button {
            Haptic.light()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.white : Theme.fgMuted)
                .padding(.horizontal, 15)
                .padding(.vertical, 6)
                .background {
                    if active { Capsule().fill(Theme.accent) }
                }
        }
        .animation(Theme.ease(0.22), value: active)
    }

    /// 常驻工具条：状态灯 + 当前脚本 + 脚本库入口 + 设置入口
    private var topBar: some View {
        HStack(spacing: 9) {
            if !session.script.isEmpty { speechDot }

            Button {
                Haptic.light()
                showScripts = true
            } label: {
                HStack(spacing: 5) {
                    if session.script.isEmpty {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(topBarTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(topBarTint)
            }

            Spacer(minLength: 6)

            Button {
                Haptic.light()
                showScripts = true
            } label: {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.fgMuted)
                    .frame(width: 30, height: 24)
            }
            .opacity(session.script.isEmpty ? 0 : 1)   // 空态时左侧已有入口，避免重复

            // 补光灯的参数要在录制中随时调（换个位置、光线变了就得改），
            // 所以顶栏直达悬浮面板，不进设置页
            Button {
                Haptic.light()
                withAnimation(Theme.spring) {
                    if showLightPanel {
                        showLightPanel = false
                    } else {
                        // 点这个图标就是想补光，顺手开灯省一步
                        if !settings.fillLight { settings.fillLight = true }
                        showLightPanel = true
                    }
                }
            } label: {
                Image(systemName: settings.fillLight ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(settings.fillLight ? Theme.accent : Theme.fgMuted)
                    .frame(width: 30, height: 24)
            }

            Button {
                Haptic.light()
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.fgMuted)
                    .frame(width: 30, height: 24)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // 玻璃会跟着背后画面变亮，白天户外或对着亮物体录的时候
        // 近白的标题会整条消失。垫一层暗底保底对比度。
        .background(Capsule().fill(Color.black.opacity(0.34)))
        .glassEffect(.regular, in: .capsule)
    }

    private var topBarTitle: String {
        if let note = speechNote { return note }
        if session.script.isEmpty { return String(localized: "选一个脚本") }
        return script?.displayTitle ?? ""
    }

    private var topBarTint: Color {
        speechNote == nil ? Theme.fg.opacity(0.85) : Theme.warn
    }

    /// 跟读引擎状态灯
    private var speechDot: some View {
        Circle()
            .fill(speechDotColor)
            .frame(width: 6, height: 6)
            .animation(Theme.ease(0.3), value: speechDotColor)
    }

    private var speechDotColor: Color {
        switch session.speech.status {
        case .running:                    return Color(hex: 0x3DD68C)   // 跟读中
        case .preparing, .downloading:    return Theme.warn
        case .failed, .unsupported:       return Theme.rec
        case .idle:                       return Theme.fgMuted.opacity(0.45)
        }
    }

    /// 跟读不可用时，把原因顶到标题位上，别让用户以为是自己念错了
    private var speechNote: String? {
        switch session.speech.status {
        case .unsupported(let m), .failed(let m): return m
        case .preparing:                          return String(localized: "跟读准备中…")
        default:                                  return nil
        }
    }

    // MARK: - 动作

    private func showToast(_ text: String) {
        withAnimation(Theme.ease()) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(Theme.ease()) { toast = nil }
        }
    }

    private func load(_ s: Script) {
        script = s
        session.load(ScriptTokenizer.parse(s.content))
        // 这里不启动识别 —— 只有开录才听麦克风
    }

    /// 语音识别的生命周期绑在录制上：省电，也避免不录的时候一直开着麦克风识别
    private func toggleRecord() {
        let wasRecording = shooting?.isRecording ?? false
        shooting?.toggleRecording()
        if wasRecording {
            Task { await session.stopFollowing() }
        } else if settings.autoScroll, !session.script.isEmpty {
            Task { await session.startFollowing() }
        }
    }

    /// 录制的「存好了」收尾：写字幕时间轴、刷新回看列表、弹 toast。
    private func handleSaved(_ url: URL?, origin: Double?) {
        guard let url else { return }
        saveTimeline(for: url, origin: origin)
        recordings.reload()
        showToast(String(localized: "已存入相册"))
    }

    /// 把本次录制的「原稿句 ↔ 视频时间」写到视频旁边的同名 .json。
    /// 之后在回看页可以导出成 SRT，字幕文本用原稿，不用手动对轴。
    ///
    private func saveTimeline(for movieURL: URL, origin: Double?) {
        guard !session.script.isEmpty, let origin else { return }

        let timeline = session.timeline.build(
            title: script?.displayTitle ?? String(localized: "未命名脚本"),
            sentences: session.script.sentences,
            originSeconds: origin,
            recordedAt: Date()
        )
        guard !timeline.isEmpty else { return }

        try? timeline.jsonData()
            .write(to: ReadingTimeline.sidecarURL(for: movieURL), options: .atomic)
    }

    private func setUpIfNeeded() async {
        recordings.reload()
        guard await capture.requestPermissions() else { return }
        capture.configure(mode: .single)
        session.attach(to: capture)         // 音频旁路：采集 → 识别（默认单摄模式）
        shooting = ShootingModeCoordinator(capture: capture)
    }

    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            capture.start()
            // 回前台时不自动恢复识别，下次录制再开启。
            if settings.fillLight { ScreenBrightness.boost() }
        case .inactive, .background:
            // 中断时收尾保存，保留已经录制的内容。
            if shooting?.isRecording == true { shooting?.toggleRecording() }
            capture.stop()
            Task { await session.stopFollowing() }
            ScreenBrightness.restore()
        @unknown default:
            break
        }
    }

}

// MARK: - 录制指示

private struct RecordingBadge: View {
    let isRecording: Bool
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.rec)
                .frame(width: 9, height: 9)

            Text(format(duration))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.fg)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .opacity(isRecording ? 1 : 0)
        .animation(Theme.ease(0.25), value: isRecording)
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - 提示

private struct Toast: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 190)
        }
    }
}

// MARK: - 语言模型下载

private struct ModelDownloadOverlay: View {
    let progress: Double

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Text("正在下载识别模型")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.fg)

                ProgressView(value: max(0, min(progress, 1)))
                    .tint(Theme.accent)
                    .frame(width: 190)

                Text("只需一次,之后全程离线识别")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fgMuted)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.radius))
            Spacer()
        }
    }
}

// MARK: - 权限缺失

private struct PermissionOverlay: View {
    var body: some View {
        ZStack {
            Theme.bgDeep.opacity(0.94).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.fgMuted)

                Text("需要相机和麦克风权限")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.fg)

                Text("口播相机要用摄像头录像、用麦克风收音并识别你读到哪一句。\n识别全程在本机完成,不会上传任何音频。")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.fgMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)

                Button("去设置里打开") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .padding(.top, 6)
            }
        }
    }
}
