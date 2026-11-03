import XCTest
import CryptoKit
import Network
@testable import Prosper

/// #614: the Mac's snippets and quicklinks synced into their own files beside the phone's: the
/// etag sent back, unchanged, a new etag, a file's error, a null file, the toggle, the throttle,
/// and the copies read-only to the phone's stores. A throwaway container and defaults throughout.
@MainActor
final class LibrarySyncTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private let studio = Machine(name: "Studio", addresses: ["127.0.0.1"])
    private let t0 = Date(timeIntervalSince1970: 1_793_459_045)

    /// No "version": read as 1.
    nonisolated static let snippets = #"{"collections":[],"snippets":[{"name":"Sign","keyword":"sig","text":"— me"}]}"#
    nonisolated static let quicklinks = #"{"version":1,"quicklinks":[{"name":"notes","url":"~/notes/{query}.md"},{"name":"Tracker","url":"tracker://open"}]}"#

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySyncTests-\(UUID())")
        suite = "LibrarySyncTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        MacLibrary.lastAttempt = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
        MacLibrary.lastAttempt = nil
        super.tearDown()
    }

    private func full(_ etag: String, snippets: String? = LibrarySyncTests.snippets,
                      quicklinks: String? = LibrarySyncTests.quicklinks, errors: [String: String] = [:]) -> LibraryReply {
        LibraryReply(etag: etag, snippets: snippets.map { Data($0.utf8) }, quicklinks: quicklinks.map { Data($0.utf8) }, errors: errors)
    }

    private var snippetsCopy: Data? { try? Data(contentsOf: MacLibrary.snippetsURL(root)) }
    private var quicklinksCopy: Data? { try? Data(contentsOf: MacLibrary.quicklinksURL(root)) }

    private func sync(_ fake: LibraryFake, at date: Date, force: Bool = false) async throws {
        try await MacLibrary.sync(studio, over: fake, root: root, defaults: defaults, force: force, now: date)
    }

    func testFirstSyncStoresBothAsReceivedAndTheEtag() async throws {
        let fake = LibraryFake([full("e1")])
        try await sync(fake, at: t0)
        XCTAssertEqual(fake.etags, [nil], "nothing stored: no etag")
        XCTAssertEqual(snippetsCopy, Data(Self.snippets.utf8))
        XCTAssertEqual(quicklinksCopy, Data(Self.quicklinks.utf8))
        XCTAssertEqual(MacLibrary.load(root), MacLibrary(machine: studio.id, name: "Studio", etag: "e1", date: t0))
    }

    func testUnchangedKeepsTheFilesAndOnlyRedates() async throws {
        let fake = LibraryFake([full("e1"), LibraryReply(etag: "e1", unchanged: true)])
        try await sync(fake, at: t0)
        try await sync(fake, at: t0 + 120)
        XCTAssertEqual(fake.etags, [nil, "e1"], "the stored etag goes back")
        XCTAssertEqual(snippetsCopy, Data(Self.snippets.utf8))
        XCTAssertEqual(quicklinksCopy, Data(Self.quicklinks.utf8))
        XCTAssertEqual(MacLibrary.load(root)?.date, t0 + 120)
        XCTAssertEqual(MacLibrary.load(root)?.etag, "e1")
    }

    func testNewEtagReplacesThem() async throws {
        let other = #"{"version":1,"snippets":[{"name":"Bye","text":"bye"}]}"#
        let fake = LibraryFake([full("e1"), full("e2", snippets: other)])
        try await sync(fake, at: t0)
        try await sync(fake, at: t0 + 120)
        XCTAssertEqual(snippetsCopy, Data(other.utf8))
        XCTAssertEqual(MacLibrary.load(root)?.etag, "e2")
    }

    /// An error keeps the previous copy; a null file (none on the Mac) clears it; a file that
    /// isn't the document the phone reads keeps its copy too.
    func testErrorKeepsTheCopyAndNullClearsIt() async throws {
        let fake = LibraryFake([
            full("e1"),
            full("e2", snippets: nil, quicklinks: nil, errors: ["snippets": "malformed JSON"]),
            full("e3", snippets: #"{"snippets":"no"}"#, quicklinks: nil),
        ])
        try await sync(fake, at: t0)
        try await sync(fake, at: t0 + 120)
        XCTAssertEqual(snippetsCopy, Data(Self.snippets.utf8), "an error keeps the old copy")
        XCTAssertNil(quicklinksCopy, "null clears")
        try await sync(fake, at: t0 + 240)
        XCTAssertEqual(snippetsCopy, Data(Self.snippets.utf8), "an unreadable document keeps the old copy")
        XCTAssertEqual(MacLibrary.load(root)?.etag, "e3")
    }

    /// One Mac at a time: another's sync sends no etag and replaces the copies, even where it errs.
    func testAnotherMacReplacesTheCopy() async throws {
        try await sync(LibraryFake([full("e1")]), at: t0)
        let desk = Machine(name: "Desk", addresses: ["127.0.0.2"])
        let fake = LibraryFake([full("d1", quicklinks: nil, errors: ["quicklinks": "unreadable"])])
        try await MacLibrary.sync(desk, over: fake, root: root, defaults: defaults, force: true, now: t0 + 1)
        XCTAssertEqual(fake.etags, [nil])
        XCTAssertNil(quicklinksCopy, "Studio's never shows under Desk")
        XCTAssertEqual(MacLibrary.load(root)?.title, "From Desk")
    }

    func testToggleOffDeletesTheCopiesAndTheEtag() async throws {
        try await sync(LibraryFake([full("e1")]), at: t0)
        XCTAssertTrue(MacLibrary.syncOn(defaults), "on by default")
        MacLibrary.setSync(false, root: root, defaults: defaults)
        XCTAssertFalse(MacLibrary.syncOn(defaults))
        XCTAssertNil(snippetsCopy)
        XCTAssertNil(quicklinksCopy)
        XCTAssertNil(MacLibrary.load(root), "the etag goes too")

        let fake = LibraryFake([full("e1")])
        try await sync(fake, at: t0 + 120, force: true)
        XCTAssertEqual(fake.etags, [], "off: never asks")
        MacLibrary.setSync(true, root: root, defaults: defaults)
        try await sync(fake, at: t0 + 240)
        XCTAssertEqual(fake.etags, [nil], "on again: a full sync")
    }

    func testAtMostOnceAMinuteUnlessForced() async throws {
        let unchanged = LibraryReply(etag: "e1", unchanged: true)
        let fake = LibraryFake([full("e1"), unchanged, unchanged])
        try await sync(fake, at: t0)
        try await sync(fake, at: t0 + 30)
        XCTAssertEqual(fake.etags.count, 1, "30 s later: skipped")
        try await sync(fake, at: t0 + 61)
        XCTAssertEqual(fake.etags.count, 2)
        try await sync(fake, at: t0 + 62, force: true)
        XCTAssertEqual(fake.etags.count, 3, "Sync Now skips the throttle")
    }

    func testSnippetsWithoutVersionReadAsOne() throws {
        let doc = try XCTUnwrap(SnippetStore.decode(Data(Self.snippets.utf8)))
        XCTAssertEqual(doc.version, 1)
        XCTAssertEqual(doc.snippets.map(\.name), ["Sign"])
    }

    /// The phone's stores never write the Mac's copies: a Mac name deletes nothing there, and a
    /// local one of the same name is allowed (Settings lists both, the phone's first).
    func testTheMacsCopiesAreReadOnlyToThePhonesStores() throws {
        MacLibrary.apply(full("e1"), from: studio, root: root, now: t0)
        let snippets = SnippetStore(url: root.appendingPathComponent("Snippets/snippets.json"))
        let links = QuicklinkStore(url: root.appendingPathComponent("Quicklinks/quicklinks.json"))
        snippets.delete("Sign")
        links.delete("notes")
        XCTAssertTrue(snippets.put(.init(name: "Sign", text: "mine"), replacing: nil))
        XCTAssertTrue(links.put(.init(name: "notes", url: "https://example.com"), replacing: nil))
        XCTAssertEqual(snippetsCopy, Data(Self.snippets.utf8))
        XCTAssertEqual(quicklinksCopy, Data(Self.quicklinks.utf8))
        XCTAssertEqual(snippets.load().snippets.map(\.text), ["mine"])
        XCTAssertEqual(snippets.fromMac()?.title, "From Studio")
        XCTAssertEqual(snippets.fromMac()?.snippets.map(\.text), ["— me"])
        XCTAssertEqual(links.fromMac()?.links.map(\.name), ["notes", "Tracker"])
        XCTAssertEqual(SnippetStore.grouped(fromMac: snippets.fromMac()).map(\.title), ["From Studio"])
    }
}

