import XCTest

final class ReadingAlignerTests: XCTestCase {

    /// 三个英文测试共用的原稿
    private let englishScript = ScriptTokenizer.parse(
        "The first thing you need to know is that lighting matters more than "
        + "the camera. Most people buy a better camera when they should buy "
        + "a better light instead.")

    // MARK: - 参数分化

    func testEnglishTuningDisablesInitialLayerAndWidensTail() {
        let t = ReadingAligner.Tuning(language: .english)
        XCTAssertEqual(t.scoreInitial, 0)
        XCTAssertEqual(t.tailCharacters, 200)
    }

    func testChineseTuningUnchanged() {
        let t = ReadingAligner.Tuning(language: .chinese)
        XCTAssertEqual(t.scoreInitial, 0.5)
        XCTAssertEqual(t.tailCharacters, 60)
    }

    func testAlignerPicksTuningFromScriptLanguage() {
        XCTAssertEqual(ReadingAligner(script: englishScript).tuning.scoreInitial, 0)
    }

    // MARK: - tail 截取

    /// 按字符截会把首个词拦腰切断，残词进 query 是一次必然 mismatch
    func testEnglishTailDropsPartialLeadingWord() {
        let transcript = "alpha bravo charlie delta"
        let tail = ScriptLanguage.english.transcriptTail(transcript, characters: 18)
        XCTAssertFalse(tail.hasPrefix("ravo"))
        XCTAssertTrue(tail.hasPrefix("charlie") || tail.hasPrefix(" charlie"),
                      "实际拿到：\(tail)")
    }

    /// 没发生截断时原样返回，不许吃掉第一个词
    func testEnglishTailKeepsWholeTranscriptWhenShort() {
        XCTAssertEqual(
            ScriptLanguage.english.transcriptTail("alpha bravo", characters: 200),
            "alpha bravo")
    }

    /// 中文没有词边界问题，保持按字符截断
    func testChineseTailIsPlainSuffix() {
        XCTAssertEqual(
            ScriptLanguage.chinese.transcriptTail("今天我们聊一聊口播这件事", characters: 4),
            "播这件事")
    }

    // MARK: - 英文对齐

    /// 念到中段时锚点应落在念到的位置附近，而不是停在 0 或飞到结尾
    func testEnglishAlignmentAdvancesToSpokenPosition() {
        let aligner = ReadingAligner(script: englishScript)
        let spoken = "the first thing you need to know is that lighting matters"
        let snap = aligner.consume(spoken, now: 1.0)

        // XCTAssertEqual 的 accuracy 重载只吃浮点，Int 得自己算差值
        let expected = ScriptTokenizer.tokenize(spoken).count
        XCTAssertLessThanOrEqual(abs(snap.tokenAnchor - expected), 3,
                                 "锚点落在 \(snap.tokenAnchor)，期望 \(expected) 附近")
        XCTAssertFalse(snap.isOffScript)
    }

    /// query 里错一两个词，序列冗余应当把它吸收掉（这就是不做音近容错的依据）
    func testEnglishAlignmentToleratesRecognitionErrors() {
        let aligner = ReadingAligner(script: englishScript)
        // "need" → "kneed"、"that" → "the" 两处刻意的识别错误
        let spoken = "the first thing you kneed to know is the lighting matters"
        let snap = aligner.consume(spoken, now: 1.0)

        let expected = ScriptTokenizer.tokenize(spoken).count
        XCTAssertLessThanOrEqual(abs(snap.tokenAnchor - expected), 4,
                                 "锚点落在 \(snap.tokenAnchor)，期望 \(expected) 附近")
    }

    /// 锚点单调前进：连续喂入越来越长的文本，锚点不能倒退
    func testEnglishAnchorAdvancesMonotonically() {
        let aligner = ReadingAligner(script: englishScript)
        let words = ("the first thing you need to know is that lighting matters "
                   + "more than the camera most people buy a better camera")
            .split(separator: " ").map(String.init)

        var last = 0
        for i in stride(from: 4, through: words.count, by: 2) {
            let snap = aligner.consume(words.prefix(i).joined(separator: " "),
                                       now: Double(i))
            XCTAssertGreaterThanOrEqual(snap.tokenAnchor, last, "第 \(i) 步锚点倒退")
            last = snap.tokenAnchor
        }
        XCTAssertGreaterThan(last, 10)
    }

    // MARK: - 中文不回归

    func testChineseAlignmentStillWorks() {
        let script = ScriptTokenizer.parse(
            "今天我们聊一聊拍口播这件事。很多人买了更好的相机，其实该买的是灯。")
        let aligner = ReadingAligner(script: script)
        let snap = aligner.consume("今天我们聊一聊拍口播这件事", now: 1.0)
        XCTAssertLessThanOrEqual(abs(snap.tokenAnchor - 13), 3,
                                 "锚点落在 \(snap.tokenAnchor)，期望 13 附近")
    }
}
