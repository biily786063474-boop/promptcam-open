import Foundation

struct AlignmentSnapshot: Equatable {
    /// 已读到的 token 位置（exclusive，即"下一个要读的"）
    var tokenAnchor: Int = 0
    var sentenceIndex: Int = 0
    var confidence: Double = 0
    /// 连续跟不上 → 用户在即兴发挥，停止自动滚动
    var isOffScript: Bool = false
}

/// 跟读对齐：把 ASR 的实时文本对到原稿位置上。
///
/// 做法是**滑动窗口内的 fitting alignment**（query 全局、脚本局部）：
/// 取 ASR 尾部若干 token 作 query，在当前锚点附近的窗口里找最佳落点。
/// 窗口限制既允许小幅回退（重读一句）和跳读，又能防止匹配到全文别处的相似句式。
///
/// 打分分三层：字面 > 拼音（同音字容错）> 声母（模糊兜底）。
/// 中文 ASR 最常见的错误就是同音字，拼音层是准确率的关键。
final class ReadingAligner {

    /// 所有可调参数集中在这里 —— 真机调参只改这一个结构体
    struct Tuning: Equatable {
        /// 取 ASR 尾部多少个 token 作为匹配 query
        var queryLength = 10
        /// 窗口相对锚点的后退/前进范围
        var windowBack = 8
        var windowForward = 40

        var scoreExact: Double    =  3.0    // 字面相同
        var scorePinyin: Double   =  2.0    // 同音字
        var scoreInitial: Double  =  0.5    // 仅声母相同
        var scoreMismatch: Double = -2.0
        var scoreGap: Double      = -1.5    // 漏字 / 插字

        /// 归一化置信度阈值。跟读体验对**响应速度**极敏感，
        /// 所以门槛压低、阻尼放松——宁可偶尔多走一两个字，也不能让人觉得"卡"。
        var acceptThreshold = 0.45          // 以上直接采纳
        var dampThreshold   = 0.28          // 之间按 dampFactor 前进（抗抖）
        /// 弱匹配时前进的比例。越接近 1 越跟手，越小越稳。
        var dampFactor      = 0.75

        /// 连续匹配不上多久判定为脱稿
        var offScriptSeconds: TimeInterval = 3.0

        /// 从 ASR 全文尾部截取多少字符参与分词
        var tailCharacters = 60

        static let `default` = Tuning()
    }

    private let script: ParsedScript
    var tuning: Tuning

    private(set) var snapshot = AlignmentSnapshot()
    private var lastMatchTime: TimeInterval = 0
    private var started = false

    /// `tuning` 传 nil 表示按脚本语言取默认参数（正常路径）；
    /// 传值只用于测试和真机调参。
    init(script: ParsedScript, tuning: Tuning? = nil) {
        self.script = script
        self.tuning = tuning ?? Tuning(language: script.language)
    }

    // MARK: - 主入口

    /// 喂入 ASR 当前累积文本（含 volatile 部分）。`now` 用单调时钟。
    @discardableResult
    func consume(_ transcript: String, now: TimeInterval) -> AlignmentSnapshot {
        if !started { lastMatchTime = now; started = true }
        guard !script.isEmpty else { return snapshot }

        let tail = script.language.transcriptTail(transcript,
                                                  characters: tuning.tailCharacters)
        let query = Array(ScriptTokenizer.tokenize(tail).suffix(tuning.queryLength))
        guard !query.isEmpty else { return snapshot }

        // 脱稿时放开到全文搜索，好让用户讲回原稿时能自动接上
        let range: Range<Int> = snapshot.isOffScript
            ? 0..<script.tokens.count
            : max(0, snapshot.tokenAnchor - tuning.windowBack)
              ..< min(script.tokens.count, snapshot.tokenAnchor + tuning.windowForward)
        guard !range.isEmpty else { return snapshot }

        guard let (end, score) = fit(query: query, in: range) else { return snapshot }
        let confidence = score / (Double(query.count) * tuning.scoreExact)
        snapshot.confidence = confidence

        if confidence > tuning.acceptThreshold {
            snapshot.tokenAnchor = end
            snapshot.isOffScript = false
            lastMatchTime = now
        } else if confidence > tuning.dampThreshold {
            // 半信半疑：按比例前进，避免 ASR 抖动把稿子拽飞
            let delta = Double(end - snapshot.tokenAnchor) * tuning.dampFactor
            snapshot.tokenAnchor += Int(delta.rounded())
            snapshot.isOffScript = false
            lastMatchTime = now
        } else if now - lastMatchTime > tuning.offScriptSeconds {
            snapshot.isOffScript = true
        }

        snapshot.sentenceIndex = script.sentenceIndex(
            forToken: max(0, snapshot.tokenAnchor - 1)
        )
        return snapshot
    }

