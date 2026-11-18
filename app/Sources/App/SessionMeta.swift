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
        func chip(maxRepo: Int?) -> String {
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
        var lines = stride(from: min(open.count, Self.maxChips), through: 1, by: -1).map { k in
            DetailLine(merged: merged, open: open.count, chips: open.prefix(k).map { $0.chip(maxRepo: Self.maxRepo) },
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
    }

    var state = true, agents = true, openPRs = true, merged = true
}

/// #1518: what a session row offers by touch, the swipe and the long-press menu: the
/// actions the old inline pencil, restart and stop buttons ran, and each open PR to open.
enum SessionRowAction: Hashable {
    case rename, restart, stop
    case openPR(chip: String, url: URL)
}

extension DchSession {
    /// What VoiceOver reads for the row: the title and state, then only the details shown,
    /// in the Mac's words.
    func rowAccessibility(_ d: RowDetails) -> String {
        let agents: String? = d.agents && self.agents > 0 ? SessionMeta.words(self.agents, "agent") : nil
        let merged: String? = d.merged ? meta?.merged.flatMap { $0 > 0 ? SessionMeta.words($0, "merged pull request") : nil } : nil
        let open = d.openPRs ? meta?.open.count ?? 0 : 0
        let prs: String? = open > 0 ? SessionMeta.words(open, "open pull request") : nil
        return [title, SessionStateStyle(state)?.label, agents, merged, prs].compactMap { $0 }.joined(separator: ", ")
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
/// state mark, then line 1 the title and the "🤖 N" capsule, line 2 the state word, the
/// merged and open counts and the PR chips, folding (`detailLines`) before the title or
/// the state word lose room. Nothing animates and the chips are inert: a tap anywhere
/// opens the session; actions live in the list's swipe and long-press menu.
struct SessionRow: View {
    let session: DchSession
    @AppStorage(RowDetails.Key.state) private var state = RowDetails().state
    @AppStorage(RowDetails.Key.agents) private var agents = RowDetails().agents
    @AppStorage(RowDetails.Key.openPRs) private var openPRs = RowDetails().openPRs
    @AppStorage(RowDetails.Key.merged) private var merged = RowDetails().merged
    @ScaledMetric(relativeTo: .subheadline) private var glyphWidth: CGFloat = 14
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The Mac's state mark: the state's glyph, "○" with no known state.
    static func mark(_ s: SessionStateStyle?) -> String { s?.glyph ?? "\u{25CB}" }

    var body: some View {
        let d = RowDetails(state: state, agents: agents, openPRs: openPRs, merged: merged)
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
                    if d.agents, session.agents > 0 { agentsCapsule(session.agents) }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        if d.agents, session.agents > 0 { agentsCapsule(session.agents).layoutPriority(1) }
                    }
                }
                let layout = big ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                // No line 2 when every detail on it is off or empty.
                if (d.state && style != nil) || lines != [SessionMeta.DetailLine()] { layout {
                    if d.state, let style {
                        Text(style.label).foregroundStyle(style == .blocked ? style.tint : .secondary)
                            .lineLimit(big ? 2 : 1).layoutPriority(1)
                    }
                    ViewThatFits(in: .horizontal) {
                        ForEach(lines, id: \.self) { Self.detailLine($0) }
                    }
                }
                .font(.footnote) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.rowAccessibility(d))
        .accessibilityActions {
            ForEach(session.rowActions(ops: [], busy: true), id: \.self) { a in
                if case let .openPR(chip, url) = a { Button("Open \(chip)") { openURL(url) } }
            }
        }
    }

    /// One line-2 variant: the counts, then the amber chips and "+N"; never cut.
    static func detailLine(_ l: SessionMeta.DetailLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let n = l.merged { count("arrow.triangle.merge", n).foregroundStyle(.secondary) }
            if let n = l.open { count("arrow.triangle.pull", n).foregroundStyle(.blue) }
            ForEach(Array(l.chips.enumerated()), id: \.offset) { _, c in prChip(c) }
            if let more = l.more { prChip("+\(more)") }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private static func count(_ symbol: String, _ n: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Image(systemName: symbol).imageScale(.small)
            Text(verbatim: SessionMeta.count(n)).monospacedDigit()
        }
    }

    /// The Mac's PR chip: "Needs input" amber on a 14% wash of it.
    private static func prChip(_ s: String) -> some View {
        Text(verbatim: s)
            .font(.caption2.monospaced().weight(.medium))
            .foregroundStyle(SessionStateStyle.blocked.tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(SessionStateStyle.blocked.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
    }

    /// The Mac's sub-agent count: "🤖 N" in an outlined capsule.
    private func agentsCapsule(_ n: Int) -> some View {
        Text(verbatim: "\u{1F916} \(SessionMeta.count(n))")
            .font(.footnote.monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 4)
            .overlay(Capsule().stroke(Color.primary, lineWidth: 1))
    }
}
#endif
