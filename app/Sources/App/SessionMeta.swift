// The keyboards build the data types without SwiftUI (#735); `SessionRow` is the app's.
#if KEYBOARD
import Foundation
#else
import SwiftUI
#endif

/// A session's PRs as the Mac's list reports them (its `meta` key), drawn under the row
/// the way the Mac's Agent Island draws them. Any other key, `tasks` included, is ignored.
struct SessionMeta: Hashable {
    struct PR: Hashable {
        var url: URL?           // nil unless https://github.com/…, then the chip is a label
        var repo: String        // "owner/repo"
        var num: Int?
        var title: String       // untrusted: plain text, newlines collapsed

        /// "prosper#12": the repo's name part, then the number when there is one.
        var chip: String { chip(maxRepo: nil) }

        /// The chip with a repo name past `maxRepo` characters cut to fit, "…" last;
        /// nil keeps it whole.
        /// #1530: `bare` drops the repo when there is a number: "#12".
        func chip(maxRepo: Int?, bare: Bool = false) -> String {
            if bare, let n = num { return "#\(n)" }
            let name = repo.split(separator: "/").last.map(String.init) ?? repo
            let short = maxRepo.map { name.count > $0 ? String(name.prefix($0 - 1)) + "…" : name } ?? name
            return num.map { "\(short)#\($0)" } ?? short
        }

    }

    var open: [PR] = []
    var merged: Int?

    static let maxChips = 3
    static let maxRepo = 18    // the Mac's cut

    /// nil when `json` is not an object or leaves nothing to draw. A field of the wrong
    /// type or a negative count is dropped on its own; it never costs the row.
    init?(json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        if let p = o["prs"] as? [String: Any] {
            merged = Self.count(p["merged"])
            // ponytail: at most 50 kept, so beyond 50 open PRs "+M" undercounts; send a total if that matters.
            open = Array(((p["open"] as? [Any]) ?? []).lazy.compactMap { e -> PR? in
                guard let e = e as? [String: Any], let repo = e["repo"] as? String, !repo.isEmpty else { return nil }
                return PR(url: Self.pullURL(e["url"]), repo: Self.plain(String(repo.prefix(100))),
                          num: Self.count(e["num"]).flatMap { $0 <= 9_999_999 ? $0 : nil },   // a chip stays chip-sized
                          title: Self.plain(e["title"] as? String ?? ""))
            }.prefix(50))
        }
        if open.isEmpty && (merged ?? 0) == 0 { return nil }
    }

    init(open: [PR] = [], merged: Int? = nil) {
        (self.open, self.merged) = (open, merged)
    }

    /// A JSON integer >= 0; nil for anything else (bools included: JSONSerialization
    /// hands them over as NSNumber, and `true as? Int` is 1).
    static func count(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let i = v as? Int, i >= 0 else { return nil }
        return i
    }

    /// The Mac already sends only github.com pull URLs; this is the cheap second check.
    static func pullURL(_ v: Any?) -> URL? {
        guard let s = v as? String, let u = URL(string: s), u.scheme == "https", u.host == "github.com" else { return nil }
        return u
    }

    /// One line of plain text: line breaks and tabs become spaces, other control characters
    /// (U+0000 included) and bidi controls go, so a title can't reorder what is drawn
    /// around it.
    static func plain(_ s: String) -> String {
        let bidi = Set("\u{200E}\u{200F}\u{061C}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}".unicodeScalars)
        var out = String.UnicodeScalarView()
        for u in s.prefix(200).unicodeScalars where !bidi.contains(u) {
            if "\n\r\t\u{85}\u{2028}\u{2029}".unicodeScalars.contains(u) { out.append(" ") }
            else if u.value >= 0x20, !(0x7F...0x9F).contains(u.value) { out.append(u) }
        }
        return String(out)
    }

    /// Every count drawn: "99999+" above 99999, so a runaway number can't squeeze the row.
    static func count(_ n: Int) -> String { n > 99_999 ? "99999+" : "\(n)" }


    /// #1518: what VoiceOver reads for a count, the Mac's words: "1 merged pull request",
    /// "75 merged pull requests"; "99999+" above 99999, as drawn.
    static func words(_ n: Int, _ noun: String) -> String { "\(count(n)) \(noun)\(n == 1 ? "" : "s")" }

