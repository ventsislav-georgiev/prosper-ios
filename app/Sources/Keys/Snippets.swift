import UIKit

/// Snippets (#609): the phone's own, in the Mac's document (`~/.config/prosper/snippets.json`,
/// its SnippetStore's `Document`), field for field, so one synced over (#614) needs no
/// conversion. One file in the App Group's container, read afresh on every call as the
/// clipboard history's index is, so the app's editor and both keyboards never hold a stale copy.
/// Inserted from the toolbar's and the terminal bar's snippets key (`SnippetPanel`); plain text
/// only: a rich (RTF) one stays in the file as it came, listed but unavailable (`unavailable`).
final class SnippetStore {
    /// The Mac's `SnippetStore.Entry`: a nil field is its default, and isn't written.
    struct Entry: Codable, Equatable {
        var name: String
        var keyword: String?
        var text: String
        var collection: String?
        var description: String?
        var autoExpand: Bool?
        var richText: Bool?
    }
    struct CollectionEntry: Codable, Equatable {
        var name: String
        var prefix: String?
        var suffix: String?
    }
    struct Document: Codable, Equatable {
        var version: Int? = 1
        var collections: [CollectionEntry]? = []
        var snippets: [Entry] = []
    }

    let url: URL

    init(url: URL) { self.url = url }

    /// The App Group's store, nil where the container isn't there.
    static func shared() -> SnippetStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardSettings.suiteName)
            .map { SnippetStore(url: $0.appendingPathComponent("Snippets/snippets.json")) }
    }

    /// Missing or unreadable, empty. An unreadable one is copied beside it as `.bad` first, so
    /// the next save never loses it silently.
    func load() -> Document {
        guard let data = try? Data(contentsOf: url) else { return Document() }
        if let doc = Self.decode(data) { return doc }
        try? data.write(to: url.appendingPathExtension("bad"), options: .atomic)
        return Document()
    }

    /// Written as the Mac writes it (`writeFile`): version 1, snippets by name, atomically.
    @discardableResult
    func save(_ doc: Document) -> Bool {
        var doc = doc
        doc.version = 1
        doc.collections = doc.collections ?? []
        doc.snippets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard let data = Self.encode(doc) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// `entry` in the place of the one named `old` (nil: added), normalised as the Mac's
    /// `entry(from:)`: name trimmed, keyword sanitised, blanks unset. Refused (false) with a
    /// blank name or text, or another snippet's name: names are unique, as on the Mac.
    @discardableResult
    func put(_ entry: Entry, replacing old: String?) -> Bool {
        var e = entry
        e.name = e.name.trimmingCharacters(in: .whitespaces)
        e.keyword = e.keyword.map(Self.sanitizeKeyword).flatMap { $0.isEmpty ? nil : $0 }
        e.collection = e.collection?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        var doc = load()
        guard !e.name.isEmpty, !e.text.isEmpty, !doc.snippets.contains(where: { $0.name == e.name && $0.name != old })
        else { return false }
        if let i = doc.snippets.firstIndex(where: { $0.name == old }) { doc.snippets[i] = e } else { doc.snippets.append(e) }
        return save(doc)
    }

    func delete(_ name: String) {
        var doc = load()
        guard doc.snippets.contains(where: { $0.name == name }) else { return }
        doc.snippets.removeAll { $0.name == name }
        save(doc)
    }

    /// `entry`'s text resolved as the Mac's (`PlaceholderEngine`): `{clipboard}` read from
    /// `pasteboard` only if the text has one, `{clipboard N}` the history's Nth text, newest
    /// first, `{snippet …}` from this store. `back`: the Characters from the end to `{cursor}`.
    func resolve(_ entry: Entry, pasteboard: UIPasteboard?, history: ClipboardHistory?) -> (text: String, back: Int) {
        var ctx = PlaceholderContext()
        ctx.clipboard = { pasteboard?.string }
        ctx.clipboardHistory = { n in
            let texts = history?.clips.compactMap(\.text) ?? []
            return n < texts.count ? texts[n] : nil
        }
        let all = load().snippets + (fromMac()?.snippets ?? [])
        ctx.snippetByKeyword = { key in all.first { $0.keyword == key || $0.name == key }?.text }
        let (text, cursor) = PlaceholderEngine.render(entry.text, ctx)
        return (text, cursor.map { text.count - $0 } ?? 0)
    }

    /// The last-synced Mac's (#614), read-only beside these, under its title; nil with none.
    func fromMac() -> (title: String, snippets: [Entry])? {
        let root = MacLibrary.root(of: url)
        guard let lib = MacLibrary.load(root), let data = try? Data(contentsOf: MacLibrary.snippetsURL(root)),
              let doc = Self.decode(data) else { return nil }
        return (lib.title, doc.snippets)
    }

    /// The Mac's grouped as the phone's, each under "From <Mac>", "From <Mac> · <collection>".
    static func grouped(fromMac mac: (title: String, snippets: [Entry])?) -> [Group] {
        guard let mac else { return [] }
        return grouped(mac.snippets).map { Group(title: $0.title.isEmpty ? mac.title : "\(mac.title) · \($0.title)", snippets: $0.snippets) }
    }

    /// One collection's snippets, by name; "" is none.
    struct Group: Identifiable {
        let title: String
        let snippets: [Entry]
        var id: String { title }
    }

    /// The ones in no collection first, then each collection's, all by name as the Mac sorts them.
    static func grouped(_ snippets: [Entry]) -> [Group] {
        let sorted = snippets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Dictionary(grouping: sorted) { $0.collection ?? "" }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { Group(title: $0.key, snippets: $0.value) }
    }

    /// The Mac's `sanitizeKeyword`: no blanks or quotes.
    static func sanitizeKeyword(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\"" && $0 != "'" })
    }

    /// The Mac's `encodeDocument`.
    static func encode(_ doc: Document) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(doc)
    }

    /// A missing version is 1, as on the Mac (#614).
    static func decode(_ data: Data) -> Document? {
        guard var doc = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
        doc.version = doc.version ?? 1
        return doc
    }
}

