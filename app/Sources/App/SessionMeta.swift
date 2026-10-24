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
        var chip: String {
            let name = repo.split(separator: "/").last.map(String.init) ?? repo
            let short = name.count > 12 ? String(name.prefix(11)) + "…" : name
            return num.map { "\(short)#\($0)" } ?? short
        }
    }

    var done: Int?, total: Int?, inProgress: Int?, queued: Int?
    var open: [PR] = []
    var merged: Int?

    static let maxChips = 3

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
    var taskLine: String? {
        var parts: [String] = []
        if let total, total > 0 { parts.append("\(Self.count(done ?? 0))/\(Self.count(total)) done") }
        if let n = inProgress, n > 0 { parts.append("\(Self.count(n)) in progress") }
        if let n = queued, n > 0 { parts.append("\(Self.count(n)) queued") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var mergedLabel: String? { merged.flatMap { $0 > 0 ? "\(Self.count($0)) merged" : nil } }

    /// The chip counts ViewThatFits tries, most first: 3, 2, 1, 0 for three or more PRs.
    static func chipCounts(_ n: Int) -> [Int] { Array((0...min(n, maxChips)).reversed()) }

    /// "open pull requests a#1, b#2, c#3 and 2 more"; nil with no open PRs.
    var prAccessibility: String? {
        guard !open.isEmpty else { return nil }
        let more = open.count - Self.maxChips
        return "open pull requests " + open.prefix(Self.maxChips).map(\.chip).joined(separator: ", ")
            + (more > 0 ? " and \(more) more" : "")
    }
}

/// The row's meta lines: PR chips, "+M" and "N merged", then the task counts.
/// Chips drop from the right when the line is too narrow; nothing animates.
/// The chips are inert, so a tap anywhere opens the session: a Link's 44 pt hit band
/// covered the name and the task line. A long press lists the PRs to open.
struct SessionMetaView: View {
    let meta: SessionMeta
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !meta.open.isEmpty || meta.mergedLabel != nil {
                ViewThatFits(in: .horizontal) {
                    ForEach(SessionMeta.chipCounts(meta.open.count), id: \.self) { prLine($0) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([meta.prAccessibility, meta.mergedLabel].compactMap { $0 }.joined(separator: ", "))
                .accessibilityActions {
                    ForEach(Array(meta.open.enumerated()), id: \.offset) { _, pr in
                        if let url = pr.url { Button("Open \(pr.chip)") { openURL(url) } }
                    }
                }
            }
            if let line = meta.taskLine {
                Text(verbatim: line).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.caption2)
        .contextMenu {
            if !meta.open.isEmpty {
                ForEach(Array(meta.open.enumerated()), id: \.offset) { _, pr in
                    // Title isolated (FSI…PDI) so its direction can't spill into the label.
                    let label = Text(verbatim: pr.title.isEmpty ? pr.chip : "\(pr.chip) — \u{2068}\(pr.title)\u{2069}")
                    if let url = pr.url { Link(destination: url) { label } } else { Button {} label: { label }.disabled(true) }
                }
                if let merged = meta.mergedLabel { Button {} label: { Text(verbatim: merged) }.disabled(true) }
            }
        }
    }

    private func prLine(_ k: Int) -> some View {
        let rest = meta.open.dropFirst(k)
        return HStack(spacing: 4) {
            ForEach(Array(meta.open.prefix(k).enumerated()), id: \.offset) { _, pr in
                chip(pr.chip).foregroundStyle(pr.url == nil ? Color.secondary : Color.accentColor)
            }
            if !rest.isEmpty { chip("+\(rest.count)") }
            if let merged = meta.mergedLabel {
                Text(verbatim: merged).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private func chip(_ s: String) -> some View {
        Text(verbatim: s)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}