/// Answers `library` from `replies` in order and records the etags it was sent.
private final class LibraryFake: SessionTransport {
    var replies: [LibraryReply]
    var etags: [String?] = []
    init(_ replies: [LibraryReply]) { self.replies = replies }
    func library(etag: String?) async throws -> LibraryReply {
        etags.append(etag)
        return replies.removeFirst()
    }
    func listSessions() async throws -> [DchSession] { [] }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
        throw TransportError.notConnected
    }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}

/// #730: the phone's own snippets to the Mac: the request (fields, nil keys left out, collection
/// as group, rich ones kept home), the hash, the per-Mac hash that skips an unchanged set, an
/// error that keeps the old one, the caps, the toggle, the op gate, and the wire. A fake Mac in
/// memory, a loopback one for the frame; a throwaway store and defaults.
@MainActor
final class SnippetPushTests: XCTestCase {
    private var dir: URL!
    private var store: SnippetStore!
    private var defaults: UserDefaults!
    private var suite = ""
    private let device = (id: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", name: String?.some("Test Phone"))

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SnippetPushTests-\(UUID())")
        store = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        suite = "SnippetPushTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private let entries: [SnippetStore.Entry] = [
        .init(name: "Sign", keyword: "sig", text: "— me", collection: "Mail"),
        .init(name: "Addr", text: "1 Main St"),
        .init(name: "Logo", text: "{\\rtf1}", richText: true),
    ]

