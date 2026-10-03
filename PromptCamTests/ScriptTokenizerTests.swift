import XCTest

final class ScriptTokenizerTests: XCTestCase {

    // MARK: - 语言写入

    func testParsedScriptCarriesLanguage() {
        let zh = ScriptTokenizer.parse("今天我们聊一聊口播这件事情，怎么念得自然。")
        XCTAssertEqual(zh.language, .chinese)

        let en = ScriptTokenizer.parse(
            "Today we are going to talk about reading a script out loud.")
        XCTAssertEqual(en.language, .english)
    }

    // MARK: - 英文断句：正例

    func testEnglishPeriodFollowedBySpaceSplits() {
        let p = ScriptTokenizer.parse(
            "This is the first sentence. This is the second sentence.")
        XCTAssertEqual(p.sentences.count, 2)
        XCTAssertEqual(p.sentences[0].text, "This is the first sentence.")
        XCTAssertEqual(p.sentences[1].text, "This is the second sentence.")
    }

    func testEnglishQuestionAndExclamationSplit() {
        let p = ScriptTokenizer.parse(
            "Does this work? It really does! Great news for everyone here.")
        XCTAssertEqual(p.sentences.count, 3)
    }

    // MARK: - 英文断句：反例

    func testDecimalNumberDoesNotSplit() {
        let p = ScriptTokenizer.parse(
            "The whole thing costs about 3.5 dollars per month for everyone.")
        XCTAssertEqual(p.sentences.count, 1)
    }

    func testHonorificAbbreviationDoesNotSplit() {
        let p = ScriptTokenizer.parse(
            "Mr. Smith called Dr. Jones about the appointment this morning.")
        XCTAssertEqual(p.sentences.count, 1)
    }

    func testDottedAbbreviationDoesNotSplit() {
        let p = ScriptTokenizer.parse(
            "We meet at 9 a.m. tomorrow, i.e. right after the morning standup.")
        XCTAssertEqual(p.sentences.count, 1)
    }

    /// "am" 只有带点写成 a.m. 时才是缩写；普通单词 am 后面的句点照常断句
    func testPlainWordAmStillSplits() {
        let p = ScriptTokenizer.parse(
            "I know exactly who I am. You should know that about me too.")
        XCTAssertEqual(p.sentences.count, 2)
    }

    func testEllipsisDoesNotSplit() {
        let p = ScriptTokenizer.parse(
            "I was thinking about it... and then it finally made sense to me.")
        XCTAssertEqual(p.sentences.count, 1)
    }

    // MARK: - 英文软断句按词数

    /// 中文 28 字一屏，英文 28 字母只有五六个词。英文必须按词数计，
    /// 否则长句会被切成碎片。
    func testEnglishLongSentenceBreaksByWordCount() {
        let long = "we talked about cameras and lenses and lighting and audio, "
                 + "and then we talked about scripts and delivery and editing, "
                 + "and that was the whole afternoon gone"
        let p = ScriptTokenizer.parse(long)
        XCTAssertGreaterThan(p.sentences.count, 1)
        for s in p.sentences {
            let words = s.text.split { !($0.isLetter || $0.isNumber) }.count
            XCTAssertLessThanOrEqual(words, 24, "断出的句子过长：\(s.text)")
        }
    }

    /// 12 个词以内不该被逗号切开
    func testEnglishShortSentenceKeepsComma() {
        let p = ScriptTokenizer.parse("It is small, but it works well enough.")
        XCTAssertEqual(p.sentences.count, 1)
    }

    // MARK: - displayText / offset 一致性

    /// 英文句子之间必须补空格，否则 "first.Second" 会连成一坨
    func testEnglishSentencesJoinedWithSpace() {
        let p = ScriptTokenizer.parse("First one here. Second one here.")
        XCTAssertEqual(p.displayText, "First one here. Second one here.")
    }

    /// 高亮位置的正确性全靠这个：token 的 utf16 区间必须能从
    /// displayText 上原样切回 token 文本
    func testEnglishTokenOffsetsMatchDisplayText() {
        let p = ScriptTokenizer.parse(
            "First one here. Second sentence follows right after it.")
        let ns = p.displayText as NSString
        for t in p.tokens {
            let slice = ns.substring(with: NSRange(location: t.offset, length: t.length))
            XCTAssertEqual(slice.lowercased(), t.text, "offset 对不上：\(t.text)")
        }
    }

    func testChineseTokenOffsetsMatchDisplayText() {
        let p = ScriptTokenizer.parse("今天聊口播。第二句在这里，也要对得上。")
        let ns = p.displayText as NSString
        for t in p.tokens {
            let slice = ns.substring(with: NSRange(location: t.offset, length: t.length))
            XCTAssertEqual(slice.lowercased(), t.text, "offset 对不上：\(t.text)")
        }
    }

    // MARK: - 中文不回归

    func testChineseSplittingUnchanged() {
        let p = ScriptTokenizer.parse("第一句在这里。第二句在这里！第三句在这里？")
        XCTAssertEqual(p.sentences.count, 3)
        XCTAssertEqual(p.sentences[0].text, "第一句在这里。")
    }

    /// 中文稿里的英文句点不参与断句（保持既有行为）
    func testChinesePeriodInLatinDoesNotSplit() {
        let p = ScriptTokenizer.parse("我们用的是 iOS 26. 这个版本才有本地识别。")
        XCTAssertEqual(p.sentences.count, 1)
    }
}
