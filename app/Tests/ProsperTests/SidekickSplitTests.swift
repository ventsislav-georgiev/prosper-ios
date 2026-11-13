import XCTest
import UIKit
import SwiftUI
@testable import Prosper

/// The sessions list's Sessions / Sidekicks split, by the name or alias matching a pattern.
/// #761: ported with the Mac's AgentIslandTests, the matcher's bounds and fallbacks included.
final class SidekickSplitTests: XCTestCase {

    private func names(_ l: [DchSession]) -> [String] { l.map(\.name) }
    private func s(_ name: String, alias: String? = nil) -> DchSession { DchSession(name: name, alias: alias) }

    func testDefaultPattern() {
        let r = DchSession.split([s("build"), s("build-qa"), s("notes")], pattern: DchSession.sidekickDefault)
        XCTAssertEqual(names(r.primary), ["build", "notes"])
        XCTAssertEqual(names(r.sidekicks), ["build-qa"])
    }

    func testCaseInsensitive() {
        let r = DchSession.split([s("build-QA"), s("notes")], pattern: "-Qa")
        XCTAssertEqual(names(r.sidekicks), ["build-QA"])
        XCTAssertEqual(names(r.primary), ["notes"])
    }

    func testEmptyPatternMeansNoSplit() {
        let list = [s("build"), s("build-qa")]
        for p in ["", "   ", "\n\t"] {
            let r = DchSession.split(list, pattern: p)
            XCTAssertEqual(names(r.primary), ["build", "build-qa"])
            XCTAssertTrue(r.sidekicks.isEmpty)
        }
        XCTAssertEqual(names(DchSession.split(list, pattern: " -qa ").sidekicks), ["build-qa"], "the pattern is trimmed")
    }

    /// A renamed session counts by its alias; a matching name still counts under a plain alias.
    func testAliasOrNameMatches() {
        let r = DchSession.split([s("build", alias: "build-qa"), s("notes-qa", alias: "notes"),
                                  s("web", alias: "site"), s("api")], pattern: "-qa")
        XCTAssertEqual(names(r.primary), ["web", "api"])
        XCTAssertEqual(names(r.sidekicks), ["build", "notes-qa"])
    }

    func testAliasCaseInsensitive() {
        let r = DchSession.split([s("build", alias: "Build-QA"), s("notes")], pattern: "-qa")
        XCTAssertEqual(names(r.sidekicks), ["build"])
        XCTAssertEqual(names(r.primary), ["notes"])
    }

    func testOrderKept() {
        let r = DchSession.split([s("z-qa"), s("b"), s("a-qa"), s("a")], pattern: "-qa")
        XCTAssertEqual(names(r.primary), ["b", "a"])
        XCTAssertEqual(names(r.sidekicks), ["z-qa", "a-qa"])
    }

    func testAllSidekicksShowsSidekicks() {
        let r = DchSession.split([s("a-qa"), s("b-qa")], pattern: "-qa")
        XCTAssertTrue(DchSession.showsSidekicks(r, tab: false))
        XCTAssertTrue(DchSession.showsSidekicks(r, tab: true))
    }

    func testChosenTabShowsWhenBothHaveSessions() {
        let r = DchSession.split([s("a"), s("a-qa")], pattern: "-qa")
        XCTAssertFalse(DchSession.showsSidekicks(r, tab: false))
        XCTAssertTrue(DchSession.showsSidekicks(r, tab: true))
    }

    func testNoSidekicksShowsPrimary() {
        let r = DchSession.split([s("a"), s("b")], pattern: "-qa")
        XCTAssertFalse(DchSession.showsSidekicks(r, tab: false))
        XCTAssertFalse(DchSession.showsSidekicks(r, tab: true))
        XCTAssertFalse(DchSession.showsSidekicks(DchSession.split([], pattern: "-qa"), tab: true))
    }

    // #967: an empty segment can't be chosen, so tapping "Sessions (0)" never writes the tab.

    func testEmptySegmentNotChoosable() {
        let all = DchSession.split([s("a-qa"), s("b-qa")], pattern: "-qa")
        XCTAssertFalse(DchSession.choosable(all, tab: false))
        XCTAssertTrue(DchSession.choosable(all, tab: true))
        let both = DchSession.split([s("a"), s("a-qa")], pattern: "-qa")
        XCTAssertTrue(DchSession.choosable(both, tab: false))
        XCTAssertTrue(DchSession.choosable(both, tab: true))
    }

    // #1054: the empty segment is disabled on the control itself, so it draws dimmed and reads dimmed.