    private func push(_ fake: SnippetsFake, _ entries: [SnippetStore.Entry], machine: String = "mac-a", clear: Bool = false) async throws {
        try await SnippetPush.push(entries, over: fake, machine: machine, defaults: defaults, device: device, clear: clear)
    }

    private func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testTheRequestCarriesThePlainSnippetsByNameWithTheirGroups() async throws {
        let fake = SnippetsFake()
        try await push(fake, entries)
        let o = json(try XCTUnwrap(fake.bodies.first))
        XCTAssertEqual(Set(o.keys), ["device_id", "device_name", "hash", "snippets"])
        XCTAssertEqual(o["device_id"] as? String, device.id)
        XCTAssertEqual(o["device_name"] as? String, "Test Phone")
        XCTAssertEqual(o["hash"] as? String, SnippetPush.hash(SnippetPush.snippets(entries)))
        let rows = try XCTUnwrap(o["snippets"] as? [[String: Any]])
        XCTAssertEqual(rows as NSArray, [["name": "Addr", "text": "1 Main St"],
                                         ["name": "Sign", "text": "— me", "keyword": "sig", "group": "Mail"]] as NSArray,
                       "by name, nil keys left out, collection as group, the rich one kept home")

        let bare = try XCTUnwrap(SnippetPush.request([], deviceId: device.id, deviceName: nil))
        XCTAssertEqual(json(bare.body) as NSDictionary, ["device_id": device.id, "hash": bare.hash, "snippets": []] as NSDictionary,
                       "no device_name key without one; an empty list is an empty array")
    }

    func testTheHashIsTheSha256OfTheSortedArrayAndFollowsAChange() throws {
        let a = SnippetPush.snippets(entries), b = SnippetPush.snippets(entries.reversed())
        XCTAssertEqual(SnippetPush.hash(a), SnippetPush.hash(b), "the store's order doesn't matter")
        let sorted = #"[{"name":"Addr","text":"1 Main St"},{"group":"Mail","keyword":"sig","name":"Sign","text":"— me"}]"#
        XCTAssertEqual(SnippetPush.hash(a), SHA256.hash(data: Data(sorted.utf8)).map { String(format: "%02x", $0) }.joined(),
                       "sorted keys, nil keys left out")
        var changed = entries
        changed[1].text = "2 Main St"
        XCTAssertNotEqual(SnippetPush.hash(SnippetPush.snippets(changed)), SnippetPush.hash(a))
        changed = entries
        changed[2].richText = nil
        XCTAssertNotEqual(SnippetPush.hash(SnippetPush.snippets(changed)), SnippetPush.hash(a), "a rich one turned plain goes")
    }

