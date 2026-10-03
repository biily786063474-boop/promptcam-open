import AVKit
import SwiftUI

/// 回看页：本机录制的网格列表，点开即播。
struct RecordingsView: View {

    @Bindable var store: RecordingsStore

    @Environment(\.dismiss) private var dismiss
    @State private var playing: RecordingsStore.Item?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .background(Theme.bgBase)
            .navigationTitle("回看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }.tint(Theme.fgMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // 录制时已同步存入相册，这里给个直达系统相册的口子
                        if let url = URL(string: "photos-redirect://") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    .tint(Theme.fgMuted)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { store.reload() }
        .fullScreenCover(item: $playing) { item in
            PlayerScreen(url: item.url)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(store.items) { item in
                    Cell(item: item, store: store)
                        .onTapGesture {
                            Haptic.light()
                            playing = item
                        }
                        .contextMenu {
                            ShareLink(item: item.url) {
                                Label("分享视频", systemImage: "square.and.arrow.up")
                            }
                            // 字幕文本取原稿、时间取跟读对齐结果，不用手动对轴
                            if let srt = store.srtFile(for: item) {
                                ShareLink(item: srt) {
                                    Label("导出字幕 SRT", systemImage: "captions.bubble")
                                }
                            }
                            if let json = store.timelineFile(for: item) {
                                ShareLink(item: json) {
                                    Label("导出时间轴 JSON", systemImage: "curlybraces")
                                }
                            }
                            Button(role: .destructive) {
                                store.delete(item)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(3)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: "film.stack")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.fgMuted)
            Text("还没有录制")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.fg)
            Text("录完的视频会出现在这里,同时存入系统相册")
                .font(.system(size: 13))
                .foregroundStyle(Theme.fgMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 单格

private struct Cell: View {
    let item: RecordingsStore.Item
    let store: RecordingsStore

    @State private var image: UIImage?
    @State private var duration: TimeInterval?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Theme.bgElevated)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView().tint(Theme.fgMuted)
                    }
                }
                .clipped()

            HStack(spacing: 4) {
                Image(systemName: "play.fill").font(.system(size: 8))
                if let duration {
                    Text(RecordingsStore.timeText(duration))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                }
                // 有跟读时间轴 → 能导字幕
                if store.hasTimeline(item) {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.accent)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(5)
        }
        .contentShape(Rectangle())
        .task {
            image = await store.thumbnail(for: item.url)
            duration = await store.duration(for: item.url)
        }
    }
}

// MARK: - 播放

private struct PlayerScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    /// 必须由 State 持有：写在 body 里现造会导致每次重算都换一个 player
    @State private var player: AVPlayer?
    @State private var timeline: ReadingTimeline?
    @State private var caption: ReadingTimeline.Entry?
    @State private var showCaptions = true
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            if showCaptions, let caption {
                captionOverlay(caption)
            }

            topControls
        }
        .onAppear(perform: setUp)
        .onDisappear(perform: tearDown)
    }

    // MARK: 字幕

    /// 用生成的时间轴实时叠字幕。文本是原稿，所以这里看到的
    /// 就是导出 SRT 后在剪辑软件里的效果——对不对轴一眼可判。
    private func captionOverlay(_ entry: ReadingTimeline.Entry) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 6) {
                if entry.offScript {
                    Text("这句期间判定为脱稿")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.warn)
                }
                Text(entry.text)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.black.opacity(0.62))
                    )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 96)      // 让开系统播放控件
        }
        .allowsHitTesting(false)
        .animation(Theme.ease(0.15), value: entry.index)
    }

    private var topControls: some View {
        VStack {
            HStack(spacing: 10) {
                Button {
                    Haptic.light()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular, in: .circle)
                }

                Spacer()

                if timeline != nil {
                    Button {
                        Haptic.light()
                        showCaptions.toggle()
                    } label: {
                        Image(systemName: showCaptions
                              ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(showCaptions ? Theme.accent : .white)
                            .frame(width: 40, height: 40)
                            .glassEffect(.regular, in: .circle)
                    }
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 18)

            Spacer()
        }
    }

    // MARK: 生命周期

    private func setUp() {
        timeline = ReadingTimeline.load(from: ReadingTimeline.sidecarURL(for: url))

        let p = AVPlayer(url: url)
        player = p

        // 0.1s 一跳足够跟住字幕，又不至于频繁刷 UI
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            let t = CMTimeGetSeconds(time)
            guard t.isFinite else { return }
            let hit = timeline?.entries.last { $0.start <= t && t <= $0.end }
            if hit?.index != caption?.index { caption = hit }
        }
        p.play()
    }

    private func tearDown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
    }
}
