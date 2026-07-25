import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// What to do with the Live Activities for one fresh session list: which to start, which
/// to update, which to take off the island. Pure, so the two rules that are easy to get
/// wrong — the slot cap and "done is terminal" — are testable without ActivityKit (which
/// exists on no simulator or Catalyst build we can run in CI).
struct SessionActivityPlan: Equatable {
    var start: [String] = []
    var update: [String] = []
    var end: [String] = []

    var isEmpty: Bool { start.isEmpty && update.isEmpty && end.isEmpty }

    /// - `shown`: session → the state its live activity is currently displaying.
    /// - `limit`: how many activities one machine may hold at once.
    static func make(sessions: [DchSession], watched: Set<String>,
                     shown: [String: String], limit: Int) -> SessionActivityPlan {
        var plan = SessionActivityPlan()
        let alive = Set(sessions.map(\.name))
        // Slots already spent by activities we're keeping.
        var live = shown.keys.filter { watched.contains($0) && alive.contains($0) }.count
        for s in sessions where watched.contains(s.name) {
            let state = s.state ?? ""
            let finished = SessionStateStyle(state) == .done
            if let displayed = shown[s.name] {
                // `done` is terminal — end it (it lingers on the lock screen) instead of
                // holding a slot for a session that will never change again.
                if finished {
                    plan.end.append(s.name)
                    live -= 1
                } else if displayed != state {
                    plan.update.append(s.name)
                }
            } else if !finished, live < limit {
                live += 1
                plan.start.append(s.name)
            }
        }
        // Bell switched off, or the session is gone → off the island immediately.
        for name in shown.keys.sorted() where !watched.contains(name) || !alive.contains(name) {
            plan.end.append(name)
        }
        return plan
    }
}

/// Drives the Dynamic Island / lock-screen Live Activities for watched sessions.
///
/// One activity per watched session, started when its bell goes on and ended when the
/// bell goes off, the session disappears, or it finishes. Updates flow from the same poll
/// that produces the pings, so the island tracks `working → needs you → done` while
/// Prosper is running.
///
/// Live Activities are iPhone-only, so on Mac Catalyst (and iOS 16.0/16.1) every call
/// here is a no-op and the rest of the watcher works unchanged.
@MainActor
final class SessionLiveActivities {
    static let shared = SessionLiveActivities()

    /// Cap what one machine can occupy — someone watching twelve sessions doesn't want
    /// twelve activities fighting over one cutout.
    static let maxActive = 3
    /// Mark the content stale a little past the next poll, so a suspended app leaves a
    /// visibly stale island instead of a confidently wrong one.
    static let staleAfter = SessionAlertEngine.pollInterval * 4
    /// How long a finished session lingers on the lock screen before it's dismissed.
    static let dismissAfter: TimeInterval = 60 * 15

    /// Bring the activities in line with a fresh session list. Idempotent: call it on
    /// every poll.
    func sync(machine: String, sessions: [DchSession], watched: Set<String>) async {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard #available(iOS 16.2, *) else { return }
        await apply(machine: machine, sessions: sessions, watched: watched)
        #endif
    }

    /// Tear everything down (leaving the machine, or all bells off).
    func endAll() async {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<SessionActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    @available(iOS 16.2, *)
    private func apply(machine: String, sessions: [DchSession], watched: Set<String>) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let live = Dictionary(
            Activity<SessionActivityAttributes>.activities
                .filter { $0.attributes.machine == machine }
                .map { ($0.attributes.session, $0) },
            uniquingKeysWith: { a, _ in a })
        let plan = SessionActivityPlan.make(sessions: sessions, watched: watched,
                                            shown: live.mapValues { $0.content.state.state },
                                            limit: Self.maxActive)
        guard !plan.isEmpty else { return }
        let states = Dictionary(sessions.map { ($0.name, $0.state ?? "") }, uniquingKeysWith: { a, _ in a })

        for name in plan.start {
            _ = try? Activity.request(attributes: SessionActivityAttributes(machine: machine, session: name),
                                      content: content(states[name] ?? ""), pushType: nil)
        }
        for name in plan.update {
            await live[name]?.update(content(states[name] ?? ""))
        }
        for name in plan.end {
            guard let activity = live[name] else { continue }
            // A finished session lingers; one whose bell went off goes now.
            if SessionStateStyle(states[name]) == .done {
                await activity.end(content(states[name] ?? ""),
                                   dismissalPolicy: .after(Date().addingTimeInterval(Self.dismissAfter)))
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    @available(iOS 16.2, *)
    private func content(_ state: String) -> ActivityContent<SessionActivityAttributes.ContentState> {
        ActivityContent(state: SessionActivityAttributes.ContentState(state: state),
                        staleDate: Date().addingTimeInterval(Self.staleAfter))
    }
    #endif
}
