import XCTest
import UIKit
@testable import Prosper

/// #735: the Mac's commands from the keyboard's menu: the tile's gate, the panel's Recent and
/// groups, Run's row for the ones that ask, the argument from the selection or the field, the
/// Mac's cap, the reply inline with Insert, errors in red, the Recent kept, the app's copy of
/// the list and its Mac, the fetch as the panel opens, and a run's deadline. A fake Mac throughout (`FakeMac`): nothing dials a real one, and Full Access is a named
/// pasteboard, never the general one.
@MainActor
final class KeyboardCommandsTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy
    typealias Row = CommandPanel.Row

    /// The Mac: its list (held till `release` with `holdList`), each run's reply (with `hold`), what
    /// it was asked.
    @MainActor
    final class FakeMac: SessionTransport {
        var list: [MacCommand]
        var reply: Result<CommandResult, Error> = .success(CommandResult(text: "42", detail: "6 × 7"))
        var hold = false
        var holdList = false
        private var waiting: CheckedContinuation<Void, Never>?
        private(set) var runs: [(id: String, argument: String?)] = []
        private(set) var lists = 0

        init(list: [MacCommand]) { self.list = list }

        func commands() async throws -> [MacCommand] {
            lists += 1
            if holdList { await withCheckedContinuation { waiting = $0 } }
            return list
        }

        func runCommand(id: String, argument: String?) async throws -> CommandResult {
            runs.append((id, argument))
            if hold { await withCheckedContinuation { waiting = $0 } }
            return try reply.get()
        }

        func release() {
            waiting?.resume()
            waiting = nil
        }

        func listSessions() async throws -> [DchSession] { [] }
        func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
        func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
            throw TransportError.notConnected
        }
        func kill(name: String) async throws {}
        func rename(name: String, alias: String?) async throws {}
    }

    static let list = [
        MacCommand(id: "calc.eval", title: "Calculate", subtitle: "Evaluate an expression", ext: "Calculator", argument: "2+2", icon: "function"),
        MacCommand(id: "toggles.lock", title: "Lock Screen", ext: "System", icon: "lock"),
        MacCommand(id: "fans.auto", title: "Fans Automatic", ext: "Fans", icon: "fan"),
        MacCommand(id: "toggles.screensaver", title: "Screen Saver", ext: "System", icon: "sparkles"),
        MacCommand(id: "acme.notes/new", title: "New Note", ext: "Acme Notes", argument: "Title"),
    ]
    static let studio = Machine(name: "Studio", addresses: ["studio.example.test", "100.64.0.9"])

    private var dir: URL!
    private var store: CommandStore!
    private var mac: FakeMac!
    private var pb: UIPasteboard!
    private var suite = ""

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("KeyboardCommandsTests-\(UUID())")
        store = CommandStore(dir: dir.appendingPathComponent("Commands"))
        mac = FakeMac(list: Self.list)
        pb = UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true)
        suite = "KeyboardCommandsTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        mac?.release()
        try? FileManager.default.removeItem(at: dir)
        UIPasteboard.remove(withName: pb.name)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func cache() { store.save(.init(machine: Self.studio, commands: Self.list)) }

    /// `CommandsSession.reach` on the fake: the list is its probe, as the real one's.
    private func reaching(_ mac: FakeMac) -> () async throws -> (SessionTransport, [MacCommand]) {
        { (mac, try await mac.commands()) }
    }

    private func panel(_ selection: String? = nil) -> CommandPanel {
        cache()
        let mac = mac!
        let p = CommandPanel(session: CommandsSession(cached: store.load()!, store: store, reach: reaching(mac)), recent: store.recent)
        p.selected = { selection }
        return p
    }

    private func command(_ id: String) -> MacCommand { Self.list.first { $0.id == id }! }

    private func rows(_ p: CommandPanel, _ title: String) -> [Row] { p.sections.first { $0.title == title }?.rows ?? [] }

    private func cell(_ p: CommandPanel, _ title: String, _ row: Int) -> UITableViewCell {
        p.tableView(p.table, cellForRowAt: IndexPath(row: row, section: p.sections.firstIndex { $0.title == title }!))
    }

    private func button(_ v: UIView, _ title: String) -> UIButton? {
        if let b = v as? UIButton, b.configuration?.title == title { return b }
        return v.subviews.lazy.compactMap { self.button($0, title) }.first
    }

    /// The row's own labels, not its buttons' titles.
    private func labels(_ v: UIView) -> [UILabel] {
        v.subviews.flatMap { $0 is UIButton ? [] : ($0 as? UILabel).map { [$0] } ?? labels($0) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)   // the panel's redraw, a turn after the change
    }

    private func rig(_ text: String = "", store: CommandStore?, fullAccess: Bool = true)
        -> (TerminalKeyboard, SuggestionBar, Proxy, UIView) {
        let doc = Proxy()
        doc.text = text
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: UserDefaults(suiteName: suite)!)))
        bar.commandStore = store
        let mac = mac!
        bar.reach = { [unowned self] _ in reaching(mac) }
        let pb = self.pb
        if fullAccess { bar.suggestions.pasteboard = { pb } }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        bar.attach(kb)
        bar.host(kb, in: view)
        return (kb, bar, doc, view)
    }

    // MARK: - The tile

    /// Only with Full Access and a Mac cached, its list fetched or not, after Rewrite's place and
    /// before Emoji; it opens the panel.
    func testTheTileNeedsFullAccessAndACachedMac() throws {
        let has = { (bar: SuggestionBar) in bar.menuItems.contains { $0.title == "Commands" } }
        XCTAssertFalse(has(rig(store: nil).1), "no store")
        XCTAssertFalse(has(rig(store: store).1), "no Mac")
        store.connected(Self.studio)
        XCTAssertTrue(has(rig(store: store).1), "a Mac, no list yet")
        cache()
        let (kb0, off, _, _) = rig(store: store, fullAccess: false)
        XCTAssertFalse(has(off), "no Full Access")
        off.showCommands(true)
        XCTAssertNil(off.commandsPanel, "nor the panel")

        let (kb, bar, _, view) = rig(store: store)
        let titles = bar.menuItems.map(\.title)
        let at = try XCTUnwrap(titles.firstIndex(of: "Commands"))
        XCTAssertEqual(titles[at + 1], "Emoji", "before Emoji")
        XCTAssertEqual(bar.menuItems[at].symbol, "command")
        bar.showMenu(true)
        bar.menuItems[at].run()
        let panel = try XCTUnwrap(bar.commandsPanel)
        XCTAssertTrue(panel.superview === view)
        withExtendedLifetime((kb0, kb, view)) {}
    }

    // MARK: - The panel

    /// Recent first (a run id the Mac no longer lists is left out), then each extension's in the
    /// Mac's order; search matches the groups' only, so nothing shows twice.
    func testThePanelListsRecentThenTheGroups() {
        store.ran("toggles.lock")
        store.ran("gone.away")
        store.ran("calc.eval")
        let p = panel()
        XCTAssertEqual(p.sections.map(\.title), ["Recent", "Calculator", "System", "Fans", "Acme Notes"])
        XCTAssertEqual(rows(p, "Recent"), [.command(command("calc.eval")), .command(command("toggles.lock"))])
        XCTAssertEqual(rows(p, "System"), [.command(command("toggles.lock")), .command(command("toggles.screensaver"))])
        XCTAssertEqual(p.tableView(p.table, titleForHeaderInSection: 0), "Recent")
        XCTAssertEqual(p.searchable.count, Self.list.count)
        XCTAssertFalse(p.searchable.contains { $0.row.section == 0 })
        XCTAssertTrue(p.empty.isHidden)

        let none = CommandPanel(session: CommandsSession(transport: mac), recent: [])
        XCTAssertEqual(none.sections.count, 0)
        XCTAssertFalse(none.empty.isHidden)
    }

    /// Lock, display off, the lid, the fans and every extension's ("/") ask in a row under them,
    /// Run or Cancel; Calculate runs at the tap.
    func testRunsRowOnlyForTheOnesThatAsk() async throws {
        XCTAssertTrue(CommandsSession.asks("fans.auto"))
        XCTAssertTrue(CommandsSession.asks("acme.notes/new"))
        XCTAssertFalse(CommandsSession.asks("calc.eval"))
        let p = panel("6*7")
        p.tap(command("toggles.lock"), in: "System")
        XCTAssertEqual(rows(p, "System"), [.command(command("toggles.lock")), .confirm(command("toggles.lock")),
                                           .command(command("toggles.screensaver"))])
        XCTAssertEqual(labels(cell(p, "System", 1)).first?.text, "Run Lock Screen?")
        XCTAssertTrue(mac.runs.isEmpty, "nothing sent before Run")
        try XCTUnwrap(button(cell(p, "System", 1), "Cancel")).sendActions(for: .touchUpInside)
        XCTAssertEqual(rows(p, "System").count, 2, "Cancel: the row goes")
        XCTAssertTrue(mac.runs.isEmpty)

        p.tap(command("toggles.lock"), in: "System")
        try XCTUnwrap(button(cell(p, "System", 1), "Run")).sendActions(for: .touchUpInside)
        try await waitUntil("the reply") { p.session.outcome != nil }
        XCTAssertEqual(mac.runs.map(\.id), ["toggles.lock"])
        XCTAssertNil(mac.runs[0].argument)

        p.tap(command("acme.notes/new"), in: "Acme Notes")
        XCTAssertEqual(rows(p, "Acme Notes").last, .confirm(command("acme.notes/new")), "an extension's asks too")

        p.tap(command("calc.eval"), in: "Calculator")
        XCTAssertEqual(rows(p, "Calculator").count, 1, "no Run row")
        try await waitUntil("the reply") { p.session.running == nil && mac.runs.count == 2 }
        XCTAssertEqual(mac.runs.last?.id, "calc.eval")
    }

    /// The selection is the text, trimmed; without one the search row is its field, the hint its
    /// placeholder, and Return runs it on what was typed (nothing typed: nothing runs).
    func testTheArgumentIsTheSelectionElseTheField() async throws {
        var selection: String? = "  6*7 "
        let p = panel()
        p.selected = { selection }
        p.tap(command("calc.eval"), in: "Calculator")
        XCTAssertNil(p.filter)
        try await waitUntil("the reply") { p.session.running == nil && !mac.runs.isEmpty }
        XCTAssertEqual(mac.runs.last?.argument, "6*7")

        selection = nil
        p.tap(command("calc.eval"), in: "Calculator")
        let field = try XCTUnwrap(p.filter, "the field over the list")
        XCTAssertEqual(field.placeholder, "2+2")
        XCTAssertEqual(field.matches, [0], "the command alone under it")
        field.pickFirst()
        XCTAssertNotNil(p.filter, "nothing typed: it stays")
        XCTAssertEqual(mac.runs.count, 1)
        for c in "1+1" { field.type(String(c)) }
        XCTAssertEqual(field.matches, [0], "typing doesn't filter it away")
        field.pickFirst()
        XCTAssertNil(p.filter, "Return: the list back")
        try await waitUntil("the reply") { p.session.running == nil && mac.runs.count == 2 }
        XCTAssertEqual(mac.runs.last?.argument, "1+1")
        XCTAssertEqual(rows(p, "Calculator").last, .outcome(.init(id: "calc.eval", result: CommandResult(text: "42", detail: "6 × 7"))))
    }

    /// Over the Mac's 1024 bytes: said in red under it, nothing sent; at 1024 it goes.
    func testTheMacsCap() async throws {
        var selection = String(repeating: "é", count: 513)   // 1026 bytes
        let p = panel()
        p.selected = { selection }
        p.tap(command("calc.eval"), in: "Calculator")
        XCTAssertEqual(rows(p, "Calculator").last, .outcome(.init(id: "calc.eval", error: "Too long for the Mac: at most 1024 bytes.")))
        XCTAssertTrue(mac.runs.isEmpty)
        selection = String(repeating: "é", count: 512)
        p.tap(command("calc.eval"), in: "Calculator")
        try await waitUntil("the reply") { p.session.running == nil && !mac.runs.isEmpty }
        XCTAssertEqual(mac.runs.last?.argument?.utf8.count, 1024)
    }

    /// A spinner on the running row; every other row off till the reply.
    func testOneRunAtATime() async throws {
        mac.hold = true
        let p = panel()
        p.tap(command("toggles.screensaver"), in: "System")
        try await waitUntil("the run sent") { mac.runs.count == 1 }
        XCTAssertTrue(cell(p, "System", 1).accessoryView is UIActivityIndicatorView)
        XCTAssertNil(cell(p, "System", 0).accessoryView)
        XCTAssertTrue(cell(p, "System", 0).accessibilityTraits.contains(.notEnabled))
        XCTAssertNil(p.tableView(p.table, willSelectRowAt: IndexPath(row: 0, section: 0)), "others off")
        p.tableView(p.table, didSelectRowAt: IndexPath(row: 0, section: 2))
        XCTAssertEqual(mac.runs.count, 1)
        mac.release()
        try await waitUntil("the reply") { p.session.running == nil }
        XCTAssertNil(cell(p, "System", 1).accessoryView)
        XCTAssertNotNil(p.tableView(p.table, willSelectRowAt: IndexPath(row: 0, section: 0)))
    }

    /// The reply big with its detail; Insert types its text at the cursor and closes the panel.
    func testInsertTypesTheReplyAndCloses() async throws {
        cache()
        let (kb, bar, doc, view) = rig("x = ", store: store)
        doc.selectedText = "6*7"
        bar.showCommands(true)
        let p = try XCTUnwrap(bar.commandsPanel)
        p.tableView(p.table, didSelectRowAt: IndexPath(row: 0, section: 0))
        try await waitUntil("the reply") { p.session.outcome != nil }
        let reply = cell(p, "Calculator", 1)
        XCTAssertEqual(labels(reply).map(\.text), ["42", "6 × 7"])
        XCTAssertEqual(labels(reply).first?.font.pointSize, 22)
        try XCTUnwrap(button(reply, "Insert")).sendActions(for: .touchUpInside)
        for _ in 1...50 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text, "x = 42")
        XCTAssertNil(bar.commandsPanel, "Insert closes the panel")

        mac.reply = .success(CommandResult(text: " "))
        doc.selectedText = "0/1"
        bar.showCommands(true)
        let again = try XCTUnwrap(bar.commandsPanel)
        again.tap(command("calc.eval"), in: "Calculator")
        try await waitUntil("the reply") { again.session.outcome != nil }
        XCTAssertNil(button(cell(again, "Calculator", 1), "Insert"), "no text, no Insert, even where it inserts")
        withExtendedLifetime((kb, view)) {}
    }

    /// #740: Insert only on a content reply: Calculate's and an extension's, never an action's
    /// acknowledgement ("Screen locked"), the fans' Manual with its text included.
    func testInsertOnlyOnContentReplies() async throws {
        XCTAssertFalse(CommandsSession.inserts(MacCommand(id: "fans.manual", title: "Fans: Manual", ext: "Fans", argument: "60%")))
        let p = panel()
        // Calculate's field: * on the 123 keys' #+= page.
        p.tap(command("calc.eval"), in: "Calculator")
        let field = try XCTUnwrap(p.filter)
        func key(_ c: String) throws { try XCTUnwrap(field.rows.joined().first { $0.configuration?.title == c }, c).sendActions(for: .touchUpInside) }
        field.toggle.sendActions(for: .touchUpInside)
        try key("6")
        field.more.sendActions(for: .touchUpInside)
        try key("*")
        field.more.sendActions(for: .touchUpInside)
        try key("7")
        field.pickFirst()
        try await waitUntil("the reply") { p.session.running == nil && mac.runs.count == 1 }
        XCTAssertEqual(mac.runs.last?.argument, "6*7")
        XCTAssertNotNil(button(cell(p, "Calculator", 1), "Insert"), "Calculate's")

        mac.reply = .success(CommandResult(text: "Screen locked"))
        p.tap(command("toggles.lock"), in: "System")
        try XCTUnwrap(button(cell(p, "System", 1), "Run")).sendActions(for: .touchUpInside)
        try await waitUntil("the reply") { p.session.running == nil && mac.runs.count == 2 }
        XCTAssertEqual(labels(cell(p, "System", 1)).first?.text, "Screen locked")
        XCTAssertNil(button(cell(p, "System", 1), "Insert"), "an acknowledgement")

        mac.reply = .success(CommandResult(text: "Note 12 created"))
        p.selected = { "Groceries" }
        p.tap(command("acme.notes/new"), in: "Acme Notes")
        try XCTUnwrap(button(cell(p, "Acme Notes", 1), "Run")).sendActions(for: .touchUpInside)
        try await waitUntil("the reply") { p.session.running == nil && mac.runs.count == 3 }
        XCTAssertNotNil(button(cell(p, "Acme Notes", 1), "Insert"), "an extension's")
    }

    /// An unreachable Mac, and the Mac's refusals, in red under the row; neither goes into Recent.
    func testErrorsShowInline() async throws {
        do {
            _ = try await CommandsSession.reach([])()   // no address: nothing dialed
            XCTFail("reached nothing")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Mac not reachable")
        }
        cache()
        let (kb, bar, _, view) = rig(store: store)
        bar.reach = { _ in { throw TransportError.server("Mac not reachable") } }
        bar.showCommands(true)
        var p = try XCTUnwrap(bar.commandsPanel)
        p.tap(command("toggles.screensaver"), in: "System")
        try await waitUntil("the error") { p.session.outcome != nil }
        XCTAssertEqual(rows(p, "System").last, .outcome(.init(id: "toggles.screensaver", error: "Mac not reachable")))
        let line = try XCTUnwrap(labels(cell(p, "System", 2)).first)
        XCTAssertEqual(line.text, "Mac not reachable")
        XCTAssertEqual(line.textColor, .systemRed)

        let mac = mac!
        bar.reach = { [unowned self] _ in reaching(mac) }
        mac.reply = .failure(TransportError.server("not allowed"))
        bar.showCommands(true)
        p = try XCTUnwrap(bar.commandsPanel)
        p.tap(command("toggles.screensaver"), in: "System")
        try await waitUntil("the error") { p.session.outcome != nil }
        XCTAssertEqual(p.session.outcome?.error, "That command isn't available on the Mac now. The list is refreshed.")
        XCTAssertEqual(store.recent, [])
        // Gone from the Mac's list: the list fetched again drops it, its reply on top.
        mac.list = Self.list.filter { $0.id != "calc.eval" }
        p.tap(command("calc.eval"), in: "Calculator")
        p.filter(false)
        p.session.drafts["calc.eval"] = "1+1"
        p.go(command("calc.eval"))
        try await waitUntil("the list again") { p.session.commands?.count == 4 }
        XCTAssertEqual(p.sections.first?.rows, [.outcome(.init(id: "calc.eval", error: "That command isn't available on the Mac now. The list is refreshed."))])
        XCTAssertNil(p.tableView(p.table, titleForHeaderInSection: 0))
        XCTAssertFalse(p.sections.contains { $0.title == "Calculator" })
        withExtendedLifetime((kb, view)) {}
    }

    /// A run that lands goes first in the Recent, which keeps four; the list is fetched again then,
    /// and the copy written. The panel's rows stay as they opened.
    func testRecentAndTheListAfterARun() async throws {
        for id in ["a", "b", "c", "b", "d", "e"] { store.ran(id) }
        XCTAssertEqual(store.recent, ["e", "d", "b", "c"])

        let p = panel()
        store.ran("calc.eval")   // as another run
        XCTAssertEqual(p.recent, ["e", "d", "b", "c"])
        let added = MacCommand(id: "toggles.dark", title: "Dark Mode", ext: "System")
        mac.list = Self.list + [added]
        p.tap(command("toggles.screensaver"), in: "System")
        // The probe as the run reached the Mac, then the list again (the panel's own fetch, as it opens, is `showCommands`').
        try await waitUntil("the list again") { mac.lists == 2 && p.session.commands?.count == 6 }
        XCTAssertEqual(store.recent, ["toggles.screensaver", "calc.eval", "e", "d"])
        XCTAssertEqual(store.load()?.commands.last, added, "the copy refreshed")
        XCTAssertEqual(store.load()?.machine, Self.studio)
        XCTAssertEqual(rows(p, "System").map { if case .command(let c) = $0 { c.id } else { "-" } },
                       ["toggles.lock", "toggles.screensaver", "-", "toggles.dark"], "the reply under its row")
    }

    /// The app's Commands screen writes each list it fetches, with its Mac; without one, nothing.
    func testTheAppWritesTheCopyOnFetch() async {
        let plain = CommandsSession(transport: mac)
        await plain.load()
        XCTAssertNil(store.load())

        let s = CommandsSession(transport: mac, cache: (store, Self.studio))
        await s.load()
        XCTAssertEqual(store.load(), .init(machine: Self.studio, commands: Self.list))
        XCTAssertEqual(mac.lists, 2)
        XCTAssertTrue(mac.runs.isEmpty)
    }

    /// The app on a Mac (`SessionListView.handshake`) writes it: the same Mac keeps its list, with
    /// its addresses as now; another starts with none, for the panel to fetch.
    func testTheAppWritesTheMacOnConnect() {
        store.connected(Self.studio)
        XCTAssertEqual(store.load(), .init(machine: Self.studio, commands: []))
        cache()
        var moved = Self.studio
        moved.addresses = ["100.64.0.10"]
        store.connected(moved)
        XCTAssertEqual(store.load(), .init(machine: moved, commands: Self.list), "the same Mac keeps its list")
        let other = Machine(name: "Mini", addresses: ["mini.example.test"])
        store.connected(other)
        XCTAssertEqual(store.load(), .init(machine: other, commands: []), "another Mac: none")
    }

    // MARK: - The fetch as the panel opens

    /// Each open shows the copy at once and fetches the list once, writing it; no more after.
    func testOpeningFetchesTheListOnce() async throws {
        cache()
        let added = MacCommand(id: "toggles.dark", title: "Dark Mode", ext: "System")
        mac.list = Self.list + [added]
        let (kb, bar, _, view) = rig(store: store)
        bar.showCommands(true)
        let p = try XCTUnwrap(bar.commandsPanel)
        XCTAssertEqual(p.session.commands, Self.list, "the copy at once")
        XCTAssertTrue(p.session.loading)
        try await waitUntil("the list") { !p.session.loading }
        XCTAssertEqual(p.session.commands?.last, added)
        XCTAssertEqual(store.load()?.commands.last, added, "the copy written")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mac.lists, 1, "one fetch, no polling")
        XCTAssertTrue(mac.runs.isEmpty)
        bar.showCommands(false)
        bar.showCommands(true)
        try await waitUntil("the list again") { bar.commandsPanel?.session.loading == false }
        XCTAssertEqual(mac.lists, 2, "one per open")
        withExtendedLifetime((kb, view)) {}
    }

    /// A Mac with no list yet: a spinner and "Fetching commands from <Mac>…", then the rows.
    func testAnEmptyListSpinsThenShowsTheRows() async throws {
        store.connected(Self.studio)
        mac.holdList = true
        let (kb, bar, _, view) = rig(store: store)
        bar.showCommands(true)
        let p = try XCTUnwrap(bar.commandsPanel)
        try await waitUntil("the fetch sent") { mac.lists == 1 }
        XCTAssertEqual(p.empty.text, "Fetching commands from Studio…")
        XCTAssertFalse(p.empty.isHidden)
        XCTAssertTrue(p.spinner.isAnimating)
        XCTAssertTrue(p.sections.isEmpty)
        mac.release()
        try await waitUntil("the rows") { !p.sections.isEmpty }
        XCTAssertEqual(p.sections.map(\.title), ["Calculator", "System", "Fans", "Acme Notes"])
        XCTAssertTrue(p.empty.isHidden)
        XCTAssertFalse(p.spinner.isAnimating)
        withExtendedLifetime((kb, view)) {}
    }

    /// The fetch failing: "Mac not reachable" in red, in the note with no list, on top of a list kept.
    func testAFailedFetchSaysSo() async throws {
        store.connected(Self.studio)
        let (kb, bar, _, view) = rig(store: store)
        bar.reach = { _ in { throw TransportError.server("Mac not reachable") } }
        bar.showCommands(true)
        var p = try XCTUnwrap(bar.commandsPanel)
        try await waitUntil("the error") { !p.session.loading }
        XCTAssertEqual(p.empty.text, "Mac not reachable")
        XCTAssertEqual(p.empty.textColor, .systemRed)
        XCTAssertFalse(p.spinner.isAnimating)

        cache()
        bar.showCommands(true)
        p = try XCTUnwrap(bar.commandsPanel)
        try await waitUntil("the error") { !p.session.loading }
        XCTAssertEqual(p.sections.first?.rows, [.outcome(.init(id: "", error: "Mac not reachable"))])
        XCTAssertEqual(labels(p.tableView(p.table, cellForRowAt: IndexPath(row: 0, section: 0))).first?.textColor, .systemRed)
        XCTAssertEqual(p.sections.dropFirst().map(\.title), ["Calculator", "System", "Fans", "Acme Notes"], "the list kept")
        withExtendedLifetime((kb, view)) {}
    }

    // MARK: - The deadline

    /// The keyboard's run with no reply by its deadline: "The Mac didn't answer." in red, the spinner
    /// gone, the rows on; the reply coming later is dropped. The app's screen waits on.
    func testARunWithNoReplyTimesOut() async throws {
        mac.hold = true
        let p = panel()
        p.session.deadline = .milliseconds(100)
        p.tap(command("toggles.screensaver"), in: "System")
        try await waitUntil("the deadline") { p.session.outcome != nil }
        XCTAssertEqual(rows(p, "System").last, .outcome(.init(id: "toggles.screensaver", error: "The Mac didn't answer.")))
        XCTAssertEqual(labels(cell(p, "System", 2)).first?.textColor, .systemRed)
        XCTAssertNil(p.session.running)
        XCTAssertNil(cell(p, "System", 1).accessoryView, "no spinner")
        XCTAssertNotNil(p.tableView(p.table, willSelectRowAt: IndexPath(row: 0, section: 0)), "the rows on")
        mac.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(p.session.outcome?.error, "The Mac didn't answer.", "the late reply dropped")
        XCTAssertEqual(store.recent, [])

        let app = CommandsSession(transport: mac)
        app.deadline = .milliseconds(50)
        app.run(command("toggles.screensaver"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(app.running, "toggles.screensaver", "the app's waits")
        mac.release()
        try await waitUntil("the app's reply") { app.running == nil }
        XCTAssertEqual(app.outcome?.result?.text, "42")
    }

    // MARK: - Render

    /// Render check, run by hand: `TEST_RUNNER_CMD_SNAPSHOT_DIR=<dir>` saves the panel, portrait, as
    /// the extension rigs the keyboard, with Recent, Run's row and a reply.
    func testSnapshot() async throws {
        guard let out = ProcessInfo.processInfo.environment["CMD_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_CMD_SNAPSHOT_DIR to render")
        }
        store.ran("toggles.lock")
        store.ran("calc.eval")
        cache()
        let (kb, bar, doc, view) = rig("x = ", store: store)
        kb.bottomInset = TerminalKeyboard.extensionBottomInset
        doc.selectedText = "6*7"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.isHidden = false
        defer { window.isHidden = true }
        let height = try XCTUnwrap(kb.constraints.first { $0.firstItem === kb && $0.firstAttribute == .height }).constant
        window.frame = CGRect(x: 0, y: 200, width: 402, height: SuggestionBar.height + height)
        view.frame = window.bounds
        window.addSubview(view)
        bar.showCommands(true)
        let p = try XCTUnwrap(bar.commandsPanel)
        func save(_ name: String) async throws {
            for _ in 0..<3 { window.layoutIfNeeded() }
            try await Task.sleep(nanoseconds: 300_000_000)
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            let png = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("735-\(name).png"))
        }
        try await save("list")
        p.tap(command("calc.eval"), in: "Recent")
        try await waitUntil("the reply") { p.session.outcome != nil }
        try await save("reply")
        p.tap(command("toggles.lock"), in: "Recent")
        try await save("confirm")
        doc.selectedText = nil
        p.tap(command("calc.eval"), in: "Calculator")
        for c in "1+1" { try XCTUnwrap(p.filter).type(String(c)) }
        try await save("field")
        bar.reach = { _ in { throw TransportError.server("Mac not reachable") } }
        bar.showCommands(true)
        let q = try XCTUnwrap(bar.commandsPanel)
        q.tap(command("toggles.screensaver"), in: "System")
        try await waitUntil("the error") { q.session.outcome != nil }
        let system = try XCTUnwrap(q.sections.firstIndex { $0.title == "System" })
        q.table.scrollToRow(at: IndexPath(row: q.sections[system].rows.count - 1, section: system), at: .bottom, animated: false)
        try await save("error")
        store.connected(Machine(name: "Mini", addresses: ["mini.example.test"]))
        let before = mac.lists
        mac.holdList = true
        bar.reach = { [unowned self] _ in reaching(mac) }
        bar.showCommands(true)
        try await waitUntil("the fetch sent") { mac.lists > before }
        try await save("fetching")
        withExtendedLifetime(kb) {}
    }
}