extension SnippetStore.Entry {
    /// Why the phone can't insert it, nil if it can: rich text needs the Mac's RTF paste, and an
    /// `{argument}` with no default a prompt, which v1 doesn't have (the Mac's inline expansion
    /// declines it too). Extension placeholders aren't told from unknown text: both go literally.
    var unavailable: String? {
        if richText == true { return "Rich text: insert it on the Mac" }
        if PlaceholderEngine.arguments(in: text).contains(where: \.required) { return "Asks for an argument: insert it on the Mac" }
        return nil
    }

    /// The text on one line, for a row's preview.
    var preview: String { text.split(whereSeparator: \.isNewline).joined(separator: " ") }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The snippets in the keys' place (#609), as the clipboard history's panel: the snippets key
/// opens it, a pick or the keyboard button closes it. Rows by collection, a name over a one-line
/// preview; one the phone can't insert is dimmed, with why, and takes no tap. The Mac's (#614)
/// follow the phone's, picked as they are.
final class SnippetPanel: KeysPanel, UITableViewDataSource, UITableViewDelegate {
    var onPick: ((SnippetStore.Entry) -> Void)?
    let groups: [SnippetStore.Group]

    init(store: SnippetStore) {
        groups = SnippetStore.grouped(store.load().snippets) + SnippetStore.grouped(fromMac: store.fromMac())
        super.init(title: "Snippets", empty: "Add snippets in Prosper's Settings.")
        table.dataSource = self
        table.delegate = self
        empty.isHidden = !groups.isEmpty
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func numberOfSections(in tableView: UITableView) -> Int { groups.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].snippets.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        groups[section].title.isEmpty ? nil : groups[section].title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let snippet = groups[indexPath.section].snippets[indexPath.row]
        let off = snippet.unavailable
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        cell.selectionStyle = off == nil ? .default : .none
        var content = cell.defaultContentConfiguration()
        content.text = snippet.name
        content.textProperties.color = off == nil ? .white : TerminalKeyboard.Style.hint
        content.textProperties.font = .systemFont(ofSize: 15, weight: .medium)
        content.secondaryText = off ?? snippet.preview
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.color = TerminalKeyboard.Style.hint
        cell.contentConfiguration = content
        // One VoiceOver label: the name, else the preview (#631).
        cell.accessibilityLabel = snippet.name.isEmpty ? snippet.preview : snippet.name
        cell.accessibilityTraits.insert(.button)
        cell.accessibilityHint = off ?? "Types it"
        if off != nil { cell.accessibilityTraits.insert(.notEnabled) }
        return cell
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        groups[indexPath.section].snippets[indexPath.row].unavailable == nil ? indexPath : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let snippet = groups[indexPath.section].snippets[indexPath.row]
        if snippet.unavailable == nil { onPick?(snippet) }
    }
}
