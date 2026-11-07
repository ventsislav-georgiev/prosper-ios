import Foundation

/// Settings › Updates (#764): how live the app keeps things. Low Power Mode is Battery saver
/// while it's on, whatever the setting. The raw values go to the Worker as they are.
enum UpdateMode: String, CaseIterable, Identifiable {
    case live, saver
    static let key = "updateMode"
    var id: String { rawValue }
    var title: String { self == .live ? "Real-time" : "Battery saver" }

    /// The mode in force: `stored` (absent or unknown reads as Real-time), saver in Low Power Mode.
    static func resolve(stored: String?, lowPower: Bool) -> UpdateMode {
        lowPower ? .saver : stored.flatMap(UpdateMode.init(rawValue:)) ?? .live
    }

    /// The mode in force now: the poll, the push tokens, and later the watch stream go by it.
    static var effective: UpdateMode {
        resolve(stored: UserDefaults.standard.string(forKey: key), lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// #771: how long an open terminal keeps streaming in the background before it detaches.
    /// Real-time rides out a quick app switch; Battery saver stops parsing output nobody sees.
    var detachGrace: Duration { self == .live ? .seconds(30) : .zero }
}

/// The session list's poll (#764): fast while the list moves, slower while it doesn't.
enum SessionPoll {
    /// The wait after a change, and after a list taken at once (a return, a verb).
    static func fastest(_ mode: UpdateMode) -> TimeInterval { mode == .live ? 5 : 15 }
    /// The longest a still list waits: a state label at most this old while the user looks.
    static func slowest(_ mode: UpdateMode) -> TimeInterval { mode == .live ? 30 : 120 }
    /// An asleep or unreachable Mac: stop hammering.
    static let failureBackoff: TimeInterval = 20

    /// The wait before the next poll. `wait` is the one before this poll, nil for a poll
    /// taken at once. A change starts over at `fastest`; a still list doubles, to `slowest`.
    static func next(after wait: TimeInterval?, changed: Bool, mode: UpdateMode = .live) -> TimeInterval {
        guard let wait, !changed else { return fastest(mode) }
        return min(max(wait * 2, fastest(mode)), slowest(mode))
    }

    /// The wait after a failed poll: never faster than the backoff, never faster than before.
    static func failed(after wait: TimeInterval?) -> TimeInterval {
        max(wait ?? 0, failureBackoff)
    }
}
