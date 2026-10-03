import Foundation
import Observation

/// 提词器可调参数。存 UserDefaults，跨启动保留。
@Observable
final class PrompterSettings {

    private enum Key {
        static let fontSize    = "prompter.fontSize"
        static let lineSpacing = "prompter.lineSpacing"
        static let heightRatio = "prompter.heightRatio"
        static let dimOpacity  = "prompter.dimOpacity"
        static let mirrored    = "prompter.mirrored"
        static let readingLine = "prompter.readingLine"
        static let autoScroll  = "prompter.autoScroll"
        static let fillLight   = "light.fill"
        static let fillLevel   = "light.level"
        static let fillWarmth  = "light.warmth"
        static let fillWidth   = "light.width"
    }

    /// 字号。下限 18 —— 再小手持距离下就读不清了
    var fontSize: Double        { didSet { d.set(fontSize, forKey: Key.fontSize) } }
    var lineSpacing: Double     { didSet { d.set(lineSpacing, forKey: Key.lineSpacing) } }
    /// 面板占屏高比例
    var heightRatio: Double     { didSet { d.set(heightRatio, forKey: Key.heightRatio) } }
    /// 玻璃之上再垫一层黑底的不透明度 —— 提词可读性的保命参数
    var dimOpacity: Double      { didSet { d.set(dimOpacity, forKey: Key.dimOpacity) } }
    /// 外接分光提词器时左右翻转
    var mirrored: Bool          { didSet { d.set(mirrored, forKey: Key.mirrored) } }
    /// 阅读线在面板内的高度位置（0=顶 1=底）
    var readingLine: Double     { didSet { d.set(readingLine, forKey: Key.readingLine) } }
    /// 跟读自动滚动总开关（关掉就是普通手动提词器）
    var autoScroll: Bool        { didSet { d.set(autoScroll, forKey: Key.autoScroll) } }

    /// 屏幕边缘柔光补光灯。开灯时会把屏幕亮度顶满 —— 光靠屏幕背光打出去，
    /// 光带画得再白，屏幕暗了也照不亮脸。
    var fillLight: Bool         { didSet { d.set(fillLight, forKey: Key.fillLight) } }
    /// 补光强度（光带不透明度）
    var fillLightLevel: Double  { didSet { d.set(fillLightLevel, forKey: Key.fillLevel) } }
    /// 色温：0 冷白 → 1 暖白，0.5 附近接近纯白
    var fillLightWarmth: Double { didSet { d.set(fillLightWarmth, forKey: Key.fillWarmth) } }
    /// 光带宽度占屏幕短边的比例。窄=预览遮挡少但光弱，宽=补光足但吃画面
    var fillLightWidth: Double  { didSet { d.set(fillLightWidth, forKey: Key.fillWidth) } }

    static let fontSizeRange    = 18.0...48.0
    static let lineSpacingRange = 0.0...24.0
    static let heightRange      = 0.20...0.65
    static let dimRange         = 0.15...0.60
    static let readingLineRange = 0.25...0.60
    /// 下限 0.2：再淡就只是屏幕泛白、起不到补光作用
    static let fillLightRange   = 0.20...1.00
    /// 上限 0.50：拉到顶时四边在竖屏中央碰头，等于整屏柔光 ——
    /// 吃掉预览，但这是屏幕能给出的最大补光量，需要极亮时留这条路
    static let fillWidthRange   = 0.08...0.50

    private let d = UserDefaults.standard

    /// 默认值 schema 版本。调整过默认值后 +1，并在下面清掉对应旧存值，
    /// 否则试过 slider 的用户会一直卡在旧默认上。
    private static let schemaVersion = 3

    init() {
        // 用局部量读取：存储属性尚未全部初始化，此时不能碰 self
        let store = UserDefaults.standard
        let stored = store.integer(forKey: "prompter.schemaVersion")

        if stored < 2 {
            // v2：面板高度 36%→26%，暗底 35%→25%
            store.removeObject(forKey: Key.heightRatio)
            store.removeObject(forKey: Key.dimOpacity)
        }
        if stored < 3 {
            // v3：补光灯 55%/20% 实测照不亮脸，默认提到 80%/26%
            store.removeObject(forKey: Key.fillLevel)
            store.removeObject(forKey: Key.fillWidth)
        }
        if stored < Self.schemaVersion {
            store.set(Self.schemaVersion, forKey: "prompter.schemaVersion")
        }
        func dbl(_ key: String, _ fallback: Double) -> Double {
            store.object(forKey: key) as? Double ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            store.object(forKey: key) as? Bool ?? fallback
        }
        fontSize    = dbl(Key.fontSize, 26)
        lineSpacing = dbl(Key.lineSpacing, 10)
        heightRatio = dbl(Key.heightRatio, 0.26)
        dimOpacity  = dbl(Key.dimOpacity, 0.25)
        readingLine = dbl(Key.readingLine, 0.40)
        mirrored    = bool(Key.mirrored, false)
        autoScroll  = bool(Key.autoScroll, true)
        fillLight   = bool(Key.fillLight, false)
        fillLightLevel  = dbl(Key.fillLevel, 0.80)
        fillLightWarmth = dbl(Key.fillWarmth, 0.55)
        fillLightWidth  = dbl(Key.fillWidth, 0.26)
    }
}
