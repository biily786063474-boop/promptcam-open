import XCTest

final class ScriptLanguageDurationTests: XCTestCase {

    /// 中文 4.2 字/秒（既有取值，不许变）
    func testChineseSecondsPerUnit() {
        XCTAssertEqual(ScriptLanguage.chinese.secondsPerUnit, 1.0 / 4.2, accuracy: 0.0001)
    }

    /// 英文按 150 wpm 取中值 = 2.5 词/秒
    func testEnglishSecondsPerUnit() {
        XCTAssertEqual(ScriptLanguage.english.secondsPerUnit, 1.0 / 2.5, accuracy: 0.0001)
    }

    /// 计量单位随语言变：同一段英文，按词数算出的时长应当合理，
    /// 而不是按字母数算出的十几分钟
    func testEnglishDurationUsesWordsNotLetters() {
        let text = String(repeating: "hello world ", count: 25)   // 50 词
        let lang = ScriptLanguage.english
        let seconds = Double(lang.sentenceUnitCount(text)) * lang.secondsPerUnit
        XCTAssertEqual(seconds, 20, accuracy: 1)
    }

    func testChineseDurationUsesCharacters() {
        let text = String(repeating: "今天聊口播", count: 10)      // 50 字
        let lang = ScriptLanguage.chinese
        let seconds = Double(lang.sentenceUnitCount(text)) * lang.secondsPerUnit
        XCTAssertEqual(seconds, 11.9, accuracy: 0.5)
    }
}
