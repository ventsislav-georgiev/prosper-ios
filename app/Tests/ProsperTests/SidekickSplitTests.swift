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

    private let sidekicks = DchSession.groups(nil, sidekick: "-qa")

    func testAllSidekicksShowsSidekicks() {
        let r = DchSession.grouped([s("a-qa"), s("b-qa")], sidekicks)
        XCTAssertEqual(DchSession.shown(r, tab: nil), 0)
        XCTAssertEqual(DchSession.shown(r, tab: "sidekicks"), 0)
    }

    func testChosenTabShowsWhenBothHaveSessions() {
        let r = DchSession.grouped([s("a"), s("a-qa")], sidekicks)
        XCTAssertNil(DchSession.shown(r, tab: nil))
        XCTAssertEqual(DchSession.shown(r, tab: "sidekicks"), 0)
    }

    func testNoSidekicksShowsPrimary() {
        let r = DchSession.grouped([s("a"), s("b")], sidekicks)
        XCTAssertTrue(r.sections.isEmpty)
        XCTAssertNil(DchSession.shown(r, tab: "sidekicks"))
        XCTAssertNil(DchSession.shown(DchSession.grouped([], sidekicks), tab: "sidekicks"))
    }

    // #1769: the Mac's groups, one section each in its order; the first match wins, an empty
    // pattern or an empty group draws nothing, the rest stay in Sessions.

    func testGroupsFirstMatchWinsInOrderAndEmptyOnesHide() {
        let groups = [SessionGroup(id: "sidekicks", name: "Sidekicks", pattern: "-qa"),
                      SessionGroup(id: "none", name: "None", pattern: " "),
                      SessionGroup(id: "rev", name: "Reviewers", pattern: "-(rev|review)$|-qa"),
                      SessionGroup(id: "lit", name: "Literal", pattern: "*["),
                      SessionGroup(id: "idle", name: "Idle", pattern: "-idle$")]
        let r = DchSession.grouped([s("x-review"), s("a-qa"), s("main"), s("b*[c"), s("c-rev")], groups)
        XCTAssertEqual(r.sections.map(\.group.name), ["Sidekicks", "Reviewers", "Literal"], "list order, empty groups hidden")
        XCTAssertEqual(r.sections.map { names($0.sessions) }, [["a-qa"], ["x-review", "c-rev"], ["b*[c"]], "first match wins")
        XCTAssertEqual(names(r.primary), ["main"])
        XCTAssertEqual(DchSession.shown(r, tab: "rev"), 1)
        XCTAssertNil(DchSession.shown(r, tab: "idle"), "a group with no sessions: Sessions")
        XCTAssertTrue(DchSession.grouped([s("a-qa")], []).sections.isEmpty, "an empty list: no split")
    }

    func testStoredGroupsWinOverTheSidekickPattern() throws {
        let g = [SessionGroup(id: "g1", name: "Reviewers", pattern: "-rev")]
        XCTAssertEqual(DchSession.groups(try JSONEncoder().encode(g), sidekick: "-qa"), g)
        XCTAssertEqual(DchSession.groups(try JSONEncoder().encode([SessionGroup]()), sidekick: "-qa"), [])
        XCTAssertEqual(DchSession.groups(nil, sidekick: "-x"), [SessionGroup(id: "sidekicks", name: "Sidekicks", pattern: "-x")])
    }

    // #1054: the empty segment is disabled on the control itself, so it draws dimmed and reads dimmed.

    @MainActor func testEmptySegmentDisabledOnControl() {
        let all = DchSession.split([s("a-qa")], pattern: "-qa")
        let picker = SegmentPicker(titles: ["Sessions (0)", "Sidekicks (1)"],
                                   enabled: [!all.primary.isEmpty, !all.sidekicks.isEmpty],
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
        stored = DchSession.tab(stored, machine: "A", set: "sidekicks")
        XCTAssertEqual(DchSession.tab(stored, machine: "A"), "sidekicks")
        XCTAssertNil(DchSession.tab(stored, machine: "B"))
        stored = DchSession.tab(stored, machine: "B", set: "g7")
        stored = DchSession.tab(stored, machine: "A", set: nil)
        XCTAssertNil(DchSession.tab(stored, machine: "A"))
        XCTAssertEqual(DchSession.tab(stored, machine: "B"), "g7")
        XCTAssertEqual(DchSession.tab(stored, machine: "B", set: "g7"), stored)   // no duplicate
        XCTAssertEqual(DchSession.tab(stored, machine: "B", set: nil), "")
        XCTAssertEqual(DchSession.tab("A,B=g7", machine: "A"), "sidekicks", "a bare id, stored before #1769")
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

    // #1502: the title ("harness" on the wire).

    private func h(_ name: String, alias: String? = nil, harness: String?) -> DchSession {
        DchSession(name: name, alias: alias, harness: harness)
    }

    func testDecodeHarness() throws {
        let long = String(repeating: "x", count: DchSession.maxHarnessBytes + 1)
        let json = """
        [{"name":"a","alias":"A","harness":"fix-qa"},{"name":"b"},{"name":"c","alias":"C","harness":"C"},
         {"name":"d","harness":""},{"name":"e","harness":"\(long)"}]
        """
        let l = try ProsperTransport.decodeList(Data(json.utf8))
        XCTAssertEqual(l.map(\.harness), ["fix-qa", nil, nil, nil, nil], "older Macs omit it; equal, empty and over-cap are dropped")
        XCTAssertEqual(l[0].title, "A", "the display is unchanged")
    }

    func testTitleOnlyMatchLandsInSidekicks() {
        let r = DchSession.split([h("web", alias: "Site", harness: "fix-qa-run"), h("api", harness: nil)], pattern: "-qa")
        XCTAssertEqual(names(r.sidekicks), ["web"])
        XCTAssertEqual(names(r.primary), ["api"])
    }

    func testNameAndAliasStillMatchAndTitleNotDoubleCounted() {
        let r = DchSession.split([h("a-qa", harness: "x-qa"), h("b", alias: "b-qa", harness: "b-qa"), h("c", harness: "none")], pattern: "-qa")
        XCTAssertEqual(names(r.sidekicks), ["a-qa", "b"], "one row each, in order")
        XCTAssertEqual(names(r.primary), ["c"])
        // A title equal to the alias is dropped on decode, so only one text carries it.
        let l = try? ProsperTransport.decodeList(Data(#"[{"name":"b","alias":"b-qa","harness":"b-qa"}]"#.utf8))
        XCTAssertNil(l?.first?.harness)
    }

    func testTitleOnlyFlagComesWithTheSplit() {
        let titled = h("web", alias: "Site", harness: "fix-qa")
        let named = h("x-qa", harness: "other-qa")
        let r = DchSession.splitNoted([titled, h("p", harness: "none")], pattern: "-qa")
        XCTAssertTrue(r.titleOnly)
        XCTAssertEqual(names(r.split.sidekicks), ["web"])
        XCTAssertFalse(DchSession.splitNoted([named, h("p", harness: "none")], pattern: "-qa").titleOnly, "the name matched too")
        XCTAssertFalse(DchSession.splitNoted([titled], pattern: " ").titleOnly)
        XCTAssertNil(DchSession.sidekickCaption("-qa", names: ["web"]), "Settings' caption is unchanged")
    }

    // #1502: the titles' timing guard, on a counted clock (the Mac's R1210-a tests). Each pattern is used by one test only.

    /// The thresholds and the clock, restored by the caller's defer.
    private func savingClock() -> () -> Void {
        let restore = savingBounds(), cpu = DchSession.sidekickCPU
        return { restore(); DchSession.sidekickCPU = cpu }
    }

    /// Each read advances `tick` ns, so a call's cost is its count of reads (the Mac's countingCPU).
    private func countingCPU(tick: UInt64) -> () -> UInt64 {
        var now: UInt64 = 0
        return { now += tick; return now }
    }

    /// A title past the deadline is no hit, nor is any title after it in that call; the pattern stays a regex.
    /// 1 ns a read, 400 reads: the names and the 2-byte title take a few each, the 600 x's backtrack
    /// x+y from each start (a progress read per start, at least), so the deadline lands in them.
    func testLateTitleIsNoHitAndNeverFlipsThePattern() {
        let restore = savingClock(); defer { restore() }
        DchSession.sidekickDeadline = 400
        DchSession.sidekickSlowCall = .max
        DchSession.sidekickSlowTotal = .max
        DchSession.sidekickCPU = countingCPU(tick: 1)
        let p = "[x]+y"
        let list = [s("xxy"), h("b", harness: "xy"), h("c", harness: String(repeating: "x", count: 600)),
                    h("d", harness: String(repeating: "x", count: 700) + "y")]
        for _ in 0..<2 {
            let r = DchSession.split(list, pattern: p)
            XCTAssertEqual(names(r.sidekicks), ["xxy", "b"], "the name by regex and the early title; d's title comes after the late one")
        }
        XCTAssertNil(DchSession.sidekickCaption(p, names: []), "never flipped to text")
    }

    /// Names and aliases are tallied as before titles: a title's cost never flips them. The titles' own
    /// tally, once past sidekickSlowTotal, makes the next call match titles as text; names stay a regex.
    /// 1 ns a read: the 8 name texts are a few reads each (under 200 per 16), the 600 x's far over it.
    func testTitlesHaveTheirOwnTallyThenMatchAsText() {
        let restore = savingClock(); defer { restore() }
        DchSession.sidekickDeadline = .max
        DchSession.sidekickSlowCall = 200
        DchSession.sidekickSlowTotal = 0
        DchSession.sidekickCPU = countingCPU(tick: 1)
        let p = "x+y"
        let list = [s("xxy"), h("b", harness: "xxy"), h("c", harness: "q-x+y-q"), h("d", harness: String(repeating: "x", count: 600))]
        XCTAssertEqual(names(DchSession.split(list, pattern: p).sidekicks), ["xxy", "b"], "first call: all a regex")
        XCTAssertEqual(names(DchSession.split(list, pattern: p).sidekicks), ["xxy", "c"], "titles as text, the name still a regex")
        XCTAssertNil(DchSession.sidekickCaption(p, names: []), "the pattern itself never flipped")
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
        let restore = savingBounds(); defer { restore() }
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
        let restore = savingBounds(); defer { restore() }
        let list = (0..<1600).map { s("s\($0)-many", alias: $0 % 2 == 0 ? "a\($0)-reviewer" : nil) }
        DchSession.sidekickDeadline = .max
        DchSession.sidekickSlowCall = 300_000
        DchSession.sidekickSlowTotal = 0   // any call that counts flips it
        for _ in 0..<3 { XCTAssertEqual(DchSession.split(list, pattern: "-(qa|reviewer|many-x)$").sidekicks.count, 800) }
        XCTAssertNil(DchSession.sidekickCaption("-(qa|reviewer|many-x)$", names: []))
    }

    /// The other side: one pathological name among 1600 cheap sessions still counts the call.
    func testOneSlowNameAmongManyStillFlips() {
        let restore = savingBounds(); defer { restore() }
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
