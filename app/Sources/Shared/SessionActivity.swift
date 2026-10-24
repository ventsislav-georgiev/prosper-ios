import SwiftUI

/// How a dch agent state reads on screen: the session list and the Live Activity, so the
/// two can't drift apart.
enum SessionStateStyle: String, CaseIterable {
    case working, blocked, idle, done

    /// nil for an unknown state from a newer server — better to say nothing than guess.
    init?(_ raw: String?) {
        guard let raw, let s = SessionStateStyle(rawValue: raw) else { return nil }
        self = s
    }

    var label: String {
        switch self {
        case .working: return "working"
        case .blocked: return "needs you"
        case .idle:    return "idle"
        case .done:    return "done"
        }
    }

    var symbol: String {
        switch self {
        case .working: return "circle.dotted"
        case .blocked: return "hand.raised.fill"
        case .idle:    return "moon.zzz"
        case .done:    return "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .working: return .blue
        case .blocked: return .orange
        case .idle:    return .secondary
        case .done:    return .green
        }
    }

    /// "2 agents" / "1 agent" for a session's live subagents, nil for none — callers
    /// append it to the state rather than showing a zero.
    static func agents(_ n: Int?) -> String? {
        guard let n, n > 0 else { return nil }
        return n == 1 ? "1 agent" : "\(n) agents"
    }
}
