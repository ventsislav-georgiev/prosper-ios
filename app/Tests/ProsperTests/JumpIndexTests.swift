import XCTest
import UIKit
@testable import Prosper

/// The A–Z jump index on the quicklinks' and the snippets' panels (#639): titles from the
/// alphabetical rows, a tap landing on the letter's first row, none on a list that fits.
/// Throwaway stores with made-up names.
@MainActor
final class JumpIndexTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("JumpIndexTests-\(UUID())")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private static let names = ["alpha", "Apex", "bravo", "Charlie", "delta", "echo", "Foxtrot", "golf", "hotel",
                                "india", "Juliet", "kilo", "lima", "mike", "1st", "ябълка", "Ърбан", "_tmp"]

    private func laidOut(_ panel: KeysPanel, height: CGFloat = 300) -> KeysPanel {
        panel.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        for _ in 0..<3 { panel.layoutIfNeeded() }
        return panel
    }

    private func quicklinks(_ names: [String]) -> QuicklinkStore {
        let store = QuicklinkStore(url: dir.appendingPathComponent("Quicklinks/quicklinks.json"))
        for n in names { store.put(.init(name: n, url: "https://example.com/\(n.count)"), replacing: nil) }
        return store
    }

    private func snippets(_ names: [String], in collection: String? = nil) -> SnippetStore {
        let store = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        for n in names { store.put(.init(name: n, text: "text of \(n)", collection: collection), replacing: nil) }
        return store
    }

    func testTitlesFollowTheNamesInDisplayOrder() {
        let jumps = KeysPanel.jumps([["Bravo", "alpha"], nil, ["1st", "ябълка", "Ърбан", "_tmp", "Bob", "  apex"]])
        XCTAssertEqual(jumps.map(\.title), ["B", "A", "#", "Я", "Ъ"], "Cyrillic as-is, non-letters as #")
        XCTAssertEqual(jumps.map(\.row), [[0, 0], [0, 1], [2, 0], [2, 1], [2, 2]], "each letter's first row")
    }

    func testQuicklinkRecentsAddNoTitles() {
        let store = quicklinks(Self.names)
        store.used("mike")   // in Recent only: its M comes from nowhere else
        let panel = laidOut(QuicklinkPanel(store: store, hasQuery: true)) as! QuicklinkPanel
        XCTAssertEqual(panel.sections.map(\.title), ["Recent", "All"])
        let titles = panel.sectionIndexTitles(for: panel.table)
        XCTAssertEqual(titles?.first, "#", "the All section's, sorted: 1st and _tmp first")
        XCTAssertFalse(titles?.contains("M") ?? true, "the recent adds nothing")
        XCTAssertEqual(titles?.suffix(2), ["Ъ", "Я"])
        // # is All's first row: it shows under All's pinned header, not behind it.
        _ = panel.tableView(panel.table, sectionForSectionIndexTitle: "#", at: 0)
        let table = panel.table
        let row = table.rectForRow(at: IndexPath(row: 0, section: 1)), header = table.rectForHeader(inSection: 1)
        XCTAssertGreaterThan(header.height, 0)
        XCTAssertEqual(row.minY, table.contentOffset.y + header.height, accuracy: 1, "lands on the row, under its header")
    }

    func testALetterLandsOnItsFirstRowNotTheHeader() throws {
        let panel = laidOut(QuicklinkPanel(store: quicklinks(Self.names), hasQuery: true)) as! QuicklinkPanel
        let table = panel.table
        XCTAssertTrue(table.scrolls)
        let titles = try XCTUnwrap(panel.sectionIndexTitles(for: table))
        let h = try XCTUnwrap(titles.firstIndex(of: "H"))
        XCTAssertEqual(panel.tableView(table, sectionForSectionIndexTitle: "H", at: h), -1, "UIKit scrolls no further")
        table.layoutIfNeeded()
        let row = try XCTUnwrap(panel.sections[0].links.firstIndex { $0.name == "hotel" })
        XCTAssertEqual(table.contentOffset.y, table.rectForRow(at: IndexPath(row: row, section: 0)).minY, accuracy: 1,
                       "H lands on hotel's row")
        XCTAssertEqual(table.indexPathsForVisibleRows?.first, IndexPath(row: row, section: 0))
    }

    func testSnippetGroupsInTheirOrder() throws {
        let store = snippets(["kilo", "Bravo", "lima", "mike"], in: "Zeta")
        for n in ["alpha", "bravo", "Charlie", "delta", "echo", "Foxtrot", "golf", "hotel", "india", "Juliet"] {
            store.put(.init(name: n, text: "text of \(n)"), replacing: nil)
        }
        let panel = laidOut(SnippetPanel(store: store)) as! SnippetPanel
        let titles = try XCTUnwrap(panel.sectionIndexTitles(for: panel.table))
        XCTAssertEqual(titles, ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M"])
        let b = try XCTUnwrap(titles.firstIndex(of: "B"))
        _ = panel.tableView(panel.table, sectionForSectionIndexTitle: "B", at: b)
        let first = try XCTUnwrap(panel.groups.firstIndex { $0.snippets.contains { $0.name == "bravo" } })
        let row = try XCTUnwrap(panel.groups[first].snippets.firstIndex { $0.name == "bravo" })
        XCTAssertEqual(panel.table.contentOffset.y, panel.table.rectForRow(at: IndexPath(row: row, section: first)).minY,
                       accuracy: 1, "B lands on the first group's bravo, not Zeta's Bravo")
    }

    func testNoIndexOnAListThatFits() {
        let q = laidOut(QuicklinkPanel(store: quicklinks(["alpha", "bravo", "charlie"]), hasQuery: true)) as! QuicklinkPanel
        XCTAssertFalse(q.table.scrolls)
        XCTAssertNil(q.sectionIndexTitles(for: q.table))
        let s = laidOut(SnippetPanel(store: snippets(["alpha", "bravo"]))) as! SnippetPanel
        XCTAssertNil(s.sectionIndexTitles(for: s.table))
    }
}
