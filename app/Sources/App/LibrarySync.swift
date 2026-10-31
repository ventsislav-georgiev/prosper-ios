import Foundation

/// Settings › Sync from Mac (#614): the app's side of `MacLibrary`. A Mac whose `ops` list
/// `library` is synced when its session list loads, at most once a minute, and from Settings'
/// Sync Now; the stored etag goes along, so an unchanged library costs one small reply.
extension MacLibrary {
    /// On by default; the app's own defaults, the keyboards only read the files.
    static let syncKey = "syncFromMac"
    static let interval: TimeInterval = 60
    /// The last sync asked, for the throttle; per launch.
    @MainActor static var lastAttempt: Date?

    static func syncOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: syncKey) as? Bool ?? true }

    /// The toggle. Off deletes the Mac's copies and the etag at once.
    static func setSync(_ on: Bool, root: URL? = sharedRoot(), defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: syncKey)
        if !on, let root { clear(root) }
    }

    /// `machine`'s library over `transport`, into `root`. `force` (Sync Now) skips the throttle.
    /// Nothing with the toggle off; the Mac's error 0x13 or a dead link throws.
    @MainActor
    static func sync(_ machine: Machine, over transport: SessionTransport, root: URL? = sharedRoot(),
                     defaults: UserDefaults = .standard, force: Bool = false, now: Date = Date()) async throws {
        guard let root, syncOn(defaults) else { return }
        if !force, let last = lastAttempt, now.timeIntervalSince(last) < interval { return }
        lastAttempt = now
        let old = load(root)
        let reply = try await transport.library(etag: old?.machine == machine.id ? old?.etag : nil)
        guard syncOn(defaults) else { return }   // turned off while it was in flight
        apply(reply, from: machine, root: root, now: now)
    }

    /// `unchanged` only re-dates. Otherwise each file: one with an error keeps its copy, a null
    /// one clears it, one that isn't the document the phone reads keeps its copy too. Another
    /// Mac's copies go first: there is one Mac's at a time.
    static func apply(_ reply: LibraryReply, from machine: Machine, root: URL, now: Date = Date()) {
        if load(root)?.machine != machine.id { clear(root) }
        if !reply.unchanged {
            put(reply.snippets, error: reply.errors["snippets"], at: snippetsURL(root)) { SnippetStore.decode($0) != nil }
            put(reply.quicklinks, error: reply.errors["quicklinks"], at: quicklinksURL(root)) { QuicklinkStore.decode($0) != nil }
        }
        MacLibrary(machine: machine.id, name: machine.name, etag: reply.etag, date: now).save(root)
    }

    private static func put(_ data: Data?, error: String?, at url: URL, valid: (Data) -> Bool) {
        guard error == nil else { return }
        guard let data else { try? FileManager.default.removeItem(at: url); return }
        guard valid(data) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
