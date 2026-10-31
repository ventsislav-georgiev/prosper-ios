import UIKit

/// Quicklinks (#613): the phone's own, in the Mac's document (`~/.config/prosper/quicklinks.json`,
/// its QuicklinkStore's `Document`), field for field, so one synced over (#614) needs no
/// conversion. As the snippets' (`SnippetStore`): one file in the App Group's container, read
/// afresh on every call. A link's `{query}` is filled as the Mac's quicklinks extension fills it
/// (`fill`); typed from the toolbar's and the terminal bar's quicklinks key (`QuicklinkPanel`).
final class QuicklinkStore {
    /// The Mac's `QuicklinkStore.Entry`: a nil description isn't written.
    struct Entry: Codable, Equatable {
        var name: String
        var url: String
        var description: String?
    }
    struct Document: Codable, Equatable {
        var version = 1
        var quicklinks: [Entry] = []
    }

    let url: URL
    /// The names picked last, newest first, beside the file: the panel's first rows.
    var recentsURL: URL { url.deletingLastPathComponent().appendingPathComponent("recents.json") }
    static let recentsKept = 5

    init(url: URL) { self.url = url }

    /// The App Group's store, nil where the container isn't there.
    static func shared() -> QuicklinkStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardSettings.suiteName)
            .map { QuicklinkStore(url: $0.appendingPathComponent("Quicklinks/quicklinks.json")) }
    }

    /// Missing or unreadable, empty. An unreadable one is copied beside it as `.bad` first, so
    /// the next save never loses it silently.
    func load() -> Document {
        guard let data = try? Data(contentsOf: url) else { return Document() }
        if let doc = Self.decode(data) { return doc }
        try? data.write(to: url.appendingPathExtension("bad"), options: .atomic)
        return Document()
    }

    /// Written as the Mac writes it (`writeFile`): version 1, links by name as `sorted()` orders
    /// them, atomically.
    @discardableResult
    func save(_ doc: Document) -> Bool {
        var doc = doc
        doc.version = 1
        doc.quicklinks.sort { $0.name < $1.name }
        guard let data = Self.encode(doc) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// `entry` in the place of the one named `old` (nil: added), trimmed as the Mac's `save`.
    /// Refused (false) with a blank name or URL, or another link's name: names are unique, as on
    /// the Mac.
    @discardableResult
    func put(_ entry: Entry, replacing old: String?) -> Bool {
        var e = entry
        e.name = e.name.trimmingCharacters(in: .whitespaces)
        e.url = e.url.trimmingCharacters(in: .whitespaces)
        e.description = e.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.description?.isEmpty == true { e.description = nil }
        var doc = load()
        guard !e.name.isEmpty, !e.url.isEmpty, !doc.quicklinks.contains(where: { $0.name == e.name && $0.name != old })
        else { return false }
        if let i = doc.quicklinks.firstIndex(where: { $0.name == old }) { doc.quicklinks[i] = e } else { doc.quicklinks.append(e) }
        return save(doc)
    }

    func delete(_ name: String) {
        var doc = load()
        guard doc.quicklinks.contains(where: { $0.name == name }) else { return }
        doc.quicklinks.removeAll { $0.name == name }
        save(doc)
    }

    var recents: [String] { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: recentsURL))) ?? [] }

    /// `name` picked: first of the recents, which keep `recentsKept`.
    func used(_ name: String) {
        let list = Array(([name] + recents.filter { $0 != name }).prefix(Self.recentsKept))
        try? JSONEncoder().encode(list).write(to: recentsURL, options: .atomic)
    }

    /// The panel's order: the recently used, newest first, then the rest A–Z. With 120 links
    /// and no search field (v1), the ones in use stay one tap away.
    func ordered() -> (recent: [Entry], rest: [Entry]) {
        let links = load().quicklinks, used = recents
        let recent = used.compactMap { name in links.first { $0.name == name } }
        let rest = links.filter { !used.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (recent, rest)
    }

    // MARK: - {query}, as the Mac's extension (`quicklinks/init.lua`, `substitute`)

    /// Lua's `{%s*[Qq]uery%s*}` and `{%s*[Aa]rgument%s*}`, in its order: only the first letter
    /// takes either case, and `%s` is C's six blanks.
    private static let tokens = ["[Qq]uery", "[Aa]rgument"].map { word in
        let blank = "[ \\t\\n\\x0B\\f\\r]*"
        return try! NSRegularExpression(pattern: "\\{\(blank)\(word)\(blank)\\}")
    }
    /// Lua's `urlencode` keeps `%w-._~/` (ASCII) and encodes every other byte, uppercase.
    private static let kept = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")

    static func takesQuery(_ template: String) -> Bool {
        tokens.contains { $0.firstMatch(in: template, range: NSRange(template.startIndex..., in: template)) != nil }
    }

    /// `template` with each `{query}` and `{argument}` as `argument`, percent-encoded only in a
    /// URL (`://`), `/` kept: `github.com/{query}` takes "owner/repo".
    static func fill(_ template: String, with argument: String) -> String {
        let value = template.contains("://") ? argument.addingPercentEncoding(withAllowedCharacters: kept) ?? argument : argument
        return tokens.reduce(template) { out, re in
            re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                        withTemplate: NSRegularExpression.escapedTemplate(for: value))
        }
    }

    /// The Mac's `writeFile` encoder.
    static func encode(_ doc: Document) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(doc)
    }

    static func decode(_ data: Data) -> Document? { try? JSONDecoder().decode(Document.self, from: data) }
}

