import XCTest
import UIKit
@testable import Prosper

/// Snippets (#609): the store in the Mac's document, the placeholders as the Mac's engine
/// resolves them, the toolbar's key and its panel's pick. A throwaway file and a named
/// pasteboard throughout.
@MainActor
final class SnippetTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy

    private var dir: URL!
    private var store: SnippetStore!
    private var pb: UIPasteboard!
    private var suite = ""

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SnippetTests-\(UUID())")
        store = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        pb = UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true)
        suite = "SnippetTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        UIPasteboard.remove(withName: pb.name)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The Mac's `encodeDocument` output for three snippets in a listed collection, one rich,
    /// its optional fields set and unset (made by running the Mac's types and encoder).
    static let macJSON = """
    {
      "collections" : [
        {
          "name" : "Work",
          "prefix" : ";;"
        }
      ],
      "snippets" : [
        {
          "description" : "Where parcels go",
          "keyword" : "addr",
          "name" : "Home address",
          "text" : "1 Sample Street{cursor}, Springfield"
        },
        {
          "autoExpand" : false,
          "collection" : "Work",
          "name" : "Rich sign-off",
          "richText" : true,
          "text" : "{\\\\rtf1\\\\ansi Thanks}"
        },
        {
          "collection" : "Work",
          "keyword" : "su",
          "name" : "Standup template",
          "text" : "Yesterday:\\nToday:\\nBlockers: none / {date}"
        }
      ],
      "version" : 1
    }
    """

    /// Read as the Mac wrote it, written back byte for byte, rich one included; a save through
    /// the store writes the same file.
    func testRoundTripsTheMacsDocument() throws {
        let doc = try XCTUnwrap(SnippetStore.decode(Data(Self.macJSON.utf8)))
        XCTAssertEqual(doc.snippets.map(\.name), ["Home address", "Rich sign-off", "Standup template"])
        XCTAssertEqual(doc.snippets[1].richText, true)
        XCTAssertEqual(doc.collections, [.init(name: "Work", prefix: ";;")])
        XCTAssertEqual(String(decoding: try XCTUnwrap(SnippetStore.encode(doc)), as: UTF8.self), Self.macJSON)

        XCTAssertTrue(store.save(doc))
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), Self.macJSON)
        XCTAssertEqual(store.load(), doc)
    }

    /// None yet reads as empty; an unreadable file too, kept as `.bad` before a save replaces it.
    func testMissingOrCorruptReadsEmptyAndKeepsABadCopy() throws {
        XCTAssertEqual(store.load(), SnippetStore.Document())
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load().snippets, [])
        XCTAssertTrue(store.put(.init(name: "Home address", text: "1 Sample Street"), replacing: nil))
        XCTAssertEqual(try String(contentsOf: store.url.appendingPathExtension("bad"), encoding: .utf8), "{ not json")
        XCTAssertEqual(store.load().snippets.map(\.name), ["Home address"])
    }

    /// Normalised as the Mac's save: name trimmed, keyword without blanks or quotes, blanks
    /// unset; another's name refused, its own kept on an edit; the Mac's fields kept.
    func testPutKeepsNamesUniqueAsTheMac() throws {
        XCTAssertTrue(store.put(.init(name: " Home address ", keyword: " a 'd\"r ", text: "x", collection: "",
                                      description: "Mac's"), replacing: nil))
        XCTAssertEqual(store.load().snippets, [.init(name: "Home address", keyword: "adr", text: "x", description: "Mac's")])
        XCTAssertTrue(store.put(.init(name: "Standup template", text: "y", collection: "Work"), replacing: nil))
        XCTAssertFalse(store.put(.init(name: "Home address", text: "z"), replacing: "Standup template"), "taken")
        XCTAssertFalse(store.put(.init(name: " ", text: "z"), replacing: nil))
        XCTAssertFalse(store.put(.init(name: "Empty", text: ""), replacing: nil))
        var edit = try XCTUnwrap(store.load().snippets.first)
        edit.text = "1 Sample Street"
        XCTAssertTrue(store.put(edit, replacing: "Home address"))
        edit.name = "Address"
        XCTAssertTrue(store.put(edit, replacing: "Home address"), "a rename")
        XCTAssertEqual(store.load().snippets.map(\.name), ["Address", "Standup template"])
        XCTAssertEqual(store.load().snippets.first?.description, "Mac's")
        store.delete("Address")
        XCTAssertEqual(store.load().snippets.map(\.name), ["Standup template"])
    }

    /// The Mac's engine's output for a fixed moment, en_GB in UTC (taken from running the Mac's
    /// file); unknown tokens literal, as there.
    func testPlaceholdersMatchTheMac() {
        var ctx = PlaceholderContext()
        let now = Date(timeIntervalSince1970: 1_793_459_045)   // 2026-10-31 15:04:05 UTC
        ctx.now = { now }
        ctx.locale = Locale(identifier: "en_GB")
        ctx.timeZone = TimeZone(identifier: "UTC")!
        let want = [
            "{date}": "31 Oct 2026", "{time}": "15:04", "{datetime}": "31 Oct 2026 at 15:04",
            "{date short}": "10/31/26", "{date long}": "October 31, 2026", "{date full}": "Saturday, October 31, 2026",
            "{date:yyyy-MM-dd}": "2026-10-31", "{date +1d}": "1 Nov 2026", "{time:HH:mm}": "15:04",
            "{unknown} {\"k\": 1}": "{unknown} {\"k\": 1}", "{{x}}": "{x}", "{argument name=who default=you}": "you",
        ]
        for (template, text) in want { XCTAssertEqual(PlaceholderEngine.render(template, ctx).text, text, template) }
    }

    /// `{cursor}` gives the Characters back from the end, `{clipboard}` reads the pasteboard
    /// given, `{snippet}` another's text; a required `{argument}` or rich text can't go in.
    func testResolveAndWhatCantGoIn() {
        pb.string = "copied"
        store.put(.init(name: "Sign", keyword: "sig", text: "— me"), replacing: nil)
        let r = store.resolve(.init(name: "a", text: "Hi {clipboard}, 🙂{cursor} ok {snippet sig}"), pasteboard: pb, history: nil)
        XCTAssertEqual(r.text, "Hi copied, 🙂 ok — me")
        XCTAssertEqual(r.back, 8)
        XCTAssertEqual(store.resolve(.init(name: "b", text: "{clipboard}"), pasteboard: nil, history: nil).text, "")
        XCTAssertEqual(store.resolve(.init(name: "c", text: "plain"), pasteboard: pb, history: nil).back, 0)

        XCTAssertNil(SnippetStore.Entry(name: "d", text: "Hi {argument name=who default=you}").unavailable)
        XCTAssertNotNil(SnippetStore.Entry(name: "e", text: "Hi {argument name=who}").unavailable)
        XCTAssertNotNil(SnippetStore.Entry(name: "f", text: "Hi {argument}").unavailable)
        XCTAssertNotNil(SnippetStore.Entry(name: "g", text: "x", richText: true).unavailable)
    }

    /// The toolbar's and the terminal's, added in the editor, an iOS 16 symbol; on the toolbar
    /// only with Full Access and a store, as the clipboard's.
    func testKeyIsAddedInTheEditorAndNeedsFullAccessAndAStore() throws {
        XCTAssertEqual(Shortcuts.snippets.id, "snips")
        XCTAssertEqual(Shortcuts.hostKey("snips"), .snippets)
        XCTAssertTrue(Shortcuts.Bar.toolbar.catalog.contains(Shortcuts.snippets))
        #if !targetEnvironment(macCatalyst)
        XCTAssertTrue(Shortcuts.Bar.terminal.catalog.contains(Shortcuts.snippets))
        #endif
        XCTAssertFalse(Shortcuts.Bar.toolbar.defaults.contains(Shortcuts.snippets), "added in the editor")
        XCTAssertFalse(Shortcuts.Bar.terminal.defaults.contains(Shortcuts.snippets))
        XCTAssertNotNil(UIImage(systemName: try XCTUnwrap(Shortcuts.snippets.systemImage)))

        let has = { (bar: SuggestionBar) in Self.caps(bar.toolbar!).contains { $0.accessibilityLabel == "snippets" } }
        XCTAssertFalse(has(rig("", store: store, fullAccess: false).1), "no Full Access")
        XCTAssertFalse(has(rig("", store: nil).1), "no store")
        let (kb, bar, _, _) = rig("", store: store)
        XCTAssertTrue(has(bar))
        withExtendedLifetime(kb) {}
    }

    /// The panel by collection, the uncollected first; one that can't go in is dimmed and takes
    /// no tap. A pick types it resolved and walks the caret back to `{cursor}`, closing the panel.
    func testKeyboardPickTypesItAndMovesTheCaret() throws {
        store.put(.init(name: "Home address", text: "1 Sample Street{cursor}, Springfield"), replacing: nil)
        store.put(.init(name: "Standup template", text: "Yesterday:\nToday:", collection: "Work"), replacing: nil)
        store.put(.init(name: "Ask", text: "Hi {argument name=who}", collection: "Work"), replacing: nil)
        let (kb, bar, doc, view) = rig("Ship to ", store: store)

        bar.press(Shortcuts.snippets)
        var panel = try XCTUnwrap(bar.snippetsPanel)
        XCTAssertTrue(panel.superview === view)
        XCTAssertEqual(panel.groups.map(\.title), ["", "Work"])
        XCTAssertEqual(panel.groups[1].snippets.map(\.name), ["Ask", "Standup template"])
        XCTAssertNil(panel.tableView(panel.table, titleForHeaderInSection: 0))
        let ask = IndexPath(row: 0, section: 1)
        XCTAssertTrue(panel.tableView(panel.table, cellForRowAt: ask).accessibilityTraits.contains(.notEnabled))
        XCTAssertNil(panel.tableView(panel.table, willSelectRowAt: ask))
        panel.tableView(panel.table, didSelectRowAt: ask)
        XCTAssertEqual(doc.text, "Ship to ", "a disabled one types nothing")
        XCTAssertNotNil(bar.snippetsPanel)

        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 0, section: 0))
        for _ in 1...50 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text + "|" + (doc.after ?? ""), "Ship to 1 Sample Street|, Springfield")
        XCTAssertNil(bar.snippetsPanel, "a pick closes the panel")

        bar.press(Shortcuts.snippets)
        panel = try XCTUnwrap(bar.snippetsPanel)
        bar.press(Shortcuts.clipboard)
        XCTAssertNil(bar.snippetsPanel, "one panel at a time")
        bar.press(Shortcuts.snippets)
        XCTAssertNotNil(bar.snippetsPanel)
        bar.press(Shortcuts.snippets)
        XCTAssertNil(bar.snippetsPanel, "the key again: the keys back")
        withExtendedLifetime(kb) {}
    }

    /// #614: the Mac's after the phone's, under "From <Mac>" (and its collections); a name on
    /// both shows twice, the phone's first; a pick types as a local one, `{snippet}` reaching the
    /// Mac's keywords too.
    func testMacSnippetsFollowThePhonesAndPickAsLocalOnes() throws {
        store.put(.init(name: "Home address", text: "local"), replacing: nil)
        let mac = #"{"snippets":[{"name":"Home address","text":"mac"},{"name":"Sign","text":"Hi{cursor} {snippet bye}"},"#
            + #"{"name":"Bye","keyword":"bye","text":"bye","collection":"Work"}]}"#
        MacLibrary.apply(LibraryReply(etag: "e1", snippets: Data(mac.utf8)), from: Machine(name: "Studio", addresses: []), root: dir)
        let (kb, bar, doc, view) = rig("x ", store: store)
        bar.press(Shortcuts.snippets)
        let panel = try XCTUnwrap(bar.snippetsPanel)
        XCTAssertEqual(panel.groups.map(\.title), ["", "From Studio", "From Studio · Work"])
        XCTAssertEqual(panel.groups[0].snippets.map(\.text), ["local"])
        XCTAssertEqual(panel.groups[1].snippets.map(\.name), ["Home address", "Sign"])
        XCTAssertEqual(panel.tableView(panel.table, titleForHeaderInSection: 1), "From Studio")
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 1, section: 1))
        for _ in 1...50 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text + "|" + (doc.after ?? ""), "x Hi| bye")
        XCTAssertNil(bar.snippetsPanel, "a pick closes the panel")
        withExtendedLifetime((kb, view)) {}
    }

    /// No snippets: the note says where to add them.
    func testEmptyPanelSaysWhereToAddThem() {
        let panel = SnippetPanel(store: store)
        XCTAssertFalse(panel.empty.isHidden)
        XCTAssertEqual(panel.empty.text, "Add snippets in Prosper's Settings.")
    }

    private func rig(_ text: String, store: SnippetStore?, fullAccess: Bool = true)
        -> (TerminalKeyboard, SuggestionBar, Proxy, UIView) {
        let doc = Proxy()
        doc.text = text
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: UserDefaults(suiteName: suite)!)))
        bar.snippets = store
        bar.history = ClipboardHistory(dir: dir.appendingPathComponent("history"))
        let pb = self.pb
        if fullAccess { bar.suggestions.pasteboard = { pb } }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        bar.attach(kb)
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults + [Shortcuts.clipboard, Shortcuts.snippets] }
        return (kb, bar, doc, view)
    }

    private static func caps(_ v: UIView) -> [KeyCapButton] {
        v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) }
    }
}