    func testAnUnchangedSetIsSentOncePerMacAndTheOkdHashIsKeptPerMac() async throws {
        let fake = SnippetsFake()
        try await push(fake, entries)
        try await push(fake, entries.reversed())
        XCTAssertEqual(fake.bodies.count, 1, "the same set: not again")
        try await push(fake, entries, machine: "mac-b")
        XCTAssertEqual(fake.bodies.count, 2, "another Mac gets its own")
        var changed = entries
        changed.append(.init(name: "New", text: "new"))
        try await push(fake, changed)
        XCTAssertEqual(fake.bodies.count, 3, "a change goes")
        XCTAssertEqual(SnippetPush.hashes(defaults), ["mac-a": SnippetPush.hash(SnippetPush.snippets(changed)),
                                                      "mac-b": SnippetPush.hash(SnippetPush.snippets(entries))])
    }

    func testARefusalKeepsTheOldHashSoTheNextConnectTriesAgain() async throws {
        let fake = SnippetsFake()
        try await push(fake, entries)
        let old = SnippetPush.hashes(defaults)
        var changed = entries
        changed[0].text = "— you"
        fake.error = TransportError.server("duplicate name: Sign")
        do { try await push(fake, changed); XCTFail("the error throws") } catch {
            XCTAssertEqual(error.localizedDescription, "duplicate name: Sign")
        }
        XCTAssertEqual(SnippetPush.hashes(defaults), old)
        fake.error = nil
        fake.echo = "something else"
        try await push(fake, changed)
        XCTAssertEqual(SnippetPush.hashes(defaults), old, "an ok echoing another hash isn't taken either")
        fake.echo = nil
        try await push(fake, changed)
        XCTAssertEqual(fake.bodies.count, 4, "each one went")
        XCTAssertEqual(SnippetPush.hashes(defaults)["mac-a"], SnippetPush.hash(SnippetPush.snippets(changed)))
    }

    func testPastTheMacsCapsNothingIsSent() async throws {
        let fake = SnippetsFake()
        let many = (0...SnippetPush.countMax).map { SnippetStore.Entry(name: "s\($0)", text: "t") }
        try await push(fake, many)
        try await push(fake, [.init(name: String(repeating: "n", count: SnippetPush.nameMax + 1), text: "t")])
        try await push(fake, [.init(name: "big", text: String(repeating: "x", count: SnippetPush.bodyMax))])
        XCTAssertEqual(fake.bodies, [], "over 5000, a name over 256, a body over 3 MB")
        XCTAssertEqual(SnippetPush.hashes(defaults), [:])
        try await push(fake, Array(many.prefix(SnippetPush.countMax - 1)) + [.init(name: String(repeating: "n", count: SnippetPush.nameMax), text: "t")])
        XCTAssertEqual(fake.bodies.count, 1, "at the caps it goes")
    }

    func testNothingWithSyncOffButAClear() async throws {
        let fake = SnippetsFake()
        defaults.set(false, forKey: MacLibrary.syncKey)
        try await push(fake, entries)
        XCTAssertEqual(fake.bodies, [])
        try await push(fake, [], clear: true)
        XCTAssertEqual(fake.bodies.count, 1)
        XCTAssertEqual((json(fake.bodies[0])["snippets"] as? [Any])?.count, 0)
        XCTAssertEqual(SnippetPush.hashes(defaults), [:], "a clear remembers nothing")
    }

    /// Sent on the handshake only when the Mac lists snippets_put; after an edit; off while
    /// connected sends one empty list and forgets the hash, so on sends the set again.
    func testTheOpGatesItAnEditGoesAndOffClearsTheMacsCopy() async throws {
        let saved = (SnippetPush.store, SnippetPush.defaults)
        SnippetPush.store = { self.store }
        SnippetPush.defaults = defaults
        defer {
            SnippetPush.offer([], over: SnippetsFake(), machine: "mac-a")
            (SnippetPush.store, SnippetPush.defaults) = saved
        }
        XCTAssertTrue(store.put(entries[0], replacing: nil))
        let fake = SnippetsFake()
        SnippetPush.offer(SessionVerb.offered(["library", "clipboard"]), over: fake, machine: "mac-a")
        XCTAssertNil(SnippetPush.mac, "no snippets_put: no Mac to send to")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.bodies, [])

