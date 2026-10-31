import Foundation

/// The last-synced Mac's snippets and quicklinks (#614): its two documents as received, in their
/// own files beside the phone's own (`Snippets/mac.json`, `Quicklinks/mac.json`), never mixed
/// into them, and this record of which Mac and which etag (`library.json`). The panels and
/// Settings read them afresh, so a sync reaches the keyboards without IPC. The app syncs them
/// (`sync`); here is only what the keyboards read too.
/// ponytail: one Mac at a time, the one synced last; per-Mac files if anyone syncs two.
struct MacLibrary: Codable, Equatable {
    var machine: UUID
    var name: String
    var etag: String
    var date: Date

    /// The App Group's container, nil where it isn't there.
    static func sharedRoot() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardSettings.suiteName)
    }

    static func url(_ root: URL) -> URL { root.appendingPathComponent("library.json") }
    static func snippetsURL(_ root: URL) -> URL { root.appendingPathComponent("Snippets/mac.json") }
    static func quicklinksURL(_ root: URL) -> URL { root.appendingPathComponent("Quicklinks/mac.json") }

    static func load(_ root: URL) -> MacLibrary? {
        try? JSONDecoder().decode(MacLibrary.self, from: Data(contentsOf: url(root)))
    }

    func save(_ root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url(root), options: .atomic)
    }

    /// The copies and the etag gone.
    static func clear(_ root: URL) {
        for u in [url(root), snippetsURL(root), quicklinksURL(root)] { try? FileManager.default.removeItem(at: u) }
    }

    /// A store's container: its file sits one folder down (`Snippets/snippets.json`).
    static func root(of store: URL) -> URL { store.deletingLastPathComponent().deletingLastPathComponent() }

    /// The section title the Mac's entries go under.
    var title: String { "From \(name)" }
}
