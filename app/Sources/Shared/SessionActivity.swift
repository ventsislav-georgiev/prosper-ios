import SwiftUI

/// How a dch agent state reads on screen in the session list.
enum SessionStateStyle: String, CaseIterable {
    case working, blocked, idle, done

    /// nil for an unknown state from a newer server — better to say nothing than guess.
    init?(_ raw: String?) {
        guard let raw, let s = SessionStateStyle(rawValue: raw) else { return nil }
        self = s
    }

    /// The Mac's Agent Island words, in the state colour on the row's second line.
    var label: String {
        switch self {
        case .working: return "Working"
        case .blocked: return "Needs input"
        case .idle:    return "Idle"
        case .done:    return "Done"
        }
    }

    /// Agent Island's static glyphs: nothing animates, so working never cycles.
    var glyph: String {
        switch self {
        case .working: return "\u{2733}\u{FE0E}"   // ✳, text style: not the green emoji
        case .blocked: return "!"
        case .idle, .done: return "\u{25CF}" // ●
        }
    }

    /// Agent Island's colours in dark mode; darker ones in light mode, so the amber
    /// still reads on white.
    var tint: Color {
        switch self {
        case .working: return Self.dynamic(dark: (0.85, 0.47, 0.34), light: (0.70, 0.32, 0.19))
        case .blocked: return Self.dynamic(dark: (1.0, 0.7, 0.0), light: (0.66, 0.40, 0.0))
        case .idle:    return Color(uiColor: .secondaryLabel)   // follows Increase Contrast
        case .done:    return Self.dynamic(dark: (0.4, 0.75, 0.45), light: (0.18, 0.52, 0.25))
        }
    }

    private static func dynamic(dark: (r: CGFloat, g: CGFloat, b: CGFloat),
                                light: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        Color(UIColor { (t: UITraitCollection) -> UIColor in
            let c: (r: CGFloat, g: CGFloat, b: CGFloat) = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }

    /// "+2 agents" / "+1 agent" for a session's live subagents, nil for none: the row
    /// draws no chip rather than a zero.
    static func agents(_ n: Int?) -> String? {
        guard let n, n > 0 else { return nil }
        return n == 1 ? "+1 agent" : "+\(n) agents"
    }
}
