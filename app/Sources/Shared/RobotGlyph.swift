import SwiftUI

/// #1547: the sub-agents robot, drawn in Apple's SF line style (replaces the U+1F916 emoji; the Mac draws the same one):
/// a rounded head, an antenna with a ball, two eyes, two ears; stroke 0.09 of the side, round caps and joins. It takes the
/// surrounding foregroundStyle as an SF Symbol does. Its side is 1.15 of the caption2 font size at default, then follows caption2's line height.
enum RobotGeometry {
    /// The line parts (head, stem, ears) and the filled parts (antenna ball, eyes) in `r`, top-left origin.
    static func paths(in r: CGRect) -> (line: Path, fill: Path) {
        let w = r.width, h = r.height
        func y(_ up: CGFloat) -> CGFloat { r.minY + (1 - up) * h }   // the drawing's fractions count from the bottom
        var line = Path(), fill = Path()
        line.addRoundedRect(in: CGRect(x: r.minX + w * 0.12, y: y(0.68), width: w * 0.76, height: h * 0.62),
                            cornerSize: CGSize(width: w * 0.2, height: w * 0.2))
        line.move(to: CGPoint(x: r.midX, y: y(0.68)))
        line.addLine(to: CGPoint(x: r.midX, y: y(0.84)))
        let ball = w * 0.13
        fill.addEllipse(in: CGRect(x: r.midX - ball / 2, y: y(0.84) - ball * 0.35 - ball / 2, width: ball, height: ball))
        let eye = w * 0.14
        for x in [0.36, 0.64] {
            fill.addEllipse(in: CGRect(x: r.minX + w * x - eye / 2, y: y(0.36) - eye / 2, width: eye, height: eye))
        }
        for (x, dir) in [(0.12, -1.0), (0.88, 1.0)] {
            let edge = r.minX + w * x, out = edge + dir * w * 0.08
            line.move(to: CGPoint(x: edge, y: y(0.30)))
            line.addLine(to: CGPoint(x: out, y: y(0.30)))
            line.addLine(to: CGPoint(x: out, y: y(0.46)))
            line.addLine(to: CGPoint(x: edge, y: y(0.46)))
        }
        return (line, fill)
    }
    static let strokeFraction: CGFloat = 0.09
    static let sideFactor: CGFloat = 1.15
}

struct RobotGlyph: View {
    @Environment(\.dynamicTypeSize) private var size

    /// #1554: sized from caption2's line height plus the chip's padding (the pill's height), not its point size: the line grows more slowly at
    /// accessibility sizes, so the point size made the glyph fill 87% of the pill there instead of 78%. Same side at .large.
    private var side: CGFloat {
        func line(_ t: DynamicTypeSize) -> CGFloat {
            #if canImport(UIKit)
            let cat: UIContentSizeCategory
            switch t {
            case .xSmall: cat = .extraSmall
            case .small: cat = .small
            case .medium: cat = .medium
            case .large: cat = .large
            case .xLarge: cat = .extraLarge
            case .xxLarge: cat = .extraExtraLarge
            case .xxxLarge: cat = .extraExtraExtraLarge
            case .accessibility1: cat = .accessibilityMedium
            case .accessibility2: cat = .accessibilityLarge
            case .accessibility3: cat = .accessibilityExtraLarge
            case .accessibility4: cat = .accessibilityExtraExtraLarge
            case .accessibility5: cat = .accessibilityExtraExtraExtraLarge
            @unknown default: cat = .large
            }
            return UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: UITraitCollection(preferredContentSizeCategory: cat)).lineHeight + 2   // + the chip's 2 pt of vertical padding, which does not scale
            #else
            return 1
            #endif
        }
        return 11 * RobotGeometry.sideFactor * line(size) / line(.large)
    }

    var body: some View {
        Canvas { ctx, canvas in
            let p = RobotGeometry.paths(in: CGRect(origin: .zero, size: canvas))
            let style = StrokeStyle(lineWidth: canvas.width * RobotGeometry.strokeFraction, lineCap: .round, lineJoin: .round)
            ctx.stroke(p.line, with: .foreground, style: style)
            ctx.fill(p.fill, with: .foreground)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)   // the row's own label names the agents
    }
}
