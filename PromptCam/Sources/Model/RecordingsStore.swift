import AVFoundation
import Observation
import UIKit

/// 本机录制文件的索引。
///
/// 数据源就是 Documents/Recordings 里的文件本身，不额外建数据库——
/// 视频文件在，记录就在；文件删了，记录自然没了，不会出现对不上的情况。
/// 读自己的目录也不需要相册读取权限。
@MainActor
@Observable
final class RecordingsStore {

    struct Item: Identifiable, Hashable {
        let url: URL
        let createdAt: Date
        let bytes: Int64

        var id: URL { url }

        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        var dateText: String {
            // 日期格式交给系统按区域决定，不写死格式串 ——
            // "M月d日 HH:mm" 在英文环境下会原样显示成 "8月19日"
            createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
    }

    private(set) var items: [Item] = []

    @ObservationIgnored private var thumbnailCache: [URL: UIImage] = [:]
    @ObservationIgnored private var durationCache: [URL: TimeInterval] = [:]

    var latest: Item? { items.first }

    func reload() {
        let dir = RecordingCoordinator.recordingsDirectory()
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []

        items = urls
            .filter { $0.pathExtension.lowercased() == "mov" }
            .map { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return Item(url: url,
                            createdAt: v?.creationDate ?? .distantPast,
                            bytes: Int64(v?.fileSize ?? 0))
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
        // 时间轴 sidecar 跟着走，别留孤儿文件
        try? FileManager.default.removeItem(at: ReadingTimeline.sidecarURL(for: item.url))
        thumbnailCache[item.url] = nil
        durationCache[item.url] = nil
        reload()
    }

    /// 这条录制有没有跟读时间轴（能导字幕）
    func hasTimeline(_ item: Item) -> Bool {
        FileManager.default.fileExists(
            atPath: ReadingTimeline.sidecarURL(for: item.url).path
        )
    }

    /// 生成 SRT 到临时目录，返回可分享的 URL
    func srtFile(for item: Item) -> URL? {
        let sidecar = ReadingTimeline.sidecarURL(for: item.url)
        guard let timeline = ReadingTimeline.load(from: sidecar),
              !timeline.isEmpty,
              let data = timeline.srtString().data(using: .utf8) else { return nil }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(item.url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("srt")
        guard (try? data.write(to: out, options: .atomic)) != nil else { return nil }
        return out
    }

    func timelineFile(for item: Item) -> URL? {
        let url = ReadingTimeline.sidecarURL(for: item.url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 缩略图 / 时长

    func thumbnail(for url: URL) async -> UIImage? {
        if let cached = thumbnailCache[url] { return cached }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true      // 尊重竖屏 transform
        generator.maximumSize = CGSize(width: 400, height: 400)

        // 取 0.1s 而不是 0：首帧可能还没曝光好
        guard let (cg, _) = try? await generator.image(
            at: CMTime(seconds: 0.1, preferredTimescale: 600)
        ) else { return nil }

        let image = UIImage(cgImage: cg)
        thumbnailCache[url] = image
        return image
    }

    func duration(for url: URL) async -> TimeInterval? {
        if let cached = durationCache[url] { return cached }
        guard let d = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(d)
        guard seconds.isFinite else { return nil }
        durationCache[url] = seconds
        return seconds
    }

    static func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