    /// #1518: line 2 after the state word, as the Mac's sidebar row draws it: the merged
    /// count, the open-PR count, then PR chips and a "+N" for the rest.
    struct DetailLine: Hashable {
        var merged: Int?, open: Int?, chips: [String] = [], more: Int?
    }

    /// #1518: the line-2 variants ViewThatFits tries, widest first, folding in the Mac's
    /// order: 3, 2, 1 chips (repos cut to 18), then the open-count group alone, then the
    /// merged count, then nothing. The state word is outside them, so it never folds.
    func detailLines(_ d: RowDetails) -> [DetailLine] {
        let merged = d.merged ? merged.flatMap { $0 > 0 ? $0 : nil } : nil
        let open = d.openPRs && !open.isEmpty ? open : []
        // #1530: "#N" when every open PR is in one repo, "repo#N" across several.
        let bare = Set(open.map(\.repo)).count == 1
        var lines = stride(from: min(open.count, Self.maxChips), through: 1, by: -1).map { k in
            DetailLine(merged: merged, open: open.count, chips: open.prefix(k).map { $0.chip(maxRepo: Self.maxRepo, bare: bare) },
                       more: open.count > k ? open.count - k : nil)
        }
        for l in [DetailLine(merged: merged, open: open.isEmpty ? nil : open.count), DetailLine(merged: merged), DetailLine()]
        where lines.last != l { lines.append(l) }
        return lines
    }
}

/// Which details a session row draws besides its title, set in Settings › Row details and
/// kept per device. Labels and defaults match the Mac's Row details. #1518: State hides the
/// state word only; the mark stays, as on the Mac.
struct RowDetails: Equatable {
    enum Key {
        static let state = "sessionRow.state"
        static let agents = "sessionRow.agents"
        static let openPRs = "sessionRow.openPRs"
        static let merged = "sessionRow.merged"
        static let model = "sessionRow.model"
        static let effort = "sessionRow.effort"
        static let age = "sessionRow.age"
    }

    var state = true, agents = true, openPRs = true, merged = true
    var model = true, effort = true, age = true   // #1532
}

/// #1518: what a session row offers by touch, the swipe and the long-press menu: the
/// actions the old inline pencil, restart and stop buttons ran, and each open PR to open.
enum SessionRowAction: Hashable {
    case rename, restart, stop
    case openPR(chip: String, url: URL)
}

