import Foundation

/// 一次录制的「原稿 ↔ 视频时间」对应表。
///
/// 字幕文本取**原稿**，时间取语音识别的 audioTimeRange。
/// 所以导出的字幕没有 ASR 错字，也不用手动对轴。
struct ReadingTimeline: Codable {

    struct Entry: Codable, Identifiable {
        let index: Int          // 原稿第几句
        let text: String        // 原稿句子（不是识别结果）
        let start: Double       // 视频内秒数
        let end: Double
        let confidence: Double  // 该句的平均跟读置信度
        let offScript: Bool     // 这句期间是否判定为脱稿

        var id: Int { index }
    }

    let title: String
    let recordedAt: Date
    let entries: [Entry]

    var isEmpty: Bool { entries.isEmpty }

    // MARK: - SRT

    func srtString() -> String {
        entries.enumerated().map { i, e in
            """
            \(i + 1)
            \(Self.srtTimestamp(e.start)) --> \(Self.srtTimestamp(e.end))
            \(e.text)
            """
        }
        .joined(separator: "\n\n") + "\n"
    }

    static func srtTimestamp(_ seconds: Double) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d",
                      ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    // MARK: - JSON

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func load(from url: URL) -> ReadingTimeline? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReadingTimeline.self, from: data)
    }

    /// 视频文件旁边的同名 .json
    static func sidecarURL(for movieURL: URL) -> URL {
        movieURL.deletingPathExtension().appendingPathExtension("json")
    }
}

/// 录制期间累积每句的起止时间。
///
/// 一句话可能横跨多条识别结果，一条识别结果也可能横跨多句，
/// 所以按句累积「首次出现」和「最后出现」的时间，而不是逐条硬分段。
final class ReadingTimelineRecorder {

    private struct Span {
        var first: Double
        var last: Double
        var confidenceSum: Double
        var samples: Int
        var offScript: Bool
    }

    private var spans: [Int: Span] = [:]

    func reset() { spans.removeAll() }

    /// - Parameter seconds: 该识别片段结束处的**绝对**时间（采集时钟），导出时再减去录制起点
    func note(sentence: Int, atSeconds seconds: Double,
              confidence: Double, offScript: Bool) {
        guard sentence >= 0, seconds.isFinite else { return }

        if var existing = spans[sentence] {
            existing.last = max(existing.last, seconds)
            existing.first = min(existing.first, seconds)
            existing.confidenceSum += confidence
            existing.samples += 1
            existing.offScript = existing.offScript || offScript
            spans[sentence] = existing
        } else {
            spans[sentence] = Span(first: seconds, last: seconds,
                                   confidenceSum: confidence, samples: 1,
                                   offScript: offScript)
        }
    }

    /// - Parameter originSeconds: 录制起点（第一帧视频的 PTS），用来把绝对时间换成视频内时间
    func build(title: String,
               sentences: [ScriptSentence],
               originSeconds: Double,
               recordedAt: Date) -> ReadingTimeline {

        var entries: [ReadingTimeline.Entry] = []

        for index in spans.keys.sorted() {
            guard let span = spans[index],
                  index < sentences.count else { continue }

            let start = max(0, span.first - originSeconds)
            // 至少给 0.4s，避免识别把一整句压在同一瞬间导致零长度字幕
            let end = max(start + 0.4, span.last - originSeconds)

            entries.append(.init(index: index,
                                 text: sentences[index].text,
                                 start: start,
                                 end: end,
                                 confidence: span.samples > 0
                                     ? span.confidenceSum / Double(span.samples) : 0,
                                 offScript: span.offScript))
        }

        // 相邻句去重叠：后一句的开始不早于前一句的结束
        for i in 1..<max(entries.count, 1) where i < entries.count {
            if entries[i].start < entries[i - 1].end {
                let prev = entries[i - 1]
                entries[i - 1] = .init(index: prev.index, text: prev.text,
                                       start: prev.start,
                                       end: min(prev.end, entries[i].start),
                                       confidence: prev.confidence,
                                       offScript: prev.offScript)
            }
        }

        return ReadingTimeline(title: title, recordedAt: recordedAt, entries: entries)
    }
}
