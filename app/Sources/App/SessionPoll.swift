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

    /// #774: whether a poll moved the list. `last` is nil before the loop's first poll, which
    /// compares against what is shown: the first appearance's refresh lands after the task starts.
    static func changed<T: Equatable>(_ list: [T], last: [T]?, shown: [T]) -> Bool { list != (last ?? shown) }

    /// The wait before the next poll. `wait` is the one before this poll, nil for a poll
    /// taken at once. A change starts over at `fastest`; a still list doubles, to `slowest`.
    static func next(after wait: TimeInterval?, changed: Bool, mode: UpdateMode = .live) -> TimeInterval {
        guard let wait, !changed else { return fastest(mode) }
        return min(max(wait * 2, fastest(mode)), slowest(mode))
    }

    /// #963: a list under this old already answers a poll (re)started now.
    static let fresh: TimeInterval = 2

    /// #963: the wait before a poll task's first list. Before the screen's first refresh and
    /// handshake end, that refresh is the list. After, a restart lists at once, unless a list
    /// landed under `fresh` ago: at launch the scene turns active just after the first refresh.
    static func first(connected: Bool, listedAt: Date?, mode: UpdateMode, now: Date = Date()) -> TimeInterval? {
        guard connected else { return fastest(mode) }
        if let at = listedAt, now.timeIntervalSince(at) < fresh { return fastest(mode) }
        return nil
    }

    /// The wait after a failed poll: never faster than the backoff, never faster than before.
    static func failed(after wait: TimeInterval?) -> TimeInterval {
        max(wait ?? 0, failureBackoff)
    }
}

/// #775: the list the Mac pushes over its 0x2e watch stream, instead of the poll, while it lists
/// "watch" and the mode is Real-time.
@MainActor
enum SessionWatch {
    /// The stream, not the poll: Battery saver and Low Power Mode keep the poll.
    static func wanted(_ ops: Set<SessionVerb>, _ mode: UpdateMode) -> Bool { mode == .live && ops.contains(.watch) }

    /// A refused stream waits this long for the fresh 0x08 that may offer it again.
    static let retry: TimeInterval = 60
    /// The wait before reopening a dead stream, doubling to the poll's failure backoff. Settable for tests.
    static var reopen: TimeInterval = 1

    /// The same stable per-install id the snippets push sends; `{}` before first unlock.
    static var device: String? { SnippetPush.currentDevice()?.id }

    /// Applies each list, adopts each sidekick pattern, and reopens a dead stream (silence, a
    /// dropped socket, an unreachable Mac) with backoff, never while `ready` is false. True when
    /// the Mac refused it (error 0x13) or closed it cleanly: the caller polls. False once cancelled.
    static func run(_ t: SessionTransport, device: String?, ready: () -> Bool = { true },
                    apply: ([DchSession]) -> Void) async -> Bool {
        var wait: TimeInterval = 0
        while !Task.isCancelled {
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled else { return false }
            let backoff = min(max(wait * 2, reopen), SessionPoll.failureBackoff)
            guard ready() else { wait = backoff; continue }
            var heard = false
            do {
                for try await e in t.watch(device: device) {
                    heard = true
                    switch e {
                    case .list(let list): apply(list)
                    case .sidekick(let v): SidekickSync.pushed(v)
                    case .heartbeat: break
                    }
                }
                return !Task.isCancelled
            } catch TransportError.server {
                return true
            } catch let e as TransportError where e.isRefusal {
                return true   // #827: the poll takes over, shows it and waits for a refresh
            } catch {
                wait = heard ? reopen : backoff
            }
        }
        return false
    }
}
