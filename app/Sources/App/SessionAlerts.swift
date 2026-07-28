import Foundation
import SwiftUI
import UserNotifications

/// Which sessions the user asked to be pinged about, persisted across launches.
///
/// Keyed by machine + session name, so the same session name on two Macs is two
/// switches. The demo machine has no id and keys under `demo`.
@MainActor
final class SessionAlerts: ObservableObject {
    static let storeKey = "sessionAlerts.v1"

    @Published private(set) var watched: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watched = Set(defaults.stringArray(forKey: Self.storeKey) ?? [])
    }

    static func key(machine: UUID?, session: String) -> String {
        "\(machine?.uuidString ?? "demo")/\(session)"
    }

    func isOn(machine: UUID?, session: String) -> Bool {
        watched.contains(Self.key(machine: machine, session: session))
    }

    /// Flip the switch and report the new value, so the caller can ask for
    /// notification permission only when someone actually turns one on.
    @discardableResult
    func toggle(machine: UUID?, session: String) -> Bool {
        let k = Self.key(machine: machine, session: session)
        let on = !watched.contains(k)
        if on { watched.insert(k) } else { watched.remove(k) }
        defaults.set(Array(watched), forKey: Self.storeKey)
        return on
    }

    /// Names watched on this machine, for the poller and the Live Activities.
    func names(machine: UUID?, in sessions: [DchSession]) -> Set<String> {
        Set(sessions.map(\.name).filter { isOn(machine: machine, session: $0) })
    }

    /// Drop switches for sessions this machine no longer has. Two reasons: a name reused
    /// weeks later shouldn't come back mysteriously pre-watched, and the store shouldn't
    /// collect one dead key per session ever created. Only ever called with a list that
    /// actually came back from the Mac — a failed poll must not clear anything.
    func prune(machine: UUID?, alive: [DchSession]) {
        let prefix = "\(machine?.uuidString ?? "demo")/"
        let keep = Set(alive.map { Self.key(machine: machine, session: $0.name) })
        let kept = watched.filter { !$0.hasPrefix(prefix) || keep.contains($0) }
        guard kept.count != watched.count else { return }
        watched = kept
        defaults.set(Array(watched), forKey: Self.storeKey)
    }
}

/// One thing worth interrupting the user over.
struct SessionAlert: Equatable {
    let session: String
    let style: SessionStateStyle
}

/// Turns a stream of session-list snapshots into alerts — the pure half of the watcher,
/// so the interesting rules (no ping on the first sight of a session, no ping for the
/// session you're staring at, no ping twice for a flapping state) are testable without
/// a network or a clock.
///
/// Hot path: `step` runs on every poll for every session, so it stays O(sessions) with
/// no allocation per session beyond the two dictionaries it already owns.
/// A reference type on purpose: the view holds it in `@State` and feeds it on every poll,
/// and a struct's mutation there would invalidate the whole session list five times a
/// second for bookkeeping nobody renders.
final class SessionAlertEngine {
    /// How often the watcher asks the Mac for states while the app is in front. One
    /// small list round-trip; the answer also refreshes the visible rows, and it is the
    /// only thing keeping the working/idle labels honest — so this doubles as how stale a
    /// row can look.
    static let pollInterval: TimeInterval = 3
    /// After a failed poll, back off — an asleep Mac shouldn't be dialed every 5s.
    static let failureBackoff: TimeInterval = 20
    /// Same session, same state: don't ping again inside this window. dch derives state
    /// from the rendered screen, so a prompt that redraws can flap blocked→working→blocked.
    static let cooldown: TimeInterval = 60

    private var lastState: [String: String] = [:]
    private var lastPing: [String: (state: String, at: TimeInterval)] = [:]

    /// What the engine is remembering. Only interesting to the test that pins the
    /// bookkeeping to the live sessions instead of every session ever seen.
    var trackedCount: Int { lastState.count + lastPing.count }

    /// Feed a fresh list; get back what to ping about.
    ///
    /// - `isWatched`: the user's switch for that session.
    /// - `attached`: the session currently open on screen — its state changes are
    ///   visible already, so pinging about them is noise.
    /// Drop the baseline, so the next `step` only re-seeds and pings for nothing. Called
    /// when the watcher restarts after the app was away: whatever changed while we
    /// couldn't poll is already on screen by the time the user sees it, and a burst of
    /// banners for it is noise, not news.
    func forget() {
        lastState.removeAll()
        lastPing.removeAll()
    }

    func step(_ sessions: [DchSession], now: TimeInterval,
              isWatched: (String) -> Bool, attached: String? = nil) -> [SessionAlert] {
        var alerts: [SessionAlert] = []
        var seen: [String: String] = Dictionary(minimumCapacity: sessions.count)
        for s in sessions {
            let state = s.state ?? ""
            seen[s.name] = state
            let previous = lastState[s.name]
            // First sight of a session seeds the baseline: turning the switch on while
            // an agent already waits must not fire a ping for something that isn't new.
            guard let previous, previous != state else { continue }
            guard isWatched(s.name), s.name != attached else { continue }
            guard let style = SessionStateStyle(state), style.ping(session: s.name) != nil else { continue }
            if let last = lastPing[s.name], last.state == state, now - last.at < Self.cooldown { continue }
            lastPing[s.name] = (state, now)
            alerts.append(SessionAlert(session: s.name, style: style))
        }
        // Drop vanished sessions so a name reused later starts from a clean baseline
        // (and neither dictionary grows forever on a long-lived screen).
        lastState = seen
        if lastPing.count > seen.count { lastPing = lastPing.filter { seen[$0.key] != nil } }
        return alerts
    }
}

/// Local notifications for session alerts. Local, not push: the pings land while Prosper
/// is running (foreground, or the few seconds iOS grants after a background switch).
/// Waking a suspended app needs APNs from the Mac, which is a separate piece of plumbing.
enum SessionPings {
    /// Ask once, when the user turns their first switch on. Returns false if denied —
    /// the Live Activity still works, it's a different permission.
    @discardableResult
    static func authorize() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// iOS swallows banners while the app is in front unless we ask for them. The list can
    /// be open on one session while another starts waiting, so we want them.
    static func presentInForeground() {
        UNUserNotificationCenter.current().delegate = presenter
    }

    private static let presenter = ForegroundPresenter()

    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions { [.banner, .sound] }
    }

    static func fire(_ alert: SessionAlert, machine: String) {
        guard let body = alert.style.ping(session: alert.session) else { return }
        let c = UNMutableNotificationContent()
        c.title = machine
        c.body = body
        c.sound = .default
        // Same session + state replaces its own older banner instead of stacking.
        let id = "session-alert/\(machine)/\(alert.session)/\(alert.style.rawValue)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}
