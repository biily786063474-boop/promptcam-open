import Foundation
import NaturalLanguage

/// 脚本语言。**语言差异的唯一归属地** —— 凡是隐含中文假设的常量
/// （断句符、句长上限、时长系数、对齐参数、识别 locale）一律搬进来，
/// 不允许散落各处。加第三种语言只加一个 case，调用方不动。
enum ScriptLanguage: String, CaseIterable {
    case chinese
    case english

    // MARK: - 检测

    /// 送检文本上限。NLLanguageRecognizer 的成本随长度线性增长，
    /// 而判定主导语言几百字符早已足够 —— 截断让检测成本恒定
    /// （脚本列表每一行都会调一次）。
    private static let detectionPrefix = 400

    /// 低于这个有效字符数就不猜了。短样本上 NLLanguageRecognizer
    /// 极不稳定（"Hi" 能判成十几种语言），猜错的代价是识别语言全错。
    private static let minimumSampleLetters = 8

    /// 汉字数达到这个门槛就直接判中文，不再问 NLLanguageRecognizer。
    ///
    /// 两种语言在这件事上是**不对称**的：中文口播稿夹英文术语是常态
    /// （"这个 API 用 Swift 写"），而英文稿里出现好几个汉字几乎不可能。
    /// 不加这一层的话，识别器会按字母数把上面那种句子判成英文
    /// （SpeechAnalyzer 一个词就 14 个字母，几句术语就压过汉字）—— 实测踩到过。
    private static let cjkThreshold = 4

    /// 判定主导语言；认不出、样本太短、非中英文一律回退 `.chinese`。
    static func detect(_ text: String) -> ScriptLanguage {
        let sample = String(text.prefix(detectionPrefix))

        var letters = 0
        var cjk = 0
        for ch in sample {
            if ch.isCJKIdeograph { cjk += 1 }
            else if ch.isLetter { letters += 1 }
        }
        if cjk >= cjkThreshold { return .chinese }
        guard letters + cjk >= minimumSampleLetters else { return .chinese }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage == .english ? .english : .chinese
    }

    // MARK: - 语音识别

    /// 识别引擎的 locale。`SpeechTranscriber` 在构造时绑定 locale，
    /// 换语言必须重建引擎（见 `ReadingSession.load`）。
    var speechLocale: Locale {
        switch self {
        case .chinese: return Locale(identifier: "zh-CN")
        case .english: return Locale(identifier: "en-US")
        }
    }

    // MARK: - 断句

    /// 硬断句符（保留在句尾）。
    /// 英文的 `.` 不在这里 —— 它有歧义，走 `ScriptTokenizer` 的单独判定。
    var terminators: Set<Character> {
        switch self {
        case .chinese: return ["。", "！", "？", "；", "…", "!", "?", ";", "\n"]
        case .english: return ["!", "?", ";", "…", "\n"]
        }
    }

    /// 软断句符 —— 只有当句子超过 `maxSentenceUnits` 时才在这里切
    var softBreaks: Set<Character> {
        switch self {
        case .chinese: return ["，", ",", "、", "：", ":"]
        case .english: return [",", ":"]
        }
    }

    /// 单句长度上限。**计量单位随语言变**（见 `sentenceUnitCount`）：
    /// 中文 28 个字是合理一屏；英文 28 个字母只有五六个词，会把稿子切碎，
    /// 所以英文按词数计，12 词 ≈ 一屏。
    var maxSentenceUnits: Int {
        switch self {
        case .chinese: return 28
        case .english: return 12
        }
    }

    /// 句长的计量函数：中文数字符，英文数词。标点和空格都不计入。
    func sentenceUnitCount(_ s: String) -> Int {
        switch self {
        case .chinese:
            return s.reduce(into: 0) { acc, ch in
                if ch.isLetter || ch.isNumber { acc += 1 }
            }
        case .english:
            return s.split { !($0.isLetter || $0.isNumber) }.count
        }
    }

    /// 每个计量单位的口播秒数。单位就是 `sentenceUnitCount` 数的东西：
    /// 中文是字（4.2 字/秒），英文是词（150 wpm = 2.5 词/秒）。
    var secondsPerUnit: Double {
        switch self {
        case .chinese: return 1.0 / 4.2
        case .english: return 1.0 / 2.5
        }
    }

    /// 句子之间的连接符。英文丢掉原始空白后必须补回一个空格，
    /// 否则 "First one." + "Second one." 会拼成 "First one.Second one."。
    var sentenceJoiner: String {
        switch self {
        case .chinese: return ""
        case .english: return " "
        }
    }

    // MARK: - 对齐

    /// 仅声母/首字母相同时的得分。
    ///
    /// 英文取 0：`pinyin` 等于原词小写，三层打分对英文已塌成两层，
    /// 剩下的首字母层是**净噪声** —— 英文高频词首字母高度集中
    /// （the/that/this/there/to/they），给分会让 DP 在错误位置堆出虚高得分，
    /// 把锚点拽偏。中文声母有 20 余种取值且分布相对均匀，同一规则噪声水平截然不同。
    var alignerScoreInitial: Double {
        switch self {
        case .chinese: return 0.5
        case .english: return 0
        }
    }

    /// 从 ASR 全文尾部截取多少字符参与分词。
    ///
    /// 中文 60 字符即 60 个 token，取 10 个 query token 绰绰有余；
    /// 英文 60 字符只有 10–12 个词，恰好等于 queryLength，缓冲为零 —— 放大到 200。
    var alignerTailCharacters: Int {
        switch self {
        case .chinese: return 60
        case .english: return 200
        }
    }

    /// 取 ASR 尾部片段。英文额外丢弃被截断的首词：
    /// `suffix(n)` 会从单词中间切开，残词进 query 即是一次必然 mismatch。
    func transcriptTail(_ transcript: String, characters: Int) -> String {
        let tail = String(transcript.suffix(characters))
        guard self == .english, tail.count < transcript.count else { return tail }
        guard let first = tail.first, first.isLetter || first.isNumber else { return tail }
        guard let cut = tail.firstIndex(where: { !($0.isLetter || $0.isNumber) }) else {
            return ""      // 整段就是一个残词
        }
        return String(tail[cut...])
    }
}