        XCTAssertEqual(SessionVerb.offered(["snippets_put"]), [.snippetsPut])
        SnippetPush.offer(SessionVerb.offered(["library", "snippets_put"]), over: fake, machine: "mac-a")
        try await waitUntil("sent on connect") { !SnippetPush.running && fake.bodies.count == 1 }
        SnippetPush.offer([.snippetsPut], over: fake, machine: "mac-a")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.bodies.count, 1, "a reconnect with the same set sends nothing")

        XCTAssertTrue(store.put(entries[1], replacing: nil))
        SnippetPush.kick()
        try await waitUntil("sent after the edit") { !SnippetPush.running && fake.bodies.count == 2 }
        XCTAssertEqual((json(fake.bodies[1])["snippets"] as? [[String: Any]])?.count, 2)

        MacLibrary.setSync(false, root: dir, defaults: defaults)
        SnippetPush.setSync(false)
        try await waitUntil("the empty list") { !SnippetPush.running && fake.bodies.count == 3 }
        XCTAssertEqual((json(fake.bodies[2])["snippets"] as? [Any])?.count, 0)
        XCTAssertNil(defaults.object(forKey: SnippetPush.hashesKey), "the hashes forgotten")
        XCTAssertTrue(store.put(.init(name: "Off", text: "off"), replacing: nil))
        SnippetPush.kick()
        SnippetPush.offer([.snippetsPut], over: fake, machine: "mac-a")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.bodies.count, 3, "off: an edit or a connect sends nothing")

        MacLibrary.setSync(true, root: dir, defaults: defaults)
        SnippetPush.setSync(true)
        try await waitUntil("on again: the set") { !SnippetPush.running && fake.bodies.count == 4 }
        XCTAssertEqual((json(fake.bodies[3])["snippets"] as? [[String: Any]])?.count, 3)
    }

    func testTheWireIsFrame0x2cAndTheReplyOrTheErrorIsRead() async throws {
        let requests = Box<[(UInt8, Data)]>([])
        let reply = Box<(UInt8, String)>((0x14, #"{"count":2,"hash":"abc"}"#))
        let listener = try loopbackServer { c in
            let buf = Box(Data())
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                    if let d { buf.v.append(d) }
                    if let frame = try? FrameCodec.pop(&buf.v) {
                        requests.v.append(frame)
                        c.send(content: FrameCodec.encode(reply.v.0, Data(reply.v.1.utf8)), completion: .idempotent)
                    }
                    if done || err != nil { c.cancel() } else { read() }
                }
            }
            read()
        }
        defer { listener.cancel() }
        let end = Date().addingTimeInterval(3)
        while (listener.port?.rawValue ?? 0) == 0 {
            if Date() > end { throw XCTSkip("loopback listener never came up") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let t = ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue)
        let body = Data(#"{"device_id":"d","hash":"abc","snippets":[]}"#.utf8)
        let ok = try await t.putPhoneSnippets(body)
        XCTAssertEqual(ok.count, 2)
        XCTAssertEqual(ok.hash, "abc")
        XCTAssertEqual(requests.v.first?.0, 0x2c)
        XCTAssertEqual(requests.v.first?.1, body, "the body as built")
        reply.v = (0x13, #"{"message":"too large"}"#)
        do { _ = try await t.putPhoneSnippets(body); XCTFail("the error frame throws") } catch {
            XCTAssertEqual(error.localizedDescription, "too large")
        }
    }
}

/// Answers putPhoneSnippets ok, echoing the hash (or `echo`), or throws `error`; records each body.
private final class SnippetsFake: SessionTransport {
    var bodies: [Data] = []
    var error: Error?
    var echo: String?
    func putPhoneSnippets(_ body: Data) async throws -> (count: Int, hash: String) {
        bodies.append(body)
        if let error { throw error }
        let o = (try JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return ((o?["snippets"] as? [Any])?.count ?? 0, echo ?? o?["hash"] as? String ?? "")
    }
    func listSessions() async throws -> [DchSession] { [] }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
        throw TransportError.notConnected
    }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}
