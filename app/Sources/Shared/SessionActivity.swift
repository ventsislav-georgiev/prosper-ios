import SwiftUI

/// How a dch agent state reads on screen. Shared by the session list, the notification
/// text, the Live Activity and the Dynamic Island so the four can't drift apart.
///
/// `blocked` and `done` are the two worth interrupting someone over: the agent is either
/// waiting on the user or finished. `working`/`idle` only ever update in place.
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

    /// Notification body for the two states that ping.
    func ping(session: String) -> String? {
        switch self {
        case .blocked: return "\(session) is waiting for your input."
        case .done:    return "\(session) finished."
        case .working, .idle: return nil
        }
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

/// Live Activity payload for one watched session — the Dynamic Island / lock-screen
/// mirror of its agent state. Kept to the raw state string: the widget resolves it
/// through `SessionStateStyle`, so a state a newer Mac invents renders as plain text
/// instead of failing to decode.
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var state: String
    }

    var machine: String
    var session: String
}
#endif