extension DchSession {
    /// What VoiceOver reads for the row: the title, then only the details shown, in the
    /// order of the Row details toggles. #1532: the model, "high effort", "active 5 minutes ago".
    func rowAccessibility(_ d: RowDetails, now: Date = Date()) -> String {
        let model = d.model ? self.model : nil
        let effort = d.effort ? effort.map { "\($0) effort" } : nil
        let agents: String? = d.agents && self.agents > 0 ? SessionMeta.words(self.agents, "agent") : nil
        let merged: String? = d.merged ? meta?.merged.flatMap { $0 > 0 ? SessionMeta.words($0, "merged pull request") : nil } : nil
        let open = d.openPRs ? meta?.open.count ?? 0 : 0
        let prs: String? = open > 0 ? SessionMeta.words(open, "open pull request") : nil
        return [title, model, effort, SessionStateStyle(state)?.label, agents, merged, prs, age(d, now: now)?.spoken]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// #1532: line 1's badges, as the Mac draws them: the model, then the effort.
    enum Badge: Hashable { case model(String), effort(String) }

    /// #1532: the badge variants ViewThatFits tries as line 1 narrows, the Mac's order: both,
    /// the effort alone, none. A model hidden by its toggle leaves the effort alone, as on the Mac.
    func badgeFolds(_ d: RowDetails) -> [[Badge]] {
        let all = [d.model ? model.map(Badge.model) : nil, d.effort ? effort.map(Badge.effort) : nil].compactMap { $0 }
        return all.count == 2 ? [all, [all[1]], []] : all.isEmpty ? [[]] : [all, []]
    }

    /// #1532: the age at line 2's end, the Mac's `AgentIsland.age` (now, 4m, 2h, 3d, 1y; whole units
    /// rounded down, years capped at 99) and its spoken words. None on a working row, as on the Mac.
    func age(_ d: RowDetails, now: Date) -> (short: String, spoken: String)? {
        guard d.age, let activity, state != "working" else { return nil }
        return Self.age(now.timeIntervalSince1970 - TimeInterval(activity))
    }

    static func age(_ seconds: TimeInterval) -> (short: String, spoken: String) {
        // Also NaN and a clock that moved back (a stamp in the future).
        guard seconds >= 60 else { return ("now", "active just now") }
        let s = Int(min(seconds, 1e15))
        let (n, unit): (Int, String) = s < 3600 ? (s / 60, "minute") : s < 86400 ? (s / 3600, "hour")
            : s < 365 * 86400 ? (s / 86400, "day") : (min(s / (365 * 86400), 99), "year")
        return ("\(n)\(unit.prefix(1))", "active \(SessionMeta.words(n, unit)) ago")
    }

    /// #1518: Rename always; Restart (on `.restart`) and Stop unless a verb already runs on
    /// it; then "Open repo#12" for each open PR with a link.
    func rowActions(ops: Set<SessionVerb>, busy: Bool) -> [SessionRowAction] {
        var a: [SessionRowAction] = [.rename]
        if !busy { a += (ops.contains(.restart) ? [.restart] : []) + [.stop] }
        return a + (meta?.open ?? []).compactMap { pr in pr.url.map { .openPR(chip: pr.chip, url: $0) } }
    }
}

#if !KEYBOARD
/// #1518: a session row as the Mac's sidebar draws it, for a narrow touch screen: the
/// state mark, then line 1 the title and the robot-glyph + N capsule (#1547), line 2 the state word, the
/// merged and open counts and the PR chips, folding (`detailLines`) before the title or
/// the state word lose room. Nothing animates and the chips are inert: a tap anywhere
/// opens the session; actions live in the list's swipe and long-press menu.
struct SessionRow: View {
    let session: DchSession
    @AppStorage(RowDetails.Key.state) private var state = RowDetails().state
    @AppStorage(RowDetails.Key.agents) private var agents = RowDetails().agents
    @AppStorage(RowDetails.Key.openPRs) private var openPRs = RowDetails().openPRs
    @AppStorage(RowDetails.Key.merged) private var merged = RowDetails().merged
    @AppStorage(RowDetails.Key.model) private var model = RowDetails().model
    @AppStorage(RowDetails.Key.effort) private var effort = RowDetails().effort
    @AppStorage(RowDetails.Key.age) private var age = RowDetails().age
    @ScaledMetric(relativeTo: .subheadline) private var glyphWidth: CGFloat = 14
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The Mac's state mark: the state's glyph, "○" with no known state.
    static func mark(_ s: SessionStateStyle?) -> String { s?.glyph ?? "\u{25CB}" }

    /// #1532: the minute tick redraws the age and the label; the list has no tick of its own.
    var body: some View {
        TimelineView(.everyMinute) { ctx in content(now: Self.drawDate(tick: ctx.date)) }
    }

    /// #1532: the time the row's age is drawn at: the clock, as a tick's date is its minute's start.
    static func drawDate(tick: Date, clock: Date = Date()) -> Date { max(tick, clock) }

    @ViewBuilder private func content(now: Date) -> some View {
        let d = RowDetails(state: state, agents: agents, openPRs: openPRs, merged: merged, model: model, effort: effort, age: age)
        let shownAge = session.age(d, now: now)
        let style = SessionStateStyle(session.state)
        let lines = session.meta?.detailLines(d) ?? [SessionMeta.DetailLine()]
        let big = typeSize.isAccessibilitySize
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: Self.mark(style))
                .font(.subheadline.bold())
                .foregroundStyle(style?.tint ?? Color(uiColor: .tertiaryLabel))
                .frame(width: glyphWidth)
            VStack(alignment: .leading, spacing: 3) {
                if big {
                    // Accessibility sizes: nothing shares a line with the title or the
                    // state word, and both may wrap, so both always show.
                    Text(session.title).fontWeight(.medium).lineLimit(2)
                    if d.agents, session.agents > 0 { Self.agentsCapsule(session.agents) }
                    // #1532: the badges' own line folds too: drawn whole, the fixed-size pills ran past the row.
                    if session.badgeFolds(d).first?.isEmpty == false {
                        ViewThatFits(in: .horizontal) {
                            ForEach(session.badgeFolds(d), id: \.self) { Self.badges($0) }
                        }
                    }
                } else {
                    // #1532: the badges fold (badgeFolds) while the title keeps its first 8 characters.
                    ViewThatFits(in: .horizontal) {
                        ForEach(session.badgeFolds(d), id: \.self) { b in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Self.title(session.title)
                                if d.agents, session.agents > 0 { Self.agentsCapsule(session.agents).layoutPriority(1) }
                                if !b.isEmpty { Self.badges(b).layoutPriority(1) }
                            }
                        }
                    }
                }
                let layout = big ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                // No line 2 when every detail on it is off or empty.
                if (d.state && style != nil) || lines != [SessionMeta.DetailLine()] || shownAge != nil { layout {
                    if d.state, let style {
                        Text(style.label).foregroundStyle(style == .blocked ? style.tint : .secondary)
                            .lineLimit(big ? 2 : 1).layoutPriority(1)
                    }
                    ViewThatFits(in: .horizontal) {
                        ForEach(lines, id: \.self) { Self.detailLine($0) }
                    }
                    if let age = shownAge {
                        if !big { Spacer(minLength: 0) }
                        Text(verbatim: age.short).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize().layoutPriority(1)
                    }
                }
                .font(.footnote) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.rowAccessibility(d, now: now))
        .accessibilityActions {
            ForEach(session.rowActions(ops: [], busy: true), id: \.self) { a in
                if case let .openPR(chip, url) = a { Button("Open \(chip)") { openURL(url) } }
            }
        }
    }

