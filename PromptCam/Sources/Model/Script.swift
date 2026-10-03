import Foundation
import SwiftData

@Model
final class Script {
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    init(title: String = "", content: String = "") {
        self.title = title
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        // 没填标题就用正文首行顶上，避免列表里一排"未命名"
        let firstLine = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? String(localized: "未命名脚本") : String(firstLine.prefix(20))
    }

    /// 脚本语言。每次访问都重新检测 —— `detect` 只看前 400 字符，
    /// 成本恒定，脚本列表逐行调用也不成问题。
    var language: ScriptLanguage { ScriptLanguage.detect(content) }

    /// 篇幅。**单位随语言变**：中文是字数，英文是词数（都不含标点空格）。
    var unitCount: Int { language.sentenceUnitCount(content) }

    /// 预估口播时长
    var estimatedDuration: TimeInterval {
        Double(unitCount) * language.secondsPerUnit
    }

    var estimatedDurationText: String {
        let s = Int(estimatedDuration.rounded())
        if s < 60 { return String(localized: "约 \(s) 秒") }
        return String(localized: "约 \(s / 60) 分 \(s % 60) 秒")
    }
}