/// The quicklinks in the keys' place (#613), as the snippets' panel: the quicklinks key opens it,
/// a pick or the keyboard button closes it. Recently used first, then A–Z, a name over its URL.
/// One whose `{query}` has nothing to take (no selection, no word before the caret; always in
/// the terminal) is dimmed, with why, and takes no tap.
/// ponytail: no search field in v1, typing into the panel from the keyboard itself is its own
/// project; the recents are the answer to a long list for now.
final class QuicklinkPanel: KeysPanel, UITableViewDataSource, UITableViewDelegate {
    var onPick: ((QuicklinkStore.Entry) -> Void)?
    let sections: [(title: String?, links: [QuicklinkStore.Entry])]
    /// A `{query}` has its argument where the panel opened.
    let hasQuery: Bool

    init(store: QuicklinkStore, hasQuery: Bool) {
        let (recent, rest) = store.ordered()
        sections = (recent.isEmpty ? [(nil, rest)] : [("Recent", recent), ("All", rest)]).filter { !$0.1.isEmpty }
        self.hasQuery = hasQuery
        super.init(title: "Quicklinks", empty: "Add quicklinks in Prosper's Settings.")
        table.dataSource = self
        table.delegate = self
        empty.isHidden = !sections.isEmpty
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Why `link` can't go, nil if it can.
    func unavailable(_ link: QuicklinkStore.Entry) -> String? {
        !hasQuery && QuicklinkStore.takesQuery(link.url) ? "Select text for {query}" : nil
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].links.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let link = sections[indexPath.section].links[indexPath.row]
        let off = unavailable(link)
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        cell.selectionStyle = off == nil ? .default : .none
        var content = cell.defaultContentConfiguration()
        content.text = link.name
        content.textProperties.color = off == nil ? .white : TerminalKeyboard.Style.hint
        content.textProperties.font = .systemFont(ofSize: 15, weight: .medium)
        content.secondaryText = off ?? link.url
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.color = TerminalKeyboard.Style.hint
        cell.contentConfiguration = content
        cell.accessibilityHint = off ?? "Types the link"
        if off != nil { cell.accessibilityTraits.insert(.notEnabled) }
        return cell
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        unavailable(sections[indexPath.section].links[indexPath.row]) == nil ? indexPath : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let link = sections[indexPath.section].links[indexPath.row]
        if unavailable(link) == nil { onPick?(link) }
    }
}
