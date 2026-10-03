import CoreText
import UIKit

/// 把提词文本按**视觉行**切开。
///
/// 逐行滚动必须知道"这一行到底包含哪些字"，而这取决于字体和可用宽度，
/// 只能靠真实排版算出来。CoreText 的 CTFrame 正好给出每行的字符区间。
struct PrompterLayout: Equatable {

    struct Line: Identifiable, Equatable {
        let id: Int
        /// 该行在文本中的 utf16 区间
        let range: Range<Int>
    }

    let lines: [Line]

    static let empty = PrompterLayout(lines: [])

    static func compute(text: String, font: UIFont, width: CGFloat) -> PrompterLayout {
        guard !text.isEmpty, width > 1 else { return .empty }

        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        // 高度给一个足够大的有限值：CGFloat.greatestFiniteMagnitude 会让
        // CoreText 内部计算溢出，返回空行集。
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000),
                          transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter,
                                             CFRange(location: 0, length: 0),
                                             path, nil)

        let ctLines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        let lines = ctLines.enumerated().map { index, line -> Line in
            let r = CTLineGetStringRange(line)
            return Line(id: index, range: r.location..<(r.location + r.length))
        }
        return PrompterLayout(lines: lines)
    }

    /// 某个字符位置落在第几行。用于把朗读进度换算成滚动目标。
    func lineIndex(containing offset: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        // 行是按顺序且连续的，二分查找
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = lines[mid].range
            if offset < r.lowerBound { hi = mid - 1 }
            else if offset >= r.upperBound { lo = mid + 1 }
            else { return mid }
        }
        // 落在末尾之后
        return min(max(lo, 0), lines.count - 1)
    }
}
