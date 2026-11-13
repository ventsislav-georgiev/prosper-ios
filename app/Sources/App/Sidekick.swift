import Foundation
import SwiftUI
import UIKit
import os

// MARK: - Matching (#761: the Mac's AgentIsland.split, sidekickFind and SidekickMatch, ported)

extension DchSession {
    /// A sidekick's name or alias matches `pattern` (trimmed), an ICU regex searched
    /// case-insensitively. A pattern that is not a usable regex (see `SidekickMatch`) is
    /// matched as literal text, still ignoring case. An empty pattern means no split. Order
    /// is kept in both halves.
    static func split(_ list: [DchSession], pattern: String) -> (primary: [DchSession], sidekicks: [DchSession]) {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return (list, []) }
        let hits = sidekickFind(p, in: list.flatMap { [$0.name, $0.alias ?? ""] }).hits
        let tagged = zip(list, list.indices.map { hits[2 * $0] || hits[2 * $0 + 1] })
        return (tagged.filter { !$0.1 }.map(\.0), tagged.filter(\.1).map(\.0))
    }

    /// How a non-empty pattern is matched. Every case but `.regex` matches it as text.
    enum SidekickMatch: Equatable {
        case regex, invalid, matchesEmpty, slow

        var caption: String? {
            switch self {
            case .regex: nil
            case .invalid: "Not a valid regex: matched as text"
            case .matchesEmpty: "Matches every session: matched as text"
            case .slow: "Too slow on a session name: matched as text"
            }
        }
    }

    /// Settings' caption under the pattern field, none for an empty pattern. `names` are the
    /// last listed sessions' names and titles, so a pattern too slow on them says so first.
    static func sidekickCaption(_ pattern: String, names: [String]) -> String? {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : sidekickFind(p, in: names).how.caption
    }

    /// The list re-splits on main on every render, and an ICU regex can backtrack for
    /// seconds. Bounds, in this thread's CPU time: a split call stops its search at
    /// `sidekickDeadline`, as does the "" probe; a call slower than `sidekickSlowCall` per 16
    /// texts searched, or on any one text, adds to the pattern's tally, which may reach
    /// `sidekickSlowTotal`. Either flips the pattern to text for the life of the process.
    /// Vars only so a test can make the tally deterministic.
    static var sidekickDeadline: UInt64 = 10_000_000
    static var sidekickSlowCall: UInt64 = 1_000_000
    static var sidekickSlowTotal: UInt64 = 50_000_000

    /// Compiled once per trimmed pattern, under `sidekickLock`.
    /// ponytail: grows by one entry per distinct pattern typed; a few hundred tiny ones per run.
    private static let sidekickLock = NSLock()
    private static var sidekickCache: [String: (re: NSRegularExpression?, how: SidekickMatch, spent: UInt64)] = [:]

    /// Which of `texts` the trimmed, non-empty `p` finds, and how it was matched.
    private static func sidekickFind(_ p: String, in texts: [String]) -> (how: SidekickMatch, hits: [Bool]) {
        let cpu = { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
        let entry = sidekickLock.withLock { sidekickCache[p] }
        var (re, how) = (entry?.re, entry?.how ?? .invalid)
        if entry == nil {
            // Off the lock: two first callers may both probe, and the first to store wins.
            re = sidekickRegex(p)
            if let re {
                // An empty match would make every session a sidekick. The probe gets the
                // search's CPU deadline: `(x?|y?){32}\b` backtracks for a second on "" alone.
                how = .regex
                let start = cpu()
                re.enumerateMatches(in: "", options: .reportProgress, range: NSRange()) { r, _, stop in
                    if r != nil { how = .matchesEmpty; stop.pointee = true }
                    else if cpu() - start > sidekickDeadline { how = .slow; stop.pointee = true }
                }
            }
            (re, how) = sidekickLock.withLock {
                if sidekickCache[p] == nil { sidekickCache[p] = (re, how, 0) }
                return (sidekickCache[p]!.re, sidekickCache[p]!.how)
            }
        }
        var hits: [Bool] = []
        if let re, how == .regex {
            let start = cpu()
            var worst: UInt64 = 0
            for t in texts where how == .regex {
                var hit = false
                let t0 = cpu()
                // .reportProgress: ICU calls back inside a backtracking search, so the deadline
                // ends one catastrophic search. A zero-width match (\b, ^) is no hit, or it
                // would take every name.
                re.enumerateMatches(in: t, options: .reportProgress, range: NSRange(t.startIndex..., in: t)) { r, _, stop in
                    if let r, r.range.length > 0 { hit = true; stop.pointee = true }
                    else if cpu() - start > sidekickDeadline { how = .slow; stop.pointee = true }
                }
                hits.append(hit)
                worst = max(worst, cpu() - t0)
            }
            let spent = cpu() - start
            how = sidekickLock.withLock {
                guard var e = sidekickCache[p], e.how == .regex else { return sidekickCache[p]?.how ?? how }
                // Per 16 texts, so a cheap pattern over 100 sessions never counts; one name
                // over the whole budget still counts, however many cheap names dilute it.
                if worst > sidekickSlowCall || spent / UInt64(max(1, texts.count / 16)) > sidekickSlowCall { e.spent += spent }
                if how == .slow || e.spent > sidekickSlowTotal { e.how = .slow }
                sidekickCache[p] = e
                return e.how
            }
        }
        if how != .regex { hits = texts.map { $0.range(of: p, options: .caseInsensitive) != nil } }
        return (how, hits)
    }

    /// The trimmed pattern as a case-insensitive regex; nil when empty or not a valid regex.
    static func sidekickRegex(_ pattern: String) -> NSRegularExpression? {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : try? NSRegularExpression(pattern: p, options: .caseInsensitive)
    }
}

