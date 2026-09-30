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

    /// "2 agents" / "1 agent" for a session's live subagents, nil for none — callers
    /// append it to the state rather than showing a zero.
    static func agents(_ n: Int?) -> String? {
        guard let n, n > 0 else { return nil }
        return n == 1 ? "1 agent" : "\(n) agents"
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

/// What one watched session's Live Activity shows. Lives outside the ActivityKit guard
/// so the planner can compare it (and CI can test that) without ActivityKit.
///
/// `state` stays the raw string: the widget resolves it through `SessionStateStyle`, so
/// a state a newer Mac invents renders as plain text instead of failing to decode.
/// `title` and `agents` are optional so an activity started by an older build still
/// decodes after an update.
struct SessionActivityDisplay: Codable, Hashable {
    var state: String
    /// The label the session list shows — alias, else the Claude Code session name.
    var title: String? = nil
    /// Live subagents on the session's Claude Code agent panel.
    var agents: Int? = nil
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

/// Live Activity payload for one watched session — the Dynamic Island / lock-screen
/// mirror of its agent state. `session` is the real dch name, the activity's identity;
/// what's displayed (including the label) is content, so a rename updates in place.
struct SessionActivityAttributes: ActivityAttributes {
    typealias ContentState = SessionActivityDisplay

    var machine: String
    var session: String
}
#endif
