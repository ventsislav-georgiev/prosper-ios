import SwiftUI

/// A session's PRs and tasks as the Mac's list reports them (its `meta` key), drawn
/// under the row the way the Mac's Agent Island draws them.
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

        /// "prosper#12 — title" for the long-press menu, the title isolated (FSI…PDI) so
        /// its direction can't spill into the label. A blank title leaves just the chip.
        var menuLabel: String {
            title.trimmingCharacters(in: .whitespaces).isEmpty ? chip : "\(chip) — \u{2068}\(title)\u{2069}"
        }
    }

    var done: Int?, total: Int?, inProgress: Int?, queued: Int?
    var open: [PR] = []
    var merged: Int?

    static let maxChips = 3
    static let maxRepo = 18, phoneRepo = 12    // the Mac's cut, then the old iOS one

    /// nil when `json` is not an object or leaves nothing to draw. A field of the wrong
    /// type or a negative count is dropped on its own; it never costs the row.
    init?(json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        if let t = o["tasks"] as? [String: Any] {
            (done, total) = (Self.count(t["done"]), Self.count(t["total"]))
            (inProgress, queued) = (Self.count(t["in_progress"]), Self.count(t["queued"]))
        }
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
        if open.isEmpty && mergedLabel == nil && taskLine == nil { return nil }
    }

    init(done: Int? = nil, total: Int? = nil, inProgress: Int? = nil, queued: Int? = nil,
         open: [PR] = [], merged: Int? = nil) {
        (self.done, self.total, self.inProgress, self.queued) = (done, total, inProgress, queued)
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

    /// "22/26 done · 2 in progress · 2 queued", zero and unknown parts left out.
    var taskLine: String? { summary(.all) }

    /// The task line with only the parts `d` turns on; nil leaves no summary. `spoken`
    /// words it for VoiceOver: "41 of 68 tasks done, 8 in progress".
    func summary(_ d: RowDetails, spoken: Bool = false) -> String? {
        var parts: [String] = []
        if d.tasksDone, let total, total > 0 {
            let (n, of) = (Self.count(done ?? 0), Self.count(total))
            parts.append(spoken ? "\(n) of \(of) tasks done" : "\(n)/\(of) done")
        }
        if d.inProgress, let n = inProgress, n > 0 { parts.append("\(Self.count(n)) in progress") }
        if d.queued, let n = queued, n > 0 { parts.append("\(Self.count(n)) queued") }
        return parts.isEmpty ? nil : parts.joined(separator: spoken ? ", " : " · ")
    }

    var mergedLabel: String? { merged.flatMap { $0 > 0 ? "\(Self.count($0)) merged" : nil } }

    /// The chip for the PRs left over: "+2 pending PRs", "+1 pending PR".
    static func moreLabel(_ n: Int) -> String { "+\(n) pending PR\(n == 1 ? "" : "s")" }

    /// One way to draw the PR line: chips, the pending chip, the merged count.
    struct PRLine: Hashable {
        var chips: [String], more: String?, merged: String?
    }

    /// The PR lines ViewThatFits tries, the first that fits wins: 3, 2, 1 chips, each
    /// with full labels then repos cut to 18, beside "+N pending PRs", then beside a
    /// bare "+N", then repos cut to 12 (a chip shown beats the long wording); last no
    /// chips, "+N pending PRs" then a bare "+N". Empty draws no PR line.
    func prLines(_ d: RowDetails) -> [PRLine] {
        let merged = d.merged ? mergedLabel : nil
        guard d.openPRs, !open.isEmpty else { return merged.map { [PRLine(chips: [], more: nil, merged: $0)] } ?? [] }
        var lines: [PRLine] = []
        for k in stride(from: min(open.count, Self.maxChips), through: 0, by: -1) {
            let n = open.count - k
            let long: String? = n == 0 ? nil : Self.moreLabel(n), short: String? = n == 0 ? nil : "+\(n)"
            let tries: [(maxRepo: Int?, more: String?)] = k == 0 ? [(maxRepo: nil, more: long), (maxRepo: nil, more: short)]
                : n == 0 ? [(maxRepo: nil, more: nil), (maxRepo: Self.maxRepo, more: nil), (maxRepo: Self.phoneRepo, more: nil)]
                : [(maxRepo: nil, more: long), (maxRepo: Self.maxRepo, more: long), (maxRepo: nil, more: short),
                   (maxRepo: Self.maxRepo, more: short), (maxRepo: Self.phoneRepo, more: short)]
            for t in tries {
                let line = PRLine(chips: open.prefix(k).map { $0.chip(maxRepo: t.maxRepo) }, more: t.more, merged: merged)
                if !lines.contains(line) { lines.append(line) }
            }
        }
        return lines
    }

    /// The PR line's long-press menu: only with open PRs to list, not for a lone merged count.
    func hasMenu(_ d: RowDetails) -> Bool { d.openPRs && !open.isEmpty }

    /// "open pull requests a#1, b#2, c#3 and 2 more"; nil with no open PRs.
    var prAccessibility: String? {
        guard !open.isEmpty else { return nil }
        let more = open.count - Self.maxChips
        return "open pull requests " + open.prefix(Self.maxChips).map(\.chip).joined(separator: ", ")
            + (more > 0 ? " and \(more) more" : "")
    }
}

