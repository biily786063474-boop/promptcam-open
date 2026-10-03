import Foundation

// MARK: - 数据结构

/// 对齐用的最小单位：中文一个字，英文/数字一个词。
struct ScriptToken: Equatable {
    let text: String          // 原文（中文单字 / 英文小写词）
    let pinyin: String        // 无声调拼音；非中文时等于 text
    let initial: String       // 声母（zh/ch/sh 保留两位）
    let sentenceIndex: Int    // 属于第几句；ASR 侧的 token 恒为 -1

    /// 在 `ParsedScript.displayText` 中的位置，**utf16 偏移**
    /// （CoreText / NSString 用的就是 utf16，统一口径避免来回换算出错）
    let offset: Int
    let length: Int

    var endOffset: Int { offset + length }
}

struct ScriptSentence: Identifiable, Equatable {
    let id: Int
    let text: String
    /// 该句在 tokens 数组中的下标区间
    let tokenRange: Range<Int>
    /// 该句在 displayText 中的 utf16 区间
    let displayRange: Range<Int>

    var index: Int { id }
}

struct ParsedScript: Equatable {
    let raw: String
    /// 实际渲染的文本：各句按顺序拼接（保留原标点）。
    /// 所有 utf16 偏移都相对它，而不是 raw —— raw 里的多余空白已被丢掉。
    let displayText: String
    let sentences: [ScriptSentence]
    let tokens: [ScriptToken]
    /// 检测出的脚本语言。识别 locale、对齐参数、时长估算都由它决定。
    let language: ScriptLanguage

    static let empty = ParsedScript(raw: "", displayText: "",
                                    sentences: [], tokens: [], language: .chinese)

    var isEmpty: Bool { tokens.isEmpty }

    /// token 下标 → 所属句子下标
    func sentenceIndex(forToken i: Int) -> Int {
        guard i >= 0, i < tokens.count else { return 0 }
        return tokens[i].sentenceIndex
    }

    /// 锚点（已读 token 数）→ 已读到的字符位置。逐字高亮的分界点。
    func readOffset(forAnchor anchor: Int) -> Int {
        guard anchor > 0 else { return 0 }
        let i = min(anchor, tokens.count) - 1
        guard i >= 0 else { return 0 }
        return tokens[i].endOffset
    }
}

// MARK: - 解析

enum ScriptTokenizer {

