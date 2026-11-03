import Foundation
import CryptoKit
import UIKit
import os

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

/// #730: the other way: the phone's own snippets (`SnippetStore`) to a Mac whose `ops` list
/// `snippets_put`, which shows them read-only. Each side owns its own; nothing is overwritten.
/// An idempotent replace, sent when a session list's handshake offers it and after an edit in
/// Settings, only when the hash differs from the last one that Mac took. Rich ones stay home
/// (they don't insert here either). The keyboards edit nothing, so no change is missed; one
/// made with no Mac connected goes on the next connect. "Sync from Mac" is its switch too:
/// off sends a connected Mac one empty list and forgets the hashes, so on sends again.
/// A failure or a refusal is only logged; the hash stays, so the next trigger tries again.
@MainActor
enum SnippetPush {
    /// The Mac's caps: past them it refuses, so nothing is sent.
    static let bodyMax = 3_000_000, countMax = 5000, nameMax = 256
    /// The last hash each Mac (`Machine.id`) took, in the app's own defaults.
    static let hashesKey = "snippetsPut.hashes"

    struct Snippet: Encodable, Equatable {
        var name: String
        var text: String
        var keyword: String?
        var group: String?
    }

    private struct Request: Encodable {
        var deviceId: String
        var deviceName: String?
        var hash: String
        var snippets: [Snippet]
        enum CodingKeys: String, CodingKey { case deviceId = "device_id", deviceName = "device_name", hash, snippets }
    }

    private static let log = Logger(subsystem: "eu.illegible.prosper", category: "snippets")

    /// What goes: plain text only, by name, a collection as its group.
    static func snippets(_ entries: [SnippetStore.Entry]) -> [Snippet] {
        entries.filter { $0.richText != true }
            .map { Snippet(name: $0.name, text: $0.text, keyword: $0.keyword, group: $0.collection) }
            .sorted { $0.name < $1.name }
    }

    private static func encode<T: Encodable>(_ v: T) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? e.encode(v)
    }

    /// SHA-256 hex of the encoded array: the same snippets always give the same hash.
    static func hash(_ snippets: [Snippet]) -> String {
        SHA256.hash(data: encode(snippets) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    /// The 0x2c body and its hash, or nil past the Mac's caps.
    static func request(_ snippets: [Snippet], deviceId: String, deviceName: String?) -> (body: Data, hash: String)? {
        let hash = hash(snippets)
        guard snippets.count <= countMax, snippets.allSatisfy({ $0.name.count <= nameMax }),
              let body = encode(Request(deviceId: deviceId, deviceName: deviceName, hash: hash, snippets: snippets)),
              body.count <= bodyMax else { return nil }
        return (body, hash)
    }

    static func hashes(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: hashesKey) as? [String: String] ?? [:]
    }

    static func currentDevice() -> (id: String, name: String?)? {
        UIDevice.current.identifierForVendor.map { ($0.uuidString, UIDevice.current.name) }
    }

    /// `entries` to `machine` over `t` as `device` (this phone's when nil), unless that Mac has
    /// them already; `clear` sends them whatever the toggle and the hash say, and remembers nothing.
    static func push(_ entries: [SnippetStore.Entry], over t: SessionTransport, machine: String,
                     defaults: UserDefaults = .standard, device: (id: String, name: String?)? = nil,
                     clear: Bool = false) async throws {
        guard clear || MacLibrary.syncOn(defaults) else { return }
        guard let device = device ?? currentDevice() else { log.error("snippets put: no device id yet"); return }
        let snippets = snippets(entries)
        guard let (body, hash) = request(snippets, deviceId: device.id, deviceName: device.name) else {
            log.error("snippets put: \(snippets.count, privacy: .public) snippets are past the Mac's caps, not sent")
            return
        }
        guard clear || hashes(defaults)[machine] != hash else { return }
        let reply = try await t.putPhoneSnippets(body)
        guard !clear, MacLibrary.syncOn(defaults) else { return }   // turned off while it was in flight
        guard reply.hash == hash else { log.error("snippets put: the Mac echoed another hash"); return }
        var all = hashes(defaults)
        all[machine] = hash
        defaults.set(all, forKey: hashesKey)
    }

    // MARK: Triggers

    /// The Mac to send to: the session list's last handshake, while it listed snippets_put.
    private(set) static var mac: (transport: SessionTransport, machine: String)?
    private(set) static var running = false
    private static var again = false, clearing = false
    /// Settable for tests.
    static var store: () -> SnippetStore? = { SnippetStore.shared() }
    static var defaults = UserDefaults.standard

    static func offer(_ ops: Set<SessionVerb>, over t: SessionTransport, machine: String) {
        mac = ops.contains(.snippetsPut) ? (t, machine) : nil
        kick()
    }

    /// After "Sync from Mac" changed (`MacLibrary.setSync`).
    static func setSync(_ on: Bool) {
        if !on {
            defaults.removeObject(forKey: hashesKey)
            clearing = mac != nil
        }
        kick()
    }

    /// A push, unless one runs: then one more after it.
    static func kick() {
        guard mac != nil, clearing || MacLibrary.syncOn(defaults) else { return }
        guard !running else { again = true; return }
        running = true
        Task {
            repeat {
                again = false
                guard let mac else { break }
                let clear = clearing
                clearing = false
                guard let entries = clear ? [] : store()?.load().snippets else { continue }
                do { try await push(entries, over: mac.transport, machine: mac.machine, defaults: defaults, clear: clear) } catch {
                    log.error("snippets put: \(error.localizedDescription, privacy: .public)")
                }
            } while again
            running = false
        }
    }
}