    @MainActor func testEmptySegmentDisabledOnControl() {
        let all = DchSession.split([s("a-qa")], pattern: "-qa")
        let picker = SegmentPicker(titles: ["Sessions (0)", "Sidekicks (1)"],
                                   enabled: [false, true].map { DchSession.choosable(all, tab: $0) },
                                   selection: .constant(1))
        let c = UISegmentedControl()
        picker.update(c)
        XCTAssertEqual(c.numberOfSegments, 2)
        XCTAssertFalse(c.isEnabledForSegment(at: 0))
        XCTAssertTrue(c.isEnabledForSegment(at: 1))
        XCTAssertEqual(c.selectedSegmentIndex, 1)
        // Both choosable again: re-enabled in place.
        let both = SegmentPicker(titles: ["Sessions (1)", "Sidekicks (1)"], enabled: [true, true], selection: .constant(0))
        both.update(c)
        XCTAssertTrue(c.isEnabledForSegment(at: 0))
        XCTAssertEqual(c.selectedSegmentIndex, 0)
    }

    // #1054: as the section header, the control spans the rows' x range, on the list SessionListView
    // uses (no style, in a NavigationStack), at an iPhone width with 16 pt and one with 20 pt insets.

    @MainActor func testHeaderSpansTheRows() {
        func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(all) }
        let picker = SegmentPicker(titles: ["Sessions (1)", "Sidekicks (1)"], enabled: [true, true], selection: .constant(0))
        for width in [402.0, 440] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 800))
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                List {
                    Text("Mac card")
                    Section { Text("row 1"); Text("row 2") } header: { picker.header }
                }
                .navigationTitle("Sessions")
            })
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            for _ in 0..<5 { window.layoutIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let views = all(window)
            guard let seg = views.first(where: { $0 is UISegmentedControl }).map({ $0.convert($0.bounds, to: window) })
            else { return XCTFail("\(width): no segmented control") }
            let cells = views.filter { $0 is UICollectionViewCell }.map { $0.convert($0.bounds, to: window) }
            guard let card = cells.filter({ $0.maxY <= seg.minY }).min(by: { $0.minY < $1.minY }),
                  let row = cells.filter({ $0.minY >= seg.maxY }).min(by: { $0.minY < $1.minY })
            else { return XCTFail("\(width): no card or row around the control, \(cells)") }
            XCTAssertGreaterThan(row.minX, 0, "\(width): an inset list")
            for edge in [card, row] {
                XCTAssertEqual(seg.minX, edge.minX, accuracy: 0.5, "\(width): left edge")
                XCTAssertEqual(seg.maxX, edge.maxX, accuracy: 0.5, "\(width): right edge")
            }
            XCTAssertGreaterThanOrEqual(row.minY - seg.maxY, 8, "\(width): clear of the first row")
        }
    }

    // #967: the chosen tab is kept per Mac, in the one scene-storage string.

    func testTabPerMachine() {
        var stored = ""
        stored = DchSession.sidekickTab(stored, machine: "A", set: true)
        XCTAssertTrue(DchSession.sidekickTab(stored, machine: "A"))
        XCTAssertFalse(DchSession.sidekickTab(stored, machine: "B"))
        stored = DchSession.sidekickTab(stored, machine: "B", set: true)
        stored = DchSession.sidekickTab(stored, machine: "A", set: false)
        XCTAssertFalse(DchSession.sidekickTab(stored, machine: "A"))
        XCTAssertTrue(DchSession.sidekickTab(stored, machine: "B"))
        XCTAssertEqual(DchSession.sidekickTab(stored, machine: "B", set: true), stored)   // no duplicate
        XCTAssertEqual(DchSession.sidekickTab(stored, machine: "B", set: false), "")
    }

    // #761: the pattern is a case-insensitive ICU regex, searched, in the name and the alias.

    func testRegexAlternation() {
        let r = DchSession.split([s("prosper-qa"), s("infra-stats-reviewer"), s("prosper-main"), s("qa-notes")],
                                 pattern: "-(qa|reviewer)$")
        XCTAssertEqual(names(r.sidekicks), ["prosper-qa", "infra-stats-reviewer"])
        XCTAssertEqual(names(r.primary), ["prosper-main", "qa-notes"], "$ anchors the end; no leading dash, no match")
    }

    func testRegexCaseInsensitive() {
        let r = DchSession.split([s("Prosper-QA"), s("infra-Reviewer"), s("main")], pattern: "-(qa|REVIEWER)$")
        XCTAssertEqual(names(r.sidekicks), ["Prosper-QA", "infra-Reviewer"])
        XCTAssertEqual(names(r.primary), ["main"])
    }

    func testRegexMatchesAlias() {
        let r = DchSession.split([s("build", alias: "build-reviewer"), s("notes", alias: "notes-rev")], pattern: "-(qa|reviewer)$")
        XCTAssertEqual(names(r.sidekicks), ["build"])
        XCTAssertEqual(names(r.primary), ["notes"])
    }

    /// A leading "*" is not a valid regex: the pattern is matched as text, ignoring case.
    func testInvalidRegexFallsBackToText() {
        XCTAssertNil(DchSession.sidekickRegex("*-qa"))
        var r = DchSession.split([s("build*-QA"), s("build-qa")], pattern: "*-qa")
        XCTAssertEqual(names(r.sidekicks), ["build*-QA"])
        XCTAssertEqual(names(r.primary), ["build-qa"])
        r = DchSession.split([s("prosper-qa"), s("infra-reviewer"), s("x", alias: "X*.?-(QA|reviewer)")], pattern: "*.?-(qa|reviewer)")
        XCTAssertEqual(names(r.sidekicks), ["x"], "only the literal text matches")
        XCTAssertEqual(names(r.primary), ["prosper-qa", "infra-reviewer"])
    }

    func testRegexValidity() {
        XCTAssertNotNil(DchSession.sidekickRegex("-qa"))
        XCTAssertNotNil(DchSession.sidekickRegex(" -(qa|reviewer)$ "))
        XCTAssertNil(DchSession.sidekickRegex("*.?-(qa|reviewer)"))
        XCTAssertNil(DchSession.sidekickRegex("-(qa"))
        XCTAssertNil(DchSession.sidekickRegex("  "), "empty: no regex, and no caption either")
        XCTAssertEqual(DchSession.sidekickRegex("-QA")?.options.contains(.caseInsensitive), true)
    }

    // The matcher's bounds and fallbacks. The cache is process-wide, so each pattern here is
    // used by this one test only.

    /// Unbounded, each search took seconds on main. The deadline is 10 ms of CPU per split
    /// call; 1 s leaves room for a loaded host.
    func testCatastrophicPatternIsBoundedThenText() {
        let list = [s("infra-stats-weekly-report-x"), s("abcdefghijklmnopqr")]
        let start = Date()
        for p in ["^(.*)*-qa$", "(.+)+x"] {
            XCTAssertEqual(DchSession.split(list, pattern: p).sidekicks.count, 0, p)
            XCTAssertEqual(DchSession.sidekickCaption(p, names: []), "Too slow on a session name: matched as text", p)
            let r = DchSession.split([s("z\(p)Z")] + list, pattern: p)
            XCTAssertEqual(names(r.sidekicks), ["z\(p)Z"], "\(p): matched as text from now on")
            // A render re-splits often: after the flip no call pays the deadline again.
            for _ in 0..<200 { _ = DchSession.split(list, pattern: p) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    /// A regex that matches "" would make every session a sidekick.
    func testEmptyMatchingPatternFallsBackToText() {
        let list = [s("build"), s("notes-QA|x"), s("a", alias: "x*y")]
        for (p, hit) in [("x*", "a"), ("-qa|", "notes-QA|x"), ("b|", "")] {
            XCTAssertEqual(DchSession.sidekickCaption(p, names: []), "Matches every session: matched as text", p)
            XCTAssertEqual(names(DchSession.split(list, pattern: p).sidekicks), hit.isEmpty ? [] : [hit], p)
        }
        // Zero-width patterns never match "" alone but match inside every name: a zero-width match is no hit.
        for p in ["\\b", "(?=build)", "(?<=a)"] {
            XCTAssertNil(DchSession.sidekickCaption(p, names: []), p)
            XCTAssertEqual(names(DchSession.split(list, pattern: p).sidekicks), [], p)
        }
    }

    private func savingBounds() -> () -> Void {
        let saved = (DchSession.sidekickDeadline, DchSession.sidekickSlowCall, DchSession.sidekickSlowTotal)
        return { (DchSession.sidekickDeadline, DchSession.sidekickSlowCall, DchSession.sidekickSlowTotal) = saved }
    }

    /// A pattern always under the deadline still flips once its slow calls add up.
    /// Deterministic: the deadline is out of reach and the thresholds are set outright.
    func testSlowCallTallyFlipsToText() {
        defer { savingBounds()() }
        let list = (0..<200).map { s("build-\($0)-tally") }   // 400 searches, far over a µs of CPU
        DchSession.sidekickDeadline = .max
        DchSession.sidekickSlowCall = .max   // no call counts toward the tally, so even a zero total holds
        DchSession.sidekickSlowTotal = 0
        XCTAssertEqual(DchSession.split(list, pattern: "-1\\d-tally$").sidekicks.count, 10)
        XCTAssertNil(DchSession.sidekickCaption("-1\\d-tally$", names: []))
        DchSession.sidekickSlowCall = 0     // every call counts, and any tally is over the total
        XCTAssertEqual(DchSession.split(list, pattern: "-2\\d-tally$").sidekicks.count, 0, "flipped: matched as text")
        XCTAssertEqual(DchSession.sidekickCaption("-2\\d-tally$", names: []), "Too slow on a session name: matched as text")
    }

    /// The "" probe backtracks too. The caption goes first with no names, so only the probe can say slow.
    func testEmptyProbeIsBoundedThenText() {
        let p = "(x?|y?){32}\\b"
        let start = Date()
        XCTAssertEqual(DchSession.sidekickCaption(p, names: []), "Too slow on a session name: matched as text")
        let r = DchSession.split([s("xy"), s("z\(p)Z")], pattern: p)
        XCTAssertEqual(names(r.sidekicks), ["z\(p)Z"], "matched as text")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    /// The slow-call bar scales with the texts searched, so many sessions under a cheap
    /// pattern never flip it.
    func testManySessionsCheapPatternStaysRegex() {
        defer { savingBounds()() }
        let list = (0..<1600).map { s("s\($0)-many", alias: $0 % 2 == 0 ? "a\($0)-reviewer" : nil) }
        DchSession.sidekickDeadline = .max
        DchSession.sidekickSlowCall = 300_000
        DchSession.sidekickSlowTotal = 0   // any call that counts flips it
        for _ in 0..<3 { XCTAssertEqual(DchSession.split(list, pattern: "-(qa|reviewer|many-x)$").sidekicks.count, 800) }
        XCTAssertNil(DchSession.sidekickCaption("-(qa|reviewer|many-x)$", names: []))
    }

    /// The other side: one pathological name among 1600 cheap sessions still counts the call.
    func testOneSlowNameAmongManyStillFlips() {
        defer { savingBounds()() }
        let slow = String(repeating: "x", count: 16)
        // As a regex it takes "xxy"; as text, only the name holding the pattern.
        let list = (0..<1600).map { s("s\($0)-few") } + [s(slow), s("xxy"), s("z(x+x+)+yZ")]
        DchSession.sidekickDeadline = .max
        DchSession.sidekickSlowCall = 300_000
        DchSession.sidekickSlowTotal = 0
        XCTAssertEqual(names(DchSession.split(list, pattern: "(x+x+)+y").sidekicks), ["z(x+x+)+yZ"], "flipped: matched as text")
        XCTAssertEqual(DchSession.sidekickCaption("(x+x+)+y", names: []), "Too slow on a session name: matched as text")
    }

    /// Ranges are UTF-16, so `$` finds the end of a Cyrillic + emoji name.
    func testRegexNonASCIIName() {
        let r = DchSession.split([s("Проспер-😀-qa"), s("Проспер-😀-qa-x"), s("бележки", alias: "ревю-👩‍💻-REVIEWER")],
                                 pattern: "😀-qa$|-reviewer$")
        XCTAssertEqual(names(r.sidekicks), ["Проспер-😀-qa", "бележки"])
        XCTAssertEqual(names(r.primary), ["Проспер-😀-qa-x"])
    }

    /// One caption per state, none for a usable regex or an empty pattern.
    func testCaptionStates() {
        let names = [String(repeating: "a", count: 20)]
        XCTAssertNil(DchSession.sidekickCaption("-(qa|reviewer)$", names: names))
        XCTAssertNil(DchSession.sidekickCaption("  ", names: names))
        XCTAssertNil(DchSession.sidekickCaption("\\b", names: names), "zero-width: a regex, it just takes no session")
        XCTAssertEqual(DchSession.sidekickCaption("*-qa", names: names), "Not a valid regex: matched as text")
        XCTAssertEqual(DchSession.sidekickCaption("a|", names: names), "Matches every session: matched as text")
        XCTAssertEqual(DchSession.sidekickCaption("([a-z]+)*-qa$", names: names), "Too slow on a session name: matched as text")
    }
}