// MARK: - Sync with the Mac (#761)

/// The pattern kept the same as the Mac's over 0x2d sidekickSync: the newer `updated` wins on
/// both ends, a tie keeps the Mac's. Synced on connect, on coming to the front, when Settings
/// opens and a second after the last keystroke in its field; never on list polls. Only with a
/// Mac that lists "sidekick". A failure is only logged; the next trigger tries again.
@MainActor
enum SidekickSync {
    static let updatedKey = "sidekickPatternUpdated"
    /// The Mac's cap on a pattern it adopts, in UTF-8 bytes.
    static let maxBytes = 512
    /// Settable for tests.
    static var defaults = UserDefaults.standard
    static var debounce: TimeInterval = 1

    private static let log = Logger(subsystem: "eu.illegible.prosper", category: "sidekick")

    static func local() -> SidekickValue {
        SidekickValue(pattern: defaults.string(forKey: DchSession.sidekickKey) ?? DchSession.sidekickDefault,
                      updated: (defaults.object(forKey: updatedKey) as? NSNumber)?.int64Value ?? 0)
    }

    /// `s` cut to `maxBytes` of UTF-8 on a character boundary.
    static func capped(_ s: String) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var out = ""
        for c in s {
            guard out.utf8.count + c.utf8.count <= maxBytes else { break }
            out.append(c)
        }
        return out
    }

    /// A Settings edit: capped and stamped, then a sync once typing pauses. Stamped past the
    /// stored one too, so an edit after adopting a fast Mac clock's value still wins.
    static func edit(_ pattern: String, now: Date = Date()) {
        let old = local()
        let p = capped(pattern)
        guard p != old.pattern else { return }
        defaults.set(p, forKey: DchSession.sidekickKey)
        defaults.set(max(Int64((now.timeIntervalSince1970 * 1000).rounded()), old.updated &+ 1), forKey: updatedKey)
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            if !Task.isCancelled { kick() }
        }
    }

    /// A Mac's value (a 0x2d reply, or later a push): stored with its own stamp, never a new
    /// one, so it can't bounce back as a newer edit. Older than ours is ignored.
    static func adopt(_ v: SidekickValue) {
        let mine = local()
        guard v != mine, v.updated >= mine.updated else { return }
        defaults.set(v.pattern, forKey: DchSession.sidekickKey)
        defaults.set(v.updated, forKey: updatedKey)
    }

    static func sync(over t: SessionTransport) async throws {
        let mine = local()
        let winner = try await t.sidekickSync(mine)
        // An edit typed meanwhile is newer than both; its own sync carries it.
        guard local() == mine else { return }
        adopt(winner)
    }

    // MARK: Triggers

    private(set) static var mac: SessionTransport?
    private(set) static var running = false
    private static var again = false
    private static var pending: Task<Void, Never>?

    /// The handshake's ops: a Mac without "sidekick" never answers 0x2d, so it gets none.
    /// #775: one that lists "watch" pushes its pattern on the stream, so in Real-time connect
    /// and foreground send none; an edit still does.
    static func offer(_ ops: Set<SessionVerb>, over t: SessionTransport) {
        mac = ops.contains(.sidekick) ? t : nil
        watched = ops.contains(.watch)
        _ = foreground
        if !streamed { kick() }
    }

    private(set) static var watched = false
    private static var streamed: Bool { watched && UpdateMode.effective == .live }

    private static let foreground: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { if !streamed { kick() } }
    }

    /// #775: the Mac's pattern off the watch stream: adopted, unless ours is newer, which only
    /// a 0x2d takes to the Mac.
    static func pushed(_ v: SidekickValue) {
        if local().updated > v.updated { kick() } else { adopt(v) }
    }

    /// A sync, unless one runs: then one more after it.
    static func kick() {
        guard mac != nil else { return }
        guard !running else { again = true; return }
        running = true
        Task {
            repeat {
                again = false
                guard let mac else { break }
                do { try await sync(over: mac) } catch {
                    log.error("sidekick sync: \(error.localizedDescription, privacy: .public)")
                }
            } while again
            running = false
        }
    }
}

// MARK: - Segments (#1054)

/// #1054: the Sessions / Sidekicks switch as a UISegmentedControl. SwiftUI's segmented Picker
/// ignores `.disabled` on a segment; `setEnabled(_:forSegmentAt:)` dims it and VoiceOver reads it dimmed.
struct SegmentPicker: UIViewRepresentable {
    let titles: [String]
    let enabled: [Bool]
    @Binding var selection: Int

    final class Coordinator { var selection: Binding<Int>?; init() {} }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UISegmentedControl {
        let c = UISegmentedControl()
        let coordinator = context.coordinator
        c.addAction(UIAction { [weak c] _ in
            guard let c else { return }
            coordinator.selection?.wrappedValue = c.selectedSegmentIndex
        }, for: .valueChanged)
        return c
    }

    func updateUIView(_ c: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        update(c)
    }

    /// Titles, enabled flags and the selected index onto `c`; apart from the context so a test can call it.
    func update(_ c: UISegmentedControl) {
        if c.numberOfSegments != titles.count {
            c.removeAllSegments()
            for (i, t) in titles.enumerated() { c.insertSegment(withTitle: t, at: i, animated: false) }
        }
        for (i, t) in titles.enumerated() {
            c.setTitle(t, forSegmentAt: i)
            c.setEnabled(enabled[i], forSegmentAt: i)
        }
        c.selectedSegmentIndex = selection
    }

    /// #1054: as a section header, edge to edge with the rows, not inset by the header's own margins
    /// (as the Picker was); the header's 10 pt above and below kept.
    var header: some View { listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)) }

    /// The full width offered, as the Picker it replaces.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        let size = uiView.intrinsicContentSize
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }
}
