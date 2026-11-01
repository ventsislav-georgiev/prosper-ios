import XCTest
import UIKit
@testable import Prosper

/// The list panels' filter mode (#665, `PanelFilter`): its ranking, its keys typing into the
/// query and never into the host, a pick through the list's own tap, the layout at each Key
/// Size, and the list back as it was.
@MainActor
final class PanelFilterTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy

    private var suite = ""
    private var dir: URL!
    private var pb: UIPasteboard!

    override func setUpWithError() throws {
        suite = "PanelFilterTests.\(UUID().uuidString)"
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
        UIPasteboard.remove(withName: pb.name)
        super.tearDown()
    }

    // MARK: - Ranking

    func testRanksPrefixThenWordStartThenSubstringThenSubsequence() {
        let rows = [["Zebra cat"], ["category"], ["Concat"], ["c-a-t"], ["dog"], ["Cat"], ["bobcat"], ["Çatal"]]
        XCTAssertEqual(PanelFilter.rank("cat", rows), [1, 5, 7, 0, 2, 6, 3], "ties keep the list's order")
        XCTAssertEqual(PanelFilter.rank("CAT", rows), PanelFilter.rank("cat", rows), "case-insensitive")
        XCTAssertEqual(PanelFilter.rank("çàt", rows), PanelFilter.rank("cat", rows), "diacritic-insensitive")
        XCTAssertEqual(PanelFilter.rank("", rows), Array(rows.indices), "a blank query keeps every row")
        XCTAssertEqual(PanelFilter.rank("  ", rows), Array(rows.indices))
        XCTAssertEqual(PanelFilter.rank("xyz", rows), [])
        XCTAssertEqual(PanelFilter.rank("git", [["https://example.com/legit"], ["https://github.com"], ["g-i-t"]]), [1, 0, 2],
                       "after a / is a word's start")
        XCTAssertEqual(PanelFilter.rank("пис", [["отпис"], ["Писмо"], ["п и с"]]), [1, 0, 2])
    }

    /// A row ranks by its best field, the earlier field on a tie: a snippet's name over its text.
    func testARowRanksByItsBestFieldNameFirst() {
        let rows = [["Deploy", "kubectl apply"], ["notes", "apply now"], ["Apply patch", "git am"], ["Reapply", "x"]]
        XCTAssertEqual(PanelFilter.rank("apply", rows), [2, 1, 0, 3])
    }

    // MARK: - The keys never reach the host

    func testSnippetFilterTypesIntoTheQueryAndReturnInsertsTheFirst() throws {
        let store = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        XCTAssertTrue(store.save(.init(snippets: [.init(name: "Address", text: "1 Main St"),
                                                  .init(name: "Greeting", text: "Hi there"),
                                                  .init(name: "Sign-off", text: "Regards")])))
        let (kb, bar, doc, view) = rig("x ")
        bar.snippets = store
        bar.showSnippets(true)
        let panel = try XCTUnwrap(bar.snippetsPanel)
        let filter = try open(panel)
        XCTAssertEqual(filter.matches.count, 3, "every row before a key")

        doc.calls = []
        try type("re", filter)
        XCTAssertEqual(doc.calls, [], "no key reaches the host")
        XCTAssertEqual(doc.text, "x ")
        XCTAssertEqual(filter.query, "re")
        XCTAssertEqual(names(filter, panel), ["Sign-off", "Address", "Greeting"], "its text's prefix, then the names' substrings")
        XCTAssertEqual(filter.count, "3 results")
        filter.delete.sendActions(for: .touchDown)
        filter.delete.sendActions(for: .touchUpInside)
        filter.space.sendActions(for: .touchUpInside)
        filter.toggle.sendActions(for: .touchUpInside)
        XCTAssertEqual(filter.rows.first?.map { $0.configuration?.title }, "1234567890".map { String($0) })
        filter.rows[0][1].sendActions(for: .touchUpInside)
        XCTAssertEqual(filter.query, "r 2")
        XCTAssertEqual(filter.count, "No matches")
        XCTAssertFalse(filter.none.isHidden)
        filter.clear.sendActions(for: .touchUpInside)
        XCTAssertEqual(filter.query, "")
        XCTAssertEqual(doc.calls, [], "nor 123, space, delete or clear")

        filter.toggle.sendActions(for: .touchUpInside)
        try type("gr", filter)
        filter.go.sendActions(for: .touchUpInside)
        for _ in 1...50 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text, "x Hi there", "return inserts the first result")
        XCTAssertNil(bar.snippetsPanel, "a pick closes the panel")
        withExtendedLifetime((kb, view)) {}
    }

    func testClipboardFilterPastesAPickedResult() throws {
        let history = ClipboardHistory(dir: dir.appendingPathComponent("Clips"))
        for s in ["older note", "make test", "newest"] { pb.string = s; history.record(s, from: pb) }
        let (kb, bar, doc, view) = rig("")
        bar.history = history
        bar.showClips(true)
        let panel = try XCTUnwrap(bar.clipsPanel)
        let filter = try open(panel)
        doc.calls = []
        try type("te", filter)
        XCTAssertEqual(doc.calls, [])
        XCTAssertEqual(filter.matches.map { panel.clips[$0].text }, ["make test", "older note"])
        let cell = filter.tableView(filter.results, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(cell.accessibilityLabel, "make test")
        XCTAssertNil(cell.accessoryView, "no pin or delete in a short row")
        filter.tableView(filter.results, didSelectRowAt: IndexPath(row: 1, section: 0))
        for _ in 1...50 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text, "older note", "a tap on a result is the list's tap")
        XCTAssertEqual(pb.string, "older note")
        withExtendedLifetime((kb, view)) {}
    }

    /// Return skips a dimmed result (a `{query}` link with nothing to fill it) for the first that goes.
    func testQuicklinkFilterReturnOpensTheFirstThatGoes() throws {
        let store = QuicklinkStore(url: dir.appendingPathComponent("Quicklinks/quicklinks.json"))
        XCTAssertTrue(store.save(.init(quicklinks: [.init(name: "Search docs", url: "https://docs.example.com/?q={query}"),
                                                    .init(name: "Dashboard", url: "https://dash.example.com")])))
        let (kb, bar, doc, view) = rig("")
        bar.quicklinks = store
        bar.showQuicklinks(true)
        let panel = try XCTUnwrap(bar.quicklinksPanel)
        let filter = try open(panel)
        doc.calls = []
        try type("d", filter)
        XCTAssertEqual(doc.calls, [])
        XCTAssertEqual(filter.matches.map { panel.searchable[$0].fields[0] }, ["Dashboard", "Search docs"])
        try type("o", filter)
        XCTAssertEqual(filter.matches.map { panel.searchable[$0].fields[0] }, ["Search docs", "Dashboard"])
        XCTAssertNil(filter.tableView(filter.results, willSelectRowAt: IndexPath(row: 0, section: 0)), "dimmed as in the list")
        filter.go.sendActions(for: .touchUpInside)
        for _ in 1...50 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text, "https://dash.example.com")
        withExtendedLifetime((kb, view)) {}
    }

    // MARK: - Layout and leaving

    /// Over the bar and the keys at each Key Size in portrait, under a one-row toolbar (the
    /// digit row) or a two-row one (Numbers: Key): the field, two whole rows and four rows of
    /// keys, no scroll, the keys what's left up to their cap. Done gives the bar back.
    func testFitsOverTheBarAtEveryKeySize() throws {
        let store = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        XCTAssertTrue(store.save(.init(snippets: [.init(name: "Address", text: "1 Main St")])))
        for size in KeyboardSettings.KeySize.allCases {
            for numbers in KeyboardSettings.Numbers.allCases {
                let label = "\(size) \(numbers)"
                let (kb, bar, view) = hostedRig(size: size, numbers: numbers)
                XCTAssertEqual(bar.toolbar?.twoRows, numbers == .key, label)
                bar.snippets = store
                bar.showSnippets(true)
                let panel = try XCTUnwrap(bar.snippetsPanel)
                view.layoutIfNeeded()
                XCTAssertEqual(panel.frame.minY, kb.frame.minY, label)
                let filter = try open(panel)
                filter.layoutIfNeeded()
                XCTAssertEqual(panel.frame.minY, bar.frame.minY, "over the bar, \(label)")
                XCTAssertEqual(panel.frame.maxY, kb.frame.maxY, label)
                XCTAssertEqual(filter.shown, 2, label)
                XCTAssertLessThanOrEqual(filter.contentSize.height, filter.bounds.height + 0.5, "no scroll, \(label)")
                XCTAssertGreaterThanOrEqual(filter.results.frame.height, 2 * PanelFilter.rowHeight, label)
                XCTAssertLessThanOrEqual(filter.go.frame.maxY, filter.bounds.height, label)
                XCTAssertTrue(PanelFilter.keyRow.contains(filter.go.frame.height), label)
                XCTAssertGreaterThan(filter.rows[0][0].frame.minY, filter.results.frame.maxY, label)
                XCTAssertEqual(filter.space.frame.minY, filter.go.frame.minY)
                print("#665 \(label): over \(filter.bounds.height), key row \(filter.go.frame.height), results \(filter.results.frame.height)")
                filter.done.sendActions(for: .touchUpInside)
                XCTAssertEqual(panel.frame.minY, kb.frame.minY, "Done gives the bar back, \(label)")
                withExtendedLifetime(kb) {}
            }
        }
    }

    /// The results card in whole rows (#674): one-line clips and two-line snippets and links
    /// at 2 and 3+ matches, over the system keyboard and in a taller panel, no row cut at the
    /// card's foot and a subtitle above its separator; the emoji grid keeps its two 38 pt rows.
    func testResultsShowOnlyWholeRows() throws {
        let snippets = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        let links = QuicklinkStore(url: dir.appendingPathComponent("Quicklinks/quicklinks.json"))
        for count in [2, 4] {
            let history = ClipboardHistory(dir: dir.appendingPathComponent("Clips\(count)"))
            XCTAssertTrue(snippets.save(.init(snippets: (1...count).map { .init(name: "Snippet \($0)", text: "text \($0)") })))
            XCTAssertTrue(links.save(.init(quicklinks: (1...count).map { .init(name: "Link \($0)", url: "https://example.com/\($0)") })))
            for i in 1...count { pb.string = "clip \(i)"; history.record("clip \(i)", from: pb) }
            for size in KeyboardSettings.KeySize.allCases {
            let (kb, bar, view) = hostedRig(size: size, numbers: .key)
            bar.snippets = snippets
            bar.quicklinks = links
            bar.history = history
            for kind in ["snippets", "links", "clips"] {
                switch kind {
                case "snippets": bar.showSnippets(true)
                case "links": bar.showQuicklinks(true)
                default: bar.showClips(true)
                }
                view.layoutIfNeeded()
                let panel = try XCTUnwrap(bar.snippetsPanel ?? bar.quicklinksPanel ?? bar.clipsPanel, kind)
                let filter = try open(panel)
                assertWholeRows(filter, "\(kind) \(count), \(size)", twoLine: kind != "clips")
                filter.done.sendActions(for: .touchUpInside)
                bar.showSnippets(false); bar.showQuicklinks(false); bar.showClips(false)
            }
            withExtendedLifetime(kb) {}
            }

            let tall = SnippetPanel(store: snippets)
            tall.frame = CGRect(x: 0, y: 0, width: 390, height: 420)
            tall.layoutIfNeeded()
            assertWholeRows(try open(tall), "snippets \(count), tall", twoLine: true)
        }

        let grid = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        let emoji = PanelFilter(placeholder: "Search", layout: .english, fields: [["a"], ["b"], ["c"]], grid: grid)
        emoji.frame = CGRect(x: 0, y: 0, width: 402, height: 300)
        emoji.layoutIfNeeded()
        XCTAssertEqual(grid.frame, CGRect(x: 8, y: 42, width: 386, height: 2 * PanelFilter.rowHeight), "the grid's two rows, as before")
        XCTAssertEqual(grid.frame, emoji.results.frame)
    }

    /// The emoji search's grid in whole rows, columns no wider than 38 pt (#686), at each Key Size, on
    /// English and Bulgarian, under either toolbar, in portrait and landscape: no band between rows (38 pt cells in
    /// 108 pt spread two over three's room), the last inside, a smaller cell's glyph inside it.
    func testEmojiResultsFillTheGridInWholeRows() throws {
        for size in KeyboardSettings.KeySize.allCases {
            for (layout, numbers) in [(TerminalKeyboard.Layout.english, KeyboardSettings.Numbers.key), (.bulgarian, .row), (.english, .row)] {
                for landscape in [false, true] {
                    let label = "\(size) \(layout) \(numbers) \(landscape ? "landscape" : "portrait")"
                    let (kb, _, view) = hostedRig(size: size, numbers: numbers, layout: layout, landscape: landscape)
                    kb.showEmoji(true)
                    let picker = try XCTUnwrap(kb.emojiPicker, label)
                    picker.search(true)
                    let filter = try XCTUnwrap(picker.filter, label)
                    view.layoutIfNeeded()
                    filter.type(layout == .english ? "a" : "а")
                    filter.layoutIfNeeded()
                    let grid = try XCTUnwrap(filter.grid, label)
                    grid.layoutIfNeeded()
                    let height = grid.bounds.height
                    let rows = Int((height / PanelFilter.cellSide).rounded(.down))
                    let cells = grid.visibleCells.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
                    let column = cells.filter { abs($0.frame.minX - cells[0].frame.minX) < 0.5 }
                    XCTAssertGreaterThan(filter.matches.count, 3 * rows, label)
                    XCTAssertEqual(column.count, rows, "\(label): whole rows in \(height) pt")
                    for (a, b) in zip(column, column.dropFirst()) {
                        XCTAssertLessThan(abs(b.frame.minY - a.frame.maxY), 1, "\(label): no gap between rows")
                    }
                    XCTAssertLessThan(column.first?.frame.minY ?? .infinity, 1, label)
                    XCTAssertLessThanOrEqual(column.last?.frame.maxY ?? .infinity, height + 0.5, "\(label): the last row inside")
                    XCTAssertGreaterThan(column.last?.frame.maxY ?? 0, height - 1, "\(label): the rows fill the grid")
                    let columns = Set(cells.map { ($0.frame.minX * 2).rounded() }).count
                    XCTAssertGreaterThanOrEqual(columns, Int(grid.bounds.width / PanelFilter.rowHeight), "\(label): no fewer columns than 38 pt ones")
                    for cell in column {
                        XCTAssertEqual(cell.frame.width, min(cell.frame.height, PanelFilter.rowHeight), accuracy: 0.01, "\(label): no wider than 38")
                        // A cell under 38 pt still holds its glyph's advance (the image's height is the line's).
                        let glyph = try XCTUnwrap((cell.contentView.subviews.first as? UIImageView)?.image?.size, label)
                        if cell.frame.width < PanelFilter.rowHeight { XCTAssertLessThanOrEqual(glyph.width, cell.frame.width, "\(label): the glyph inside") }
                    }
                    withExtendedLifetime(kb) {}
                }
            }
        }
    }

    /// A drag comes to rest on a row's top, the nearer one, never past the end (#674).
    func testAScrollRestsOnARowsTop() throws {
        let store = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        XCTAssertTrue(store.save(.init(snippets: (1...8).map { .init(name: "Snippet \($0)", text: "text \($0)") })))
        let panel = SnippetPanel(store: store)
        panel.frame = CGRect(x: 0, y: 0, width: 390, height: 308)
        let filter = try open(panel)
        filter.layoutIfNeeded()
        let table = filter.results
        table.layoutIfNeeded()
        let row = table.rowHeight, end = 8 * row - table.bounds.height   // the last row's top-aligned rest (#678)
        XCTAssertGreaterThan(end, 2 * row, "enough rows to scroll")
        func rest(_ y: CGFloat, _ view: UIScrollView? = nil) -> CGFloat {
            var p = CGPoint(x: 0, y: y)
            filter.scrollViewWillEndDragging(view ?? table, withVelocity: .zero, targetContentOffset: &p)
            return p.y
        }
        XCTAssertEqual(rest(1.4 * row), row, accuracy: 0.01)
        XCTAssertEqual(rest(1.6 * row), 2 * row, accuracy: 0.01)
        XCTAssertEqual(rest(end + 3 * row), end, accuracy: 0.01, "clamped to the end")
        let last = filter.tableView(table, cellForRowAt: IndexPath(row: 7, section: 0))
        XCTAssertGreaterThanOrEqual(last.separatorInset.left + last.separatorInset.right, table.bounds.width, "no hairline under the last row")
        XCTAssertLessThan(filter.tableView(table, cellForRowAt: IndexPath(row: 6, section: 0)).separatorInset.right,
                          table.bounds.width, "the other rows keep theirs")
        XCTAssertEqual(rest(1.4 * row, filter), 1.4 * row, accuracy: 0.01, "another scroll view's target is its own")
    }

    /// No hairline on the card's top or bottom edge (#681): none under a lone match, in the
    /// Snippets and Quicklinks panels, and at every rest of six matches only the hairlines
    /// between the visible rows.
    func testNoHairlineOnTheCardsEdges() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        for count in [1, 6] {
            let snippets = SnippetStore(url: dir.appendingPathComponent("Snippets\(count)/snippets.json"))
            XCTAssertTrue(snippets.save(.init(snippets: (1...count).map { .init(name: "Snippet \($0)", text: "text \($0)") })))
            let links = QuicklinkStore(url: dir.appendingPathComponent("Quicklinks\(count)/quicklinks.json"))
            XCTAssertTrue(links.save(.init(quicklinks: (1...count).map { .init(name: "Link \($0)", url: "https://example.com/\($0)") })))
            for panel in [SnippetPanel(store: snippets), QuicklinkPanel(store: links, hasQuery: false)] as [KeysPanel] {
                panel.frame = CGRect(x: 0, y: 0, width: 390, height: 308)
                window.addSubview(panel)
                let filter = try open(panel)
                filter.layoutIfNeeded()
                let table = filter.results
                table.layoutIfNeeded()
                let label = "\(Swift.type(of: panel)) \(count)"
                XCTAssertEqual(filter.matches.count, count, label)
                let fit = Int((table.bounds.height / table.rowHeight).rounded())
                XCTAssertGreaterThan(fit, 1, label)
                XCTAssertEqual(table.mask?.layer.cornerRadius, table.layer.cornerRadius, "\(label): the clip keeps the card's corners")
                var rests = [CGFloat(0)]
                if count > fit { rests += (1...(count - fit)).map { CGFloat($0) * table.rowHeight } }
                for y in rests {
                    table.contentOffset.y = y
                    table.layoutIfNeeded()
                    let seen = hairlines(table)
                    let edge: CGFloat = 0.5
                    for h in seen {
                        XCTAssertGreaterThan(h.minY, table.bounds.minY + edge, "\(label) at \(y): a hairline on the top edge")
                        XCTAssertLessThan(h.maxY, table.bounds.maxY - edge, "\(label) at \(y): a hairline on the bottom edge")
                    }
                    let rows = min(count, fit)
                    XCTAssertEqual(seen.count, rows - 1, "\(label) at \(y): a hairline between each two visible rows, no more")
                }
                filter.done.sendActions(for: .touchUpInside)
                panel.removeFromSuperview()
            }
        }
    }

    /// The app's terminal: filter mode covers its shortcut bar too, so no bar key reaches the
    /// terminal mid-filter; Done gives the bar back.
    func testTheAppsFilterCoversItsShortcutBar() throws {
        let store = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        XCTAssertTrue(store.save(.init(snippets: [.init(name: "Address", text: "1 Main St")])))
        let vc = TerminalHostVC(conn: SessionConnection(transport: SpyTransport(), session: DchSession(name: "t", alias: nil)),
                                handle: TermHandle())
        vc.pasteboard = pb
        vc.snippets = store
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        vc.view.layoutIfNeeded()
        let bar = try XCTUnwrap(vc.view.subviews.first { $0 is ShortcutBar })
        vc.showSnippets(true)
        let panel = try XCTUnwrap(vc.snippetsPanel)
        vc.view.layoutIfNeeded()
        XCTAssertEqual(panel.frame.maxY, bar.frame.minY, accuracy: 0.5, "the list stops at the bar")
        let filter = try open(panel)
        let mid = CGPoint(x: bar.frame.midX, y: bar.frame.midY)
        XCTAssertEqual(panel.frame.maxY, bar.frame.maxY, accuracy: 0.5, "over the bar")
        XCTAssertEqual(vc.view.hitTest(mid, with: nil)?.isDescendant(of: filter), true, "the bar takes no tap")
        filter.done.sendActions(for: .touchUpInside)
        XCTAssertEqual(panel.frame.maxY, bar.frame.minY, accuracy: 0.5, "Done gives the bar back")
        XCTAssertNotEqual(vc.view.hitTest(mid, with: nil)?.isDescendant(of: panel), true)
    }

    /// The search row shows only over rows it can match: an empty list, or one of images,
    /// has none; a clip captured while the panel is open brings it.
    func testSearchRowOnlyOverRowsItCanMatch() throws {
        let history = ClipboardHistory(dir: dir.appendingPathComponent("Clips"))
        let clips = ClipboardPanel(history: history, pasteboard: pb)
        XCTAssertEqual(clips.search?.isHidden, true)
        clips.paste(itemProviders: [NSItemProvider(object: "fresh" as NSString)])
        let deadline = Date() + 5
        while clips.clips.isEmpty, Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
        XCTAssertEqual(clips.search?.isHidden, false, "shown at the capture's reload")
        let store = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        XCTAssertEqual(SnippetPanel(store: store).search?.isHidden, true)
        XCTAssertTrue(store.save(.init(snippets: [.init(name: "Address", text: "1 Main St")])))
        XCTAssertEqual(SnippetPanel(store: store).search?.isHidden, false)
        let links = QuicklinkStore(url: dir.appendingPathComponent("Quicklinks/quicklinks.json"))
        XCTAssertEqual(QuicklinkPanel(store: links, hasQuery: true).search?.isHidden, true)
    }

    /// Delete takes one on touch-down, then repeats while held at the keys' pace, and stops
    /// at the lift; a letter shows the keys' press bubble while down.
    func testDeleteRepeatsWhileHeldAndALetterShowsItsBubble() throws {
        let panel = SnippetPanel(store: SnippetStore(url: dir.appendingPathComponent("none.json")))
        panel.frame = CGRect(x: 0, y: 0, width: 390, height: 308)
        let filter = try open(panel)
        filter.layoutIfNeeded()
        try type("abcdefghij", filter)
        filter.delete.sendActions(for: .touchDown)
        XCTAssertEqual(filter.query, "abcdefghi", "one at touch-down")
        RunLoop.main.run(until: Date() + 0.3)
        XCTAssertEqual(filter.query, "abcdefghi", "nothing more before 0.4 s")
        RunLoop.main.run(until: Date() + 0.4)
        let held = filter.query.count
        XCTAssertLessThan(held, 9, "repeating")
        filter.delete.sendActions(for: .touchUpInside)
        RunLoop.main.run(until: Date() + 0.3)
        XCTAssertEqual(filter.query.count, held, "stopped at the lift")

        let q = try XCTUnwrap(filter.rows[0].first)
        q.sendActions(for: .touchDown)
        XCTAssertTrue(filter.preview.superview === filter)
        XCTAssertEqual(filter.preview.label.text, q.configuration?.title)
        XCTAssertLessThan(filter.preview.frame.minY, q.frame.minY, "above the key")
        q.sendActions(for: .touchUpInside)
        XCTAssertNil(filter.preview.superview)
    }

    /// The covered keyboard's layout; Done gives the list back, scrolled where it was.
    func testBulgarianKeysAndDoneRestoresTheList() throws {
        let store = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        XCTAssertTrue(store.save(.init(snippets: (1...30).map { .init(name: "Snippet \($0)", text: "t\($0)") })))
        let (kb, bar, _, view) = rig("", layout: .bulgarian)
        bar.snippets = store
        bar.showSnippets(true)
        XCTAssertEqual(bar.snippetsPanel?.layout, .bulgarian, "the covered keys' layout")
        withExtendedLifetime((kb, view)) {}

        let panel = SnippetPanel(store: store)
        panel.frame = CGRect(x: 0, y: 0, width: 390, height: 264)
        panel.layout = .bulgarian
        panel.layoutIfNeeded()
        panel.table.contentOffset.y = 120
        let filter = try open(panel)
        XCTAssertEqual(filter.rows.map { $0.compactMap { $0.configuration?.title }.joined() },
                       ["явертъуиопю", "асдфгхйклшщ", "зьцжбнмч"])
        filter.done.sendActions(for: .touchUpInside)
        XCTAssertNil(panel.filter)
        XCTAssertNil(filter.superview)
        XCTAssertEqual(panel.table.contentOffset.y, 120)
        XCTAssertNil(AppearancePanel(settings: KeyboardSettings(), enabled: true).search, "a panel with no list has no search row")
    }

    /// On Bulgarian the language key before space switches the letters to English's and back
    /// (#680), from the 123 keys too; what it types filters. English has none.
    func testBulgarianLanguageKeySwitchesToEnglishLettersAndBack() throws {
        let store = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        XCTAssertTrue(store.save(.init(snippets: [.init(name: "Адрес", text: "ул. Шипка 1"), .init(name: "Deploy", text: "make ship")])))
        let english = SnippetPanel(store: store)
        english.frame = CGRect(x: 0, y: 0, width: 390, height: 264)
        XCTAssertTrue(try open(english).language.isHidden, "none on English")

        let panel = SnippetPanel(store: store)
        panel.frame = english.frame
        panel.layout = .bulgarian
        let filter = try open(panel)
        filter.layoutIfNeeded()
        func letters() -> [String] { filter.rows.map { $0.compactMap { $0.configuration?.title }.joined() } }
        let cyrillic = ["явертъуиопю", "асдфгхйклшщ", "зьцжбнмч"]
        XCTAssertEqual(letters(), cyrillic)
        XCTAssertFalse(filter.language.isHidden)
        XCTAssertEqual(filter.language.configuration?.title, "EN")
        XCTAssertEqual(filter.language.accessibilityLabel, "Switch to English")
        XCTAssertLessThan(filter.language.frame.maxX, filter.space.frame.minX, "before space")
        XCTAssertEqual(filter.language.frame.minY, filter.space.frame.minY)

        filter.language.sendActions(for: .touchUpInside)
        XCTAssertEqual(letters(), ["qwertyuiop", "asdfghjkl", "zxcvbnm"])
        XCTAssertEqual(filter.language.configuration?.title, "БГ")
        try type("ship", filter)
        XCTAssertEqual(filter.query, "ship")
        XCTAssertEqual(names(filter, panel), ["Deploy"], "English typed on Bulgarian filters")

        filter.toggle.sendActions(for: .touchUpInside)
        XCTAssertTrue(filter.digits)
        filter.language.sendActions(for: .touchUpInside)
        XCTAssertFalse(filter.digits, "from the 123 keys, the letters")
        XCTAssertEqual(letters(), cyrillic, "and back")
        XCTAssertEqual(filter.language.configuration?.title, "EN")
        filter.clear.sendActions(for: .touchUpInside)
        try type("шип", filter)
        XCTAssertEqual(names(filter, panel), ["Адрес"])

        filter.done.sendActions(for: .touchUpInside)
        XCTAssertEqual(try open(panel).letters, .bulgarian, "fresh on the next open")
    }

    // MARK: - Helpers

    /// Every row the card shows is whole, none under 38 pt, a subtitle inside its cell (#674).
    private func assertWholeRows(_ filter: PanelFilter, _ label: String, twoLine: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) {
        filter.layoutIfNeeded()
        let table = filter.results
        table.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(table.rowHeight, PanelFilter.rowHeight, label, file: file, line: line)
        let visible = table.indexPathsForVisibleRows ?? []
        let fit = Int((table.bounds.height / PanelFilter.rowHeight).rounded(.down))
        XCTAssertEqual(visible.count, min(filter.matches.count, fit), label, file: file, line: line)
        for ip in visible {
            let row = table.rectForRow(at: ip)
            XCTAssertGreaterThanOrEqual(row.minY, table.bounds.minY - 0.5, "\(label) row \(ip.row)", file: file, line: line)
            XCTAssertLessThanOrEqual(row.maxY, table.bounds.maxY + 0.5, "\(label) row \(ip.row) cut at the foot", file: file, line: line)
            guard twoLine, let cell = table.cellForRow(at: ip),
                  let sub = (cell.contentConfiguration as? UIListContentConfiguration)?.secondaryText else { continue }
            cell.layoutIfNeeded()
            let labels = sequence(first: [cell.contentView] as [UIView]) { level in
                let next = level.flatMap(\.subviews)
                return next.isEmpty ? nil : next
            }.joined().compactMap { $0 as? UILabel }
            guard let subtitle = labels.first(where: { $0.text == sub }) else {
                XCTFail("\(label): no subtitle", file: file, line: line); continue
            }
            let frame = subtitle.convert(subtitle.bounds, to: cell)
            XCTAssertLessThanOrEqual(frame.maxY, cell.bounds.height - 3, "\(label): the subtitle above the separator",
                                     file: file, line: line)
        }
    }

    /// The table's separators as drawn, in its bounds: each with a width, cut to what the
    /// table's mask lets through.
    private func hairlines(_ table: UITableView) -> [CGRect] {
        let shown = table.mask?.frame ?? table.bounds
        return table.visibleCells.flatMap { cell -> [CGRect] in
            cell.layoutIfNeeded()
            return cell.subviews.filter { NSStringFromClass(Swift.type(of: $0)).contains("Separator") && !$0.isHidden && $0.alpha > 0 }
                .map { $0.convert($0.bounds, to: table).intersection(shown).intersection(table.bounds) }
                .filter { !$0.isNull && $0.width > 0.01 && $0.height > 0.01 }
        }
    }

    /// A keyboard on a fake field, the bar hosted in `view` so a panel can cover the keys, Full Access on.
    private func rig(_ text: String, layout: TerminalKeyboard.Layout = .english,
                     in view: UIView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300)))
        -> (TerminalKeyboard, SuggestionBar, Proxy, UIView) {
        let doc = Proxy()
        doc.text = text
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard(layout: layout)
        kb.target = doc
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: UserDefaults(suiteName: suite)!)))
        let pb = self.pb!
        bar.suggestions.pasteboard = { pb }
        bar.attach(kb)
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults }
        return (kb, bar, doc, view)
    }

    /// The extension's keyboard and bar in a window at `size` and `numbers`, the view at the
    /// height they add up to, as NumbersKeyTests' rig.
    private func hostedRig(size: KeyboardSettings.KeySize, numbers: KeyboardSettings.Numbers,
                           layout: TerminalKeyboard.Layout = .english, landscape: Bool = false)
        -> (TerminalKeyboard, SuggestionBar, UIView) {
        let width: CGFloat = landscape ? 874 : 402
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: landscape ? 402 : 874))
        if #available(iOS 17, *) { window.traitOverrides.verticalSizeClass = landscape ? .compact : .regular }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        window.addSubview(view)
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        let (kb, bar, _, _) = rig("", layout: layout, in: view)
        kb.bottomInset = TerminalKeyboard.extensionBottomInset
        kb.allowsNumbersKey = true
        kb.settings.keySize = size
        kb.settings.numbers = numbers
        bar.showsToolbar = true
        view.frame.size.height = view.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                                              verticalFittingPriority: .fittingSizeLevel).height
        view.layoutIfNeeded()
        return (kb, bar, view)
    }

    /// The search row tapped: filter mode over the whole panel.
    private func open(_ panel: KeysPanel) throws -> PanelFilter {
        try XCTUnwrap(panel.search).sendActions(for: .touchUpInside)
        let filter = try XCTUnwrap(panel.filter)
        XCTAssertTrue(filter.superview === panel)
        XCTAssertEqual(filter.frame, panel.bounds)
        return filter
    }

    /// Each character's key tapped.
    private func type(_ text: String, _ filter: PanelFilter) throws {
        for c in text {
            let key = try XCTUnwrap(filter.rows.joined().first { $0.configuration?.title == String(c) }, "no \(c) key")
            key.sendActions(for: .touchUpInside)
        }
    }

    private func names(_ filter: PanelFilter, _ panel: SnippetPanel) -> [String] {
        filter.matches.map { panel.searchable[$0].fields[0] }
    }
}