    /// One line-2 variant: the counts as plain text, then the soft chips and "+N"; never cut.
    static func detailLine(_ l: SessionMeta.DetailLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let n = l.merged { count("arrow.triangle.merge", n).foregroundStyle(.secondary) }
            if let n = l.open { count("arrow.triangle.pull", n).foregroundStyle(.blue) }
            ForEach(Array(l.chips.enumerated()), id: \.offset) { _, c in chip(c, amber: true) }
            if let more = l.more { chip("+\(more)", amber: true) }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private static func count(_ symbol: String, _ n: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Image(systemName: symbol).imageScale(.small)
            Text(verbatim: SessionMeta.count(n))
        }
        .font(.caption2.monospaced())
    }

    /// #1530: the one chip material, as before #1518: a soft filled capsule, monospaced
    /// caption, no stroke. PR chips tint the text amber. #1532: an effort chip swaps the wash
    /// (and `primary` the text).
    private static func chip(_ s: String, amber: Bool = false, primary: Bool = false,
                             wash: Color = Color.primary.opacity(0.1)) -> some View {
        Text(verbatim: s)
            .font(.caption2.monospaced().weight(.medium))
            .foregroundStyle(amber ? AnyShapeStyle(SessionStateStyle.blocked.tint) : primary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(wash, in: Capsule())
    }

    /// #1532: the title, whose ideal width is its first 8 characters (all of a shorter one), so a
    /// badge fold fits only while that much of the name still shows; drawn, it takes all the room left.
    private static func title(_ t: String) -> some View {
        ZStack(alignment: .leading) {
            Text(verbatim: t.count > 8 ? t.prefix(8) + "\u{2026}" : t).fontWeight(.medium).lineLimit(1).hidden()
            Text(verbatim: t).fontWeight(.medium).lineLimit(1).truncationMode(.middle).frame(idealWidth: 0, alignment: .leading)
        }
    }

    /// #1532: the model (neutral, cut in the middle past 16 characters, as the Mac cuts it) then the effort, washed by level as on the
    /// Mac: low to high blue at rising strength, xhigh and max magenta (the Mac's opacities plus the
    /// 0.04 the neutral chip has over the Mac's).
    static func badges(_ b: [DchSession.Badge]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(b, id: \.self) { badge in
                switch badge {
                case .model(let m): chip(m.count > 16 ? m.prefix(8) + "\u{2026}" + m.suffix(7) : m).fixedSize()
                case .effort(let e):
                    let (tint, k): (Color, Double) = switch e {
                    case "low": (.blue, 0.10)
                    case "medium": (.blue, 0.16)
                    case "high": (.blue, 0.28)
                    case "xhigh": (Color(uiColor: .magenta), 0.22)
                    default: (Color(uiColor: .magenta), 0.36)
                    }
                    chip(e, primary: e != "low", wash: tint.opacity(k)).fixedSize()
                }
            }
        }
    }

    static func agentsCapsule(_ n: Int) -> some View {
        HStack(spacing: 3) {   // #1547: the drawn robot (not the emoji), centred with the count
            RobotGlyph()
            Text(verbatim: SessionMeta.count(n))
        }
        .font(.caption2.monospaced().weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.primary.opacity(0.1), in: Capsule())
    }
}
#endif
