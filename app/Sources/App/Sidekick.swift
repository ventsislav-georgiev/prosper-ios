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
        splitNoted(list, pattern: pattern).split
    }

    /// #1502: split, and whether a session is a sidekick by its title alone (R1220-2), from one search.
    static func splitNoted(_ list: [DchSession], pattern: String) -> (split: (primary: [DchSession], sidekicks: [DchSession]), titleOnly: Bool) {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return ((list, []), false) }
        let hits = found(list, p).hits
        let tagged = zip(list, hits.map { $0.name || $0.title })
        return ((tagged.filter { !$0.1 }.map(\.0), tagged.filter(\.1).map(\.0)), hits.contains { !$0.name && $0.title })
    }

    /// What split searches for one session; `true` marks the title (sidekickFind).
    private static func texts(_ s: DchSession) -> [(text: String, title: Bool)] { [(s.name, false), (s.alias ?? "", false), (s.harness ?? "", true)] }

    /// #1502: per session, whether its name or alias matched and whether its title did.
    private static func found(_ list: [DchSession], _ p: String) -> (how: SidekickMatch, hits: [(name: Bool, title: Bool)]) {
        let r = sidekickFind(p, in: list.flatMap(texts))
        return (r.how, list.indices.map { (r.hits[3 * $0] || r.hits[3 * $0 + 1], r.hits[3 * $0 + 2]) })
    }

    /// R1220-2: the Sidekicks footer when splitNoted says titleOnly (the Mac's sidekickCaption line).
    static let titleOnlyNote = "Some sessions are here by their title, which Prosper does not show"

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
        return p.isEmpty ? nil : sidekickFind(p, in: names.map { ($0, false) }).how.caption
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
    /// #1502: this thread's CPU clock, a var so a test can count reads instead (the Mac's sidekickCPU).
    static var sidekickCPU: () -> UInt64 = { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// Compiled once per trimmed pattern, under `sidekickLock`.
    /// ponytail: grows by one entry per distinct pattern typed; a few hundred tiny ones per run.
    private static let sidekickLock = NSLock()
    private static var sidekickCache: [String: (re: NSRegularExpression?, how: SidekickMatch, spent: UInt64, titleSpent: UInt64)] = [:]

    /// Which of `texts` the trimmed, non-empty `p` finds, and how it was matched.
    private static func sidekickFind(_ p: String, in texts: [(text: String, title: Bool)]) -> (how: SidekickMatch, hits: [Bool]) {
        let cpu = sidekickCPU
        let entry = sidekickLock.withLock { sidekickCache[p] }
        var (re, how) = (entry?.re, entry?.how ?? .invalid)
        var titleSpentSoFar = entry?.titleSpent ?? 0
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
                if sidekickCache[p] == nil { sidekickCache[p] = (re, how, 0, 0) }
                titleSpentSoFar = sidekickCache[p]!.titleSpent
                return (sidekickCache[p]!.re, sidekickCache[p]!.how)
            }
        }
        let titlesAsText = titleSpentSoFar > sidekickSlowTotal
        var hits = [Bool](repeating: false, count: texts.count)
        if let re, how == .regex {
            let start = cpu()
            var worst: UInt64 = 0
            // One search; nil when it ran past the call's deadline.
            func find(_ t: String) -> Bool? {
                var hit: Bool? = false
                // .reportProgress: ICU calls back inside a backtracking search, so the deadline
                // ends one catastrophic search. A zero-width match (\b, ^) is no hit, or it
                // would take every name.
                re.enumerateMatches(in: t, options: .reportProgress, range: NSRange(t.startIndex..., in: t)) { r, _, stop in
                    if let r, r.range.length > 0 { hit = true; stop.pointee = true }
                    else if cpu() - start > sidekickDeadline { hit = nil; stop.pointee = true }
                }
                return hit
            }
            let names = texts.indices.filter { !texts[$0].title }
            for i in names where how == .regex {
                let t0 = cpu()
                if let hit = find(texts[i].text) { hits[i] = hit } else { how = .slow }
                worst = max(worst, cpu() - t0)
            }
            let spent = cpu() - start   // names and aliases only
            // #1502 (R1210-a): titles after, shortest first, in what is left of the deadline; one past it is no hit
            // (nor the titles after it) and never flips the pattern. Their own tally ends only their regex search.
            let titles = texts.indices.filter { texts[$0].title && !texts[$0].text.isEmpty }.sorted { texts[$0].text.utf8.count < texts[$1].text.utf8.count }
            var (titleWorst, titleSpent, late): (UInt64, UInt64, Bool) = (0, 0, false)
            if titlesAsText {
                for i in titles { hits[i] = texts[i].text.range(of: p, options: .caseInsensitive) != nil }
            } else if how == .regex, !titles.isEmpty {
                let t1 = cpu()
                for i in titles {
                    let t0 = cpu()
                    guard let hit = find(texts[i].text) else { late = true; break }
                    hits[i] = hit
                    titleWorst = max(titleWorst, cpu() - t0)
                }
                titleSpent = cpu() - t1
            }
            how = sidekickLock.withLock {
                guard var e = sidekickCache[p], e.how == .regex else { return sidekickCache[p]?.how ?? how }
                // Per 16 texts, so a cheap pattern over 100 sessions never counts; one name
                // over the whole budget still counts, however many cheap names dilute it.
                if worst > sidekickSlowCall || spent / UInt64(max(1, names.count / 16)) > sidekickSlowCall { e.spent += spent }
                if late || titleWorst > sidekickSlowCall || titleSpent / UInt64(max(1, titles.count / 16)) > sidekickSlowCall { e.titleSpent += titleSpent }
                if how == .slow || e.spent > sidekickSlowTotal { e.how = .slow }
                sidekickCache[p] = e
                return e.how
            }
        }
        if how != .regex { hits = texts.map { $0.text.range(of: p, options: .caseInsensitive) != nil } }
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