/// Which details a session row draws besides its title, state and name, set in
/// Settings › Session list and kept per device. Labels and defaults match the Mac's
/// Agent Island.
struct RowDetails: Equatable {
    enum Key {
        static let agents = "sessionRow.agents"
        static let openPRs = "sessionRow.openPRs"
        static let merged = "sessionRow.merged"
        static let tasksDone = "sessionRow.tasksDone"
        static let inProgress = "sessionRow.inProgress"
        static let queued = "sessionRow.queued"
    }

    var agents = true, openPRs = true, merged = true
    var tasksDone = false, inProgress = false, queued = false

    static let all = RowDetails(agents: true, openPRs: true, merged: true, tasksDone: true, inProgress: true, queued: true)
}

extension DchSession {
    /// What VoiceOver reads for the row: the title and state, then only the details shown.
    func rowAccessibility(_ d: RowDetails) -> String {
        let n = agents
        let agents: String? = d.agents && n > 0 ? (n == 1 ? "1 agent" : "\(n) agents") : nil
        let prs: String? = d.openPRs ? meta?.prAccessibility : nil
        let merged: String? = d.merged ? meta?.mergedLabel : nil
        return [title, SessionStateStyle(state)?.label, agents, title != name ? name : nil,
                meta?.summary(d, spoken: true), prs, merged].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A session row as the Mac's Agent Island draws it: a state glyph, then line 1 the
/// title and "+N agents", line 2 the state, the name under an alias and the task
/// summary, line 3 the PR chips and "N merged". Nothing animates.
/// The chips are inert, so a tap anywhere opens the session: a Link's 44 pt hit band
/// covered the name and the task line. A long press on the PR line lists the PRs.
struct SessionRow: View {
    let session: DchSession
    @AppStorage(RowDetails.Key.agents) private var agents = RowDetails().agents
    @AppStorage(RowDetails.Key.openPRs) private var openPRs = RowDetails().openPRs
    @AppStorage(RowDetails.Key.merged) private var merged = RowDetails().merged
    @AppStorage(RowDetails.Key.tasksDone) private var tasksDone = RowDetails().tasksDone
    @AppStorage(RowDetails.Key.inProgress) private var inProgress = RowDetails().inProgress
    @AppStorage(RowDetails.Key.queued) private var queued = RowDetails().queued
    @ScaledMetric(relativeTo: .subheadline) private var glyphWidth: CGFloat = 14
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let d = RowDetails(agents: agents, openPRs: openPRs, merged: merged,
                           tasksDone: tasksDone, inProgress: inProgress, queued: queued)
        let style = SessionStateStyle(session.state)
        let alias: String? = session.title != session.name ? session.name : nil
        let summary: String? = session.meta?.summary(d)
        let lines: [SessionMeta.PRLine] = session.meta?.prLines(d) ?? []
        let agentsChip: String? = d.agents ? SessionStateStyle.agents(session.agents) : nil
        let big = typeSize.isAccessibilitySize
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Unknown state from a newer server: an empty column, rather than a guess.
            Text(verbatim: style?.glyph ?? " ")
                .font(.subheadline.bold())
                .foregroundStyle(style?.tint ?? Color.clear)
                .frame(width: glyphWidth)
            VStack(alignment: .leading, spacing: 2) {
                if big {
                    // Accessibility sizes: nothing shares a line with the title or the
                    // state word, and both may wrap, so the name and state always show.
                    Text(session.title).fontWeight(.medium).lineLimit(2)
                    if let agentsChip { chip(agentsChip) }
                    VStack(alignment: .leading, spacing: 2) {
                        stateAndName(style, alias)
                        if let summary { summaryText(summary) }
                    }
                    .font(.footnote)
                    .lineLimit(2)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.title).fontWeight(.medium).lineLimit(1)
                        if let agentsChip { chip(agentsChip).layoutPriority(1) }
                    }
                }
                if !big, style != nil || alias != nil || summary != nil {
                    // A phone row rarely fits every part: the summary moves under the state
                    // rather than truncate its numbers.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            stateAndName(style, alias)
                            if let summary { Spacer(minLength: 6); summaryText(summary) }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) { stateAndName(style, alias) }
                            if let summary { summaryText(summary) }
                        }
                    }
                    .font(.footnote)
                    .lineLimit(1)
                }
                if !lines.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        ForEach(lines, id: \.self) { prLine($0) }
                    }
                    .contextMenu { if let meta = session.meta, meta.hasMenu(d) { menu(meta, d) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.rowAccessibility(d))
        .accessibilityActions {
            if d.openPRs {
                ForEach(Array((session.meta?.open ?? []).enumerated()), id: \.offset) { _, pr in
                    if let url = pr.url { Button("Open \(pr.chip)") { openURL(url) } }
                }
            }
        }
    }

    @ViewBuilder private func stateAndName(_ style: SessionStateStyle?, _ alias: String?) -> some View {
        if let style { Text(style.label).foregroundStyle(style.tint).layoutPriority(1) }   // the name truncates first
        if let alias { Text(verbatim: alias).font(.caption2.monospaced()).foregroundStyle(.secondary) }
    }

    private func summaryText(_ s: String) -> some View {
        Text(verbatim: s).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    /// Lists the PRs to open; with Open PRs off the line has no chips and no menu.
    @ViewBuilder private func menu(_ meta: SessionMeta, _ d: RowDetails) -> some View {
        ForEach(Array(meta.open.enumerated()), id: \.offset) { _, pr in
            let label = Text(verbatim: pr.menuLabel)
            if let url = pr.url { Link(destination: url) { label } } else { Button {} label: { label }.disabled(true) }
        }
        if d.merged, let merged = meta.mergedLabel { Button {} label: { Text(verbatim: merged) }.disabled(true) }
    }

    /// At accessibility sizes "N merged" goes under the chips instead of beside them.
    private func prLine(_ line: SessionMeta.PRLine) -> some View {
        let big = typeSize.isAccessibilitySize
        let layout = big ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 0))
        return layout {
            if !line.chips.isEmpty || line.more != nil {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    ForEach(Array(line.chips.enumerated()), id: \.offset) { _, c in chip(c) }
                    if let more = line.more { chip(more) }
                }
            }
            if let merged = line.merged {
                if !big { Spacer(minLength: 8) }
                Text(verbatim: merged).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    /// The agents capsule; the PR chips share it.
    private func chip(_ s: String) -> some View {
        Text(verbatim: s)
            .font(.caption2.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.1), in: Capsule())
    }
}
