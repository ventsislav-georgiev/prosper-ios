import XCTest
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
