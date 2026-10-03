import XCTest

final class ScriptLanguageTests: XCTestCase {

    func testDetectsPureChinese() {
        let s = "今天聊一个被很多人忽略的问题，就是拍口播的时候到底要不要看提词器。"
        XCTAssertEqual(ScriptLanguage.detect(s), .chinese)
    }

    func testDetectsPureEnglish() {
        let s = "Today I want to talk about a problem most people ignore, "
              + "which is whether you should read from a teleprompter at all."
        XCTAssertEqual(ScriptLanguage.detect(s), .english)
    }

    /// 技术类中文稿里夹英文术语是常态，必须仍判为中文
    func testMixedTechnicalChineseIsChinese() {
        let s = "这个 API 用 Swift 写，跑在 iOS 26 上，用的是 SpeechAnalyzer 和 SwiftUI。"
        XCTAssertEqual(ScriptLanguage.detect(s), .chinese)
    }

    /// 样本太短时 NLLanguageRecognizer 极不稳定，一律回退中文
    func testTooShortFallsBackToChinese() {
        XCTAssertEqual(ScriptLanguage.detect("Hi"), .chinese)
        XCTAssertEqual(ScriptLanguage.detect(""), .chinese)
        XCTAssertEqual(ScriptLanguage.detect("   \n  "), .chinese)
    }

    /// 纯数字/标点没有语言可言，回退中文
    func testNoLettersFallsBackToChinese() {
        XCTAssertEqual(ScriptLanguage.detect("12345 67890 ——————"), .chinese)
    }
}