    /// 手动把锚点拉到某个 token（用户点了提词面板上的某一行）
    func jump(toToken index: Int, now: TimeInterval) {
        let clamped = min(max(index, 0), script.tokens.count)
        snapshot.tokenAnchor = clamped
        snapshot.sentenceIndex = script.sentenceIndex(forToken: max(0, clamped - 1))
        snapshot.isOffScript = false
        lastMatchTime = now
        started = true
    }

    /// 手动把锚点拉到某句开头
    func jump(toSentence index: Int, now: TimeInterval) {
        guard index >= 0, index < script.sentences.count else { return }
        jump(toToken: script.sentences[index].tokenRange.lowerBound, now: now)
    }

    func reset(now: TimeInterval) {
        snapshot = AlignmentSnapshot()
        lastMatchTime = now
        started = true
    }

    // MARK: - 对齐核心

    /// Fitting alignment：query 必须整条消耗完，脚本侧可从窗口任意位置起止。
    /// 返回脚本侧的最佳结束下标（exclusive）与得分。
    private func fit(query: [ScriptToken], in range: Range<Int>) -> (end: Int, score: Double)? {
        let m = query.count
        let n = range.count
        guard m > 0, n > 0 else { return nil }

        let base = range.lowerBound
        // dp[0][j] = 0：脚本侧起点自由，不惩罚前面跳过的部分
        var prev = [Double](repeating: 0, count: n + 1)
        var curr = [Double](repeating: 0, count: n + 1)

        for i in 1...m {
            // query 侧必须全部消耗，跳过 query 的字要付 gap
            curr[0] = Double(i) * tuning.scoreGap
            for j in 1...n {
                let s = matchScore(query[i - 1], script.tokens[base + j - 1])
                curr[j] = max(prev[j - 1] + s,          // 对上
                              prev[j] + tuning.scoreGap, // ASR 多出一个字
                              curr[j - 1] + tuning.scoreGap) // 稿子上被吃掉一个字
            }
            swap(&prev, &curr)
        }
        // swap 后 prev 持有第 m 行
        var best = -Double.infinity
        var bestEnd = -1
        for j in 1...n where prev[j] > best {
            best = prev[j]
            bestEnd = base + j
        }
        guard bestEnd >= 0 else { return nil }
        return (bestEnd, best)
    }

    private func matchScore(_ a: ScriptToken, _ b: ScriptToken) -> Double {
        if a.text == b.text       { return tuning.scoreExact }
        if a.pinyin == b.pinyin   { return tuning.scorePinyin }
        if a.initial == b.initial { return tuning.scoreInitial }
        return tuning.scoreMismatch
    }
}

extension ReadingAligner.Tuning {
    /// 按语言构造：只覆盖有分化依据的两项，其余共用。
    /// `queryLength` / 窗口 / 阈值 / `offScriptSeconds` 不分化 ——
    /// 10 个英文词约 4 秒语音，与 10 个中文字的时间尺度接近。
    ///
    /// 写在 extension 里是必须的：定义在 struct 主体内会抑制 memberwise init 的合成。
    init(language: ScriptLanguage) {
        self.init()
        scoreInitial = language.alignerScoreInitial
        tailCharacters = language.alignerTailCharacters
    }
}