    /// 英文缩写白名单（不带点写法）：后面的句点不断句
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "inc", "ltd", "jr", "sr"
    ]
    /// 带内部点的缩写：只有原文确实写成 `a.m.` / `i.e.` 才算数。
    /// 分开放是因为 "am"、"pm" 本身就是常用词，混进上面那张表
    /// 会让 "who I am." 这种正常句子断不开。
    private static let dottedAbbreviations: Set<String> = ["ie", "eg", "am", "pm"]

    // MARK: 脚本 → 句 + token

    static func parse(_ raw: String) -> ParsedScript {
        let language = ScriptLanguage.detect(raw)
        var sentences: [ScriptSentence] = []
        var tokens: [ScriptToken] = []
        var display = ""

        for piece in splitSentences(raw, language: language) {
            // 这一段若能产出 token，它就是第 sentences.count 句；
            // 产不出（纯标点行）则整段丢掉，下一段沿用同一个序号。
            let si = sentences.count
            // 英文断句时原始空白被 trim 掉了，拼接必须补回来，
            // 否则 "First one." + "Second one." 会连成一坨
            let joiner = display.isEmpty ? "" : language.sentenceJoiner
            let base = display.utf16.count + joiner.utf16.count
            let produced = tokenize(piece, sentenceIndex: si, base: base)
            guard !produced.isEmpty else { continue }

            let start = tokens.count
            tokens.append(contentsOf: produced)
            display += joiner + piece

            sentences.append(ScriptSentence(id: si,
                                            text: piece,
                                            tokenRange: start..<tokens.count,
                                            displayRange: base..<display.utf16.count))
        }
        return ParsedScript(raw: raw, displayText: display,
                            sentences: sentences, tokens: tokens,
                            language: language)
    }

    /// ASR 侧文本 → token（不归属任何句子，偏移无意义）
    static func tokenize(_ text: String) -> [ScriptToken] {
        tokenize(text, sentenceIndex: -1, base: 0)
    }

    // MARK: 内部

    private static func splitSentences(_ raw: String,
                                       language: ScriptLanguage) -> [String] {
        var out: [String] = []
        var buf = ""
        let chars = Array(raw)
        let terminators = language.terminators
        let softBreaks = language.softBreaks
        let maxUnits = language.maxSentenceUnits

        func flush() {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            buf = ""
        }

        for (i, ch) in chars.enumerated() {
            buf.append(ch)
            if terminators.contains(ch) {
                flush()
            } else if ch == ".", language == .english,
                      isTerminatingPeriod(chars, at: i) {
                flush()
            } else if softBreaks.contains(ch),
                      language.sentenceUnitCount(buf) >= maxUnits {
                flush()
            }
        }
        flush()
        return out
    }

    /// 英文句点是否为句子终止符。三条同时成立才算：
    /// 1) 其后是空白或字符串结尾；2) 前一个字符不是数字（排除 `3.5`）；
    /// 3) 其前的连续字母不在缩写白名单里。
    /// 连续句点（`...`）按省略号处理，不断句。
    ///
    /// 这类规则不可能穷尽，目标是"读稿场景下不出洋相"，不追求语言学完备。
    private static func isTerminatingPeriod(_ chars: [Character], at i: Int) -> Bool {
        // 省略号：前后任一侧还是句点就不算终止
        if i > 0, chars[i - 1] == "." { return false }
        if i + 1 < chars.count, chars[i + 1] == "." { return false }

        let atEnd = i + 1 == chars.count
        guard atEnd || chars[i + 1].isWhitespace else { return false }

        guard i > 0 else { return false }
        if chars[i - 1].isNumber { return false }

        // 往回收连续的字母与内部句点，覆盖 a.m. / i.e. 这类写法
        var j = i - 1
        var word = ""
        while j >= 0, chars[j].isLetter || chars[j] == "." {
            word.insert(chars[j], at: word.startIndex)
            j -= 1
        }
        let hasInnerDot = word.contains(".")
        let normalized = word.replacingOccurrences(of: ".", with: "").lowercased()
        guard !normalized.isEmpty else { return false }

        if abbreviations.contains(normalized) { return false }
        if hasInnerDot, dottedAbbreviations.contains(normalized) { return false }
        return true
    }

    /// - Parameter base: 本段在 displayText 中的起始 utf16 偏移
    private static func tokenize(_ text: String,
                                 sentenceIndex: Int,
                                 base: Int) -> [ScriptToken] {
        var out: [ScriptToken] = []
        var latinBuf = ""
        var latinStart = 0
        var cursor = 0                  // 相对本段的 utf16 偏移

        func flushLatin() {
            guard !latinBuf.isEmpty else { return }
            let w = latinBuf.lowercased()
            out.append(ScriptToken(text: w, pinyin: w,
                                   initial: String(w.prefix(1)),
                                   sentenceIndex: sentenceIndex,
                                   offset: base + latinStart,
                                   length: latinBuf.utf16.count))
            latinBuf = ""
        }

        for ch in text {
            let width = String(ch).utf16.count
            if ch.isCJKIdeograph {
                flushLatin()
                let s = String(ch)
                let py = pinyin(of: s)
                out.append(ScriptToken(text: s, pinyin: py,
                                       initial: initial(of: py),
                                       sentenceIndex: sentenceIndex,
                                       offset: base + cursor,
                                       length: width))
            } else if ch.isLetter || ch.isNumber {
                if latinBuf.isEmpty { latinStart = cursor }
                latinBuf.append(ch)
            } else {
                flushLatin()      // 标点/空格：断词，本身不入 token
            }
            cursor += width
        }
        flushLatin()
        return out
    }

    // MARK: 拼音

    /// 无声调拼音。
    ///
    /// 已知局限：`CFStringTransform` 不做多音字上下文消歧
    /// （"银行"→yin xing、"重复"→zhong fu）。**不影响对齐正确性**——
    /// 脚本与 ASR 文本走同一个函数，偏差是对称的、会互相抵消；
    /// 最坏情况只是少给一次同音容错分，不会造成错误匹配。
    static func pinyin(of s: String) -> String {
        guard s.range(of: "\\p{Han}", options: .regularExpression) != nil else {
            return s.lowercased()
        }
        let m = NSMutableString(string: s) as CFMutableString
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        return (m as String)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    static func initial(of pinyin: String) -> String {
        for p in ["zh", "ch", "sh"] where pinyin.hasPrefix(p) { return p }
        return String(pinyin.prefix(1))
    }
}

// MARK: -

extension Character {
    /// CJK 统一表意文字（含扩展 A）
    var isCJKIdeograph: Bool {
        unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }
    }
}
