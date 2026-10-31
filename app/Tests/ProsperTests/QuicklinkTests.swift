import XCTest
import UIKit
@testable import Prosper

@MainActor
final class QuicklinkTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy

    private var dir: URL!
    private var store: QuicklinkStore!
    private var pb: UIPasteboard!
    private var suite = ""

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuicklinkTests-\(UUID())")
        store = QuicklinkStore(url: dir.appendingPathComponent("Quicklinks/quicklinks.json"))
        pb = UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true)
        suite = "QuicklinkTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        UIPasteboard.remove(withName: pb.name)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        clearSavedShortcuts()
        super.tearDown()
    }

    /// As the Mac's `QuicklinkStore.writeFile` wrote it: its Entry, Document and encoder run on
    /// these three links.
    static let macJSON = """
    {
      "quicklinks" : [
        {
          "name" : "GitHub",
          "url" : "https://github.com/{query}"
        },
        {
          "description" : "Example search",
          "name" : "Search",
          "url" : "https://example.com/search?q={query}"
        },
        {
          "name" : "docs",
          "url" : "https://example.com/docs"
        }
      ],
      "version" : 1
    }
    """

    private func addThree() {
        store.put(.init(name: "docs", url: "https://example.com/docs"), replacing: nil)
        store.put(.init(name: " Search ", url: " https://example.com/search?q={query} ", description: "Example search\n"),
                  replacing: nil)
        store.put(.init(name: "GitHub", url: "https://github.com/{query}", description: " "), replacing: nil)
    }

    func testRoundTripsTheMacsDocument() throws {
        let doc = try XCTUnwrap(QuicklinkStore.decode(Data(Self.macJSON.utf8)))
        XCTAssertEqual(doc.quicklinks.map(\.name), ["GitHub", "Search", "docs"])
        XCTAssertEqual(String(decoding: try XCTUnwrap(QuicklinkStore.encode(doc)), as: UTF8.self), Self.macJSON)
        XCTAssertTrue(store.save(doc))
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), Self.macJSON)
        XCTAssertEqual(store.load(), doc)

        try FileManager.default.removeItem(at: store.url)
        addThree()   // trimmed and sorted as the Mac's `save` and `writeFile`
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), Self.macJSON)
    }

    func testMissingOrCorruptReadsEmptyAndKeepsABadCopy() throws {
        XCTAssertEqual(store.load(), QuicklinkStore.Document())
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load().quicklinks, [])
        XCTAssertTrue(store.put(.init(name: "docs", url: "https://example.com/docs"), replacing: nil))
        XCTAssertEqual(try String(contentsOf: store.url.appendingPathExtension("bad"), encoding: .utf8), "{ not json")
    }

    func testPutKeepsNamesUniqueAsTheMac() throws {
        addThree()
        XCTAssertFalse(store.put(.init(name: "docs", url: "https://example.com"), replacing: "GitHub"), "taken")
        XCTAssertFalse(store.put(.init(name: " ", url: "https://example.com"), replacing: nil))
        XCTAssertFalse(store.put(.init(name: "Empty", url: " "), replacing: nil))
        var edit = try XCTUnwrap(store.load().quicklinks.first { $0.name == "Search" })
        edit.name = "Find"
        XCTAssertTrue(store.put(edit, replacing: "Search"), "a rename")
        XCTAssertEqual(store.load().quicklinks.map(\.name), ["Find", "GitHub", "docs"])
        XCTAssertEqual(store.load().quicklinks.first?.description, "Example search", "the Mac's description kept")
        store.delete("Find")
        XCTAssertEqual(store.load().quicklinks.map(\.name), ["GitHub", "docs"])
    }

    /// Each expected string is what the Mac's `substitute` (quicklinks/init.lua) returned for it.
    func testFillMatchesTheMacsExtension() {
        let want: [(String, String, String)] = [
            ("https://example.com/search?q={query}", "a b&c/d", "https://example.com/search?q=a%20b%26c/d"),
            ("https://github.com/{query}", "owner/repo", "https://github.com/owner/repo"),
            ("~/notes/{query} x", "a b&c", "~/notes/a b&c x"),   // a path: never encoded
            ("https://example.com/{Query}/{ query }/{\targument }/{Argument}", "é~-._",
             "https://example.com/%C3%A9~-._/%C3%A9~-._/%C3%A9~-._/%C3%A9~-._"),
            ("https://example.com/{QUERY}?q={query}", "x", "https://example.com/{QUERY}?q=x"),   // Lua's [Qq]uery
            ("note {query}", "$0 \\1 %1", "note $0 \\1 %1"),
            ("https://example.com/?q={query}", "50%+1=#?", "https://example.com/?q=50%25%2B1%3D%23%3F"),
        ]
        for (template, arg, out) in want { XCTAssertEqual(QuicklinkStore.fill(template, with: arg), out, template) }
        XCTAssertTrue(QuicklinkStore.takesQuery("https://example.com/{ Argument }"))
        XCTAssertFalse(QuicklinkStore.takesQuery("https://example.com/{QUERY}"))
    }

    func testRecentsComeFirstThenTheRestAToZ() {
        for name in ["beta", "Alpha", "gamma", "Delta"] { store.put(.init(name: name, url: "https://example.com/\(name)"), replacing: nil) }
        store.used("gamma")
        store.used("Alpha")
        store.used("gamma")
        var order = store.ordered()
        XCTAssertEqual(order.recent.map(\.name), ["gamma", "Alpha"])
        XCTAssertEqual(order.rest.map(\.name), ["beta", "Delta"])
        store.delete("gamma")
        order = store.ordered()
        XCTAssertEqual(order.recent.map(\.name), ["Alpha"], "a deleted one goes")
        for n in 1...7 { store.used("\(n)") }
        XCTAssertEqual(store.recents, ["7", "6", "5", "4", "3"])
        XCTAssertEqual(store.recentsURL.deletingLastPathComponent(), store.url.deletingLastPathComponent(), "beside the file")
    }

    func testKeyIsAddedInTheEditorAndNeedsFullAccessAndAStore() throws {
        XCTAssertEqual(Shortcuts.quicklinks.id, "qlinks")
        XCTAssertEqual(Shortcuts.hostKey("qlinks"), .quicklinks)
        XCTAssertTrue(Shortcuts.Bar.toolbar.catalog.contains(Shortcuts.quicklinks))
        #if targetEnvironment(macCatalyst)
        XCTAssertFalse(Shortcuts.Bar.terminal.catalog.contains(Shortcuts.quicklinks))
        #else
        XCTAssertTrue(Shortcuts.Bar.terminal.catalog.contains(Shortcuts.quicklinks))
        #endif
        XCTAssertFalse(Shortcuts.Bar.toolbar.defaults.contains(Shortcuts.quicklinks), "added in the editor")
        XCTAssertFalse(Shortcuts.Bar.terminal.defaults.contains(Shortcuts.quicklinks))
        XCTAssertNotNil(UIImage(systemName: try XCTUnwrap(Shortcuts.quicklinks.systemImage)))

        let has = { (bar: SuggestionBar) in Self.caps(bar.toolbar!).contains { $0.accessibilityLabel == "quicklinks" } }
        XCTAssertFalse(has(rig("", store: store, fullAccess: false).1), "no Full Access")
        XCTAssertFalse(has(rig("", store: nil).1), "no store")
        let (kb, bar, _, _) = rig("", store: store)
        XCTAssertTrue(has(bar))
        withExtendedLifetime(kb) {}
    }

    /// A selection is the `{query}`: the URL types over it.
    func testKeyboardPickFillsTheSelection() throws {
        addThree()
        let (kb, bar, doc, view) = rig("see ", store: store)
        doc.selectedText = "swift tests"
        bar.press(Shortcuts.quicklinks)
        let panel = try XCTUnwrap(bar.quicklinksPanel)
        XCTAssertTrue(panel.superview === view)
        XCTAssertEqual(panel.sections.map(\.title), [nil])
        XCTAssertEqual(panel.sections[0].links.map(\.name), ["docs", "GitHub", "Search"])
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 2, section: 0))
        for _ in 1...50 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text, "see https://example.com/search?q=swift%20tests")
        XCTAssertNil(bar.quicklinksPanel, "a pick closes the panel")
        XCTAssertEqual(store.recents, ["Search"])

        bar.press(Shortcuts.quicklinks)
        XCTAssertEqual(try XCTUnwrap(bar.quicklinksPanel).sections.map(\.title), ["Recent", "All"])
        bar.press(Shortcuts.quicklinks)
        XCTAssertNil(bar.quicklinksPanel, "the key again: the keys back")
        withExtendedLifetime(kb) {}
    }

    /// No selection: the word before the caret, back to a blank, is the `{query}`, and goes.
    /// One with no `{query}` types at the cursor.
    func testKeyboardPickFillsTheWordBeforeTheCaret() throws {
        addThree()
        let (kb, bar, doc, view) = rig("look at owner/repo", store: store)
        bar.press(Shortcuts.quicklinks)
        var panel = try XCTUnwrap(bar.quicklinksPanel)
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 1, section: 0))
        for _ in 1...50 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text, "look at https://github.com/owner/repo")

        doc.text = "read "
        bar.press(Shortcuts.quicklinks)
        panel = try XCTUnwrap(bar.quicklinksPanel)
        XCTAssertEqual(panel.sections[1].links.map(\.name), ["docs", "Search"])
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 0, section: 1))
        for _ in 1...50 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text, "read https://example.com/docs")
        withExtendedLifetime((kb, view)) {}
    }

    /// Neither a selection nor a word: a `{query}` one is dimmed, says why, and takes no tap.
    func testKeyboardQueryLinkIsOffWithNothingToTake() throws {
        addThree()
        let (kb, bar, doc, view) = rig("go ", store: store)
        bar.press(Shortcuts.quicklinks)
        let panel = try XCTUnwrap(bar.quicklinksPanel)
        let search = IndexPath(row: 2, section: 0)
        let cell = panel.tableView(panel.table, cellForRowAt: search)
        XCTAssertTrue(cell.accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual((cell.contentConfiguration as? UIListContentConfiguration)?.secondaryText, "Select text for {query}")
        XCTAssertNil(panel.tableView(panel.table, willSelectRowAt: search))
        panel.tableView(panel.table, didSelectRowAt: search)
        XCTAssertEqual(doc.text, "go ", "a disabled one types nothing")
        XCTAssertNotNil(bar.quicklinksPanel)
        XCTAssertEqual((panel.tableView(panel.table, cellForRowAt: IndexPath(row: 0, section: 0))
            .contentConfiguration as? UIListContentConfiguration)?.secondaryText, "https://example.com/docs")
        withExtendedLifetime((kb, view)) {}
    }

    /// The terminal bar's key: a pick goes out as one bracketed paste, never a CR or LF; a
    /// `{query}` one is off there, with no selection to fill it.
    func testTerminalPickSendsOnePasteAndNoReturn() async throws {
        addThree()
        let transport = SpyTransport()
        let vc = TerminalHostVC(conn: SessionConnection(transport: transport, session: DchSession(name: "t", alias: nil)),
                                handle: TermHandle())
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        vc.view.layoutIfNeeded()
        vc.startIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        transport.stream.emit("$ ")
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.stream.emit("\u{1b}[?2004h")   // the shell turned bracketed paste on
        try await Task.sleep(nanoseconds: 50_000_000)
        vc.pasteboard = pb
        vc.quicklinks = store
        let bar = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? ShortcutBar }.first)
        let spy = transport.stream
        spy.sent = []

        bar.onKey?(Shortcuts.quicklinks)
        let panel = try XCTUnwrap(vc.quicklinksPanel)
        XCTAssertTrue(panel.superview === vc.view)
        XCTAssertNotNil(panel.unavailable(try XCTUnwrap(store.load().quicklinks.first { $0.name == "GitHub" })))
        XCTAssertNil(panel.tableView(panel.table, willSelectRowAt: IndexPath(row: 1, section: 0)))
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(spy.sent, [], "a {query} one sends nothing")
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(spy.sent, [Array("\u{1b}[200~https://example.com/docs\u{1b}[201~".utf8)])
        XCTAssertFalse(spy.sent.joined().contains { $0 == 0x0d || $0 == 0x0a }, "never a return")
        XCTAssertNil(vc.quicklinksPanel, "a pick closes the panel")
        XCTAssertEqual(store.recents, ["docs"])
    }

    func testEmptyPanelSaysWhereToAddThem() {
        let panel = QuicklinkPanel(store: store, hasQuery: true)
        XCTAssertFalse(panel.empty.isHidden)
        XCTAssertEqual(panel.empty.text, "Add quicklinks in Prosper's Settings.")
    }

    private func rig(_ text: String, store: QuicklinkStore?, fullAccess: Bool = true)
        -> (TerminalKeyboard, SuggestionBar, Proxy, UIView) {
        let doc = Proxy()
        doc.text = text
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: UserDefaults(suiteName: suite)!)))
        bar.quicklinks = store
        let pb = self.pb
        if fullAccess { bar.suggestions.pasteboard = { pb } }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        bar.attach(kb)
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults + [Shortcuts.quicklinks] }
        return (kb, bar, doc, view)
    }

    private static func caps(_ v: UIView) -> [KeyCapButton] {
        v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) }
    }
}
