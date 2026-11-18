import XCTest
import SwiftUI
@testable import Prosper

/// The list row's PRs (the Mac's `meta`), decoded and drawn like Agent Island.
final class SessionMetaTests: XCTestCase {

    private func meta(_ json: String) -> SessionMeta? {
        SessionMeta(json: try! JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    private func pr(_ repo: String, _ num: Int?) -> SessionMeta.PR {
        .init(url: nil, repo: repo, num: num, title: "")
    }

    func testDecodeFull() {
        let m = meta(#"{"prs":{"open":[{"url":"https://github.com/o/prosper/pull/12","repo":"o/prosper","num":12,"title":"Fix it"}],"merged":4}}"#)
        XCTAssertEqual(m, SessionMeta(open: [.init(url: URL(string: "https://github.com/o/prosper/pull/12"),
                                                   repo: "o/prosper", num: 12, title: "Fix it")], merged: 4))
    }

    /// Absent or non-object meta is nil, so the row draws as before.
    func testDecodeAbsent() {
        XCTAssertNil(SessionMeta(json: nil))
        XCTAssertNil(SessionMeta(json: "x"))
        XCTAssertNil(SessionMeta(json: [1]))
    }

    func testDecodePartial() {
        let m = meta(#"{"prs":{"open":[{"repo":"o/r","url":"https://github.com/o/r/pull/1"}]}}"#)!
        XCTAssertNil(m.merged)
        XCTAssertEqual(m.open, [.init(url: URL(string: "https://github.com/o/r/pull/1"), repo: "o/r", num: nil, title: "")])
    }

    /// Wrong types and negative numbers drop only that field (or that PR); a meta left with nothing is nil.
    func testDecodeGarbage() {
        let m = meta(#"{"tasks":{"done":"3","total":-1,"in_progress":true,"queued":1.5},"prs":{"open":[1,"x",{"url":5,"repo":"o/r","num":-7,"title":["t"]},{"num":3},{"repo":"o/q","num":3,"url":"http://github.com/o/q/pull/3"},{"repo":"o/z","url":"https://evil.example/o/z/pull/1"}],"merged":"many"}}"#)!
        XCTAssertEqual(m, SessionMeta(open: [pr("o/r", nil), pr("o/q", 3), pr("o/z", nil)]))
        XCTAssertNil(meta(#"{"tasks":[],"prs":{"open":{"url":"x"},"merged":-2}}"#))
    }

    /// #763: the phone draws no tasks; a Mac that still sends them changes nothing.
    func testTasksKeyIgnored() {
        XCTAssertEqual(meta(#"{"tasks":{"done":3,"total":7,"in_progress":1,"queued":2},"prs":{"merged":4}}"#),
                       SessionMeta(merged: 4))
        XCTAssertNil(meta(#"{"tasks":{"done":3,"total":7,"in_progress":1,"queued":2}}"#), "tasks alone draw nothing")
        XCTAssertNil(meta(#"{"tasks":"junk"}"#))
    }

    /// A meta with nothing to draw is nil, so the row gains no empty gap.
    func testNothingToShowIsNil() {
        for j in [#"{}"#, #"{"prs":{"open":[]}}"#, #"{"prs":{"open":[],"merged":0}}"#, #"{"tasks":{"done":0,"total":0}}"#] {
            XCTAssertNil(meta(j), j)
        }
        XCTAssertNotNil(meta(#"{"prs":{"open":[],"merged":4}}"#))
    }

    /// A whole list row with meta keeps the row; a row without keeps meta nil.
    func testListRowMeta() {
        let rows = try! JSONSerialization.jsonObject(with: Data(#"[{"name":"a","state":"idle","meta":{"prs":{"open":[],"merged":4}},"meta_epoch":1784995200},{"name":"b","meta":7}]"#.utf8)) as! [[String: Any]]
        XCTAssertEqual(SessionMeta(json: rows[0]["meta"])?.merged, 4)
        XCTAssertNil(SessionMeta(json: rows[1]["meta"]))
    }

    func testTitleIsOnePlainLine() {
        XCTAssertEqual(SessionMeta.plain("a\nb\r\u{202E}c\u{2066}d\u{2069}"), "a b cd")
        XCTAssertEqual(SessionMeta.plain("\u{202A}\u{202B}\u{202C}\u{202D}\u{2067}\u{2068}x"), "x", "bidi overrides and isolates go")
        XCTAssertEqual(SessionMeta.plain("a\u{0}b\u{1B}c\u{7F}\u{9B}d"), "abcd", "controls, U+0000 included, go")
        XCTAssertEqual(SessionMeta.plain("line4\ttab"), "line4 tab", "a tab is a space")
        let m = meta(#"{"prs":{"open":[{"repo":"o/r","num":1,"title":"x\u0000y\n\u202Ez"}]}}"#)!
        XCTAssertEqual(m.open.first?.title, "xy z", "decoded titles are cleaned")
        XCTAssertEqual(SessionMeta.plain("👨‍👩‍👧 ok"), "👨‍👩‍👧 ok", "ZWJ is not a bidi control")
        XCTAssertEqual(SessionMeta.plain(String(repeating: "x", count: 300)).count, 200)
    }

    func testCountCap() {
        XCTAssertEqual(SessionMeta.count(99_999), "99999")
        XCTAssertEqual(SessionMeta.count(100_000), "99999+")
        XCTAssertEqual(SessionMeta.words(1_000_000, "merged pull request"), "99999+ merged pull requests")
        XCTAssertEqual(meta("{\"prs\":{\"merged\":\(Int.max)}}")?.detailLines(RowDetails()).first?.merged, Int.max, "drawn capped")
    }

    func testChipsMoreAndMerged() {
        XCTAssertEqual(pr("o/prosper", 12).chip, "prosper#12")
        XCTAssertEqual(pr("o/prosper", nil).chip, "prosper")
        XCTAssertEqual(pr("o/averyverylongrepo", 1).chip, "averyverylongrepo#1", "full label unless cut")
        XCTAssertEqual(pr("o/averyverylongrepo", 1).chip(maxRepo: SessionMeta.maxRepo), "averyverylongrepo#1", "17 fits")
        XCTAssertEqual(pr("o/eighteencharsrepo1", 1).chip(maxRepo: SessionMeta.maxRepo), "eighteencharsrepo1#1", "18 fits")
        XCTAssertEqual(pr("o/nineteencharsrepo12", 1).chip(maxRepo: SessionMeta.maxRepo), "nineteencharsrepo…#1", "19 cut to 18")
    }

    /// #1518: the Mac's count words, singular at 1.
    func testCountWords() {
        XCTAssertEqual(SessionMeta.words(2, "agent"), "2 agents")
        XCTAssertEqual(SessionMeta.words(1, "agent"), "1 agent")
        XCTAssertEqual(SessionMeta.words(75, "merged pull request"), "75 merged pull requests")
        XCTAssertEqual(SessionMeta.words(1, "open pull request"), "1 open pull request")
    }

    /// Junk entries never hide valid PRs behind the cap, and the cap still holds.
    func testCapAfterFilter() {
        let valid = { (n: Int) in #"{"repo":"o/r","num":\#(n)}"# }
        let junk = Array(repeating: "1", count: 50) + (1...3).map(valid)
        XCTAssertEqual(meta(#"{"prs":{"open":["# + junk.joined(separator: ",") + "]}}")?.open.count, 3)
        XCTAssertEqual(meta(#"{"prs":{"open":["# + (1...60).map(valid).joined(separator: ",") + "]}}")?.open.count, 50)
    }

    func testEmptyRepoDroppedAndRepoCleaned() {
        let m = meta(#"{"prs":{"open":[{"repo":"","num":1},{"repo":"o/\u202Eab\u0000c\nd","num":2}]}}"#)!
        XCTAssertEqual(m.open.map(\.repo), ["o/abc d"])
    }

    /// A num too big for a chip is dropped like any other bad num.
    func testHugeNumIsNil() {
        XCTAssertEqual(meta(#"{"prs":{"open":[{"repo":"o/r","num":9999999}]}}"#)?.open.first?.num, 9_999_999)
        XCTAssertNil(meta("{\"prs\":{\"open\":[{\"repo\":\"o/r\",\"num\":\(Int.max)}]}}")!.open.first!.num)
    }

    // MARK: - Row details (#533)

    private let full = SessionMeta(open: [.init(url: nil, repo: "o/repo", num: 12, title: "")], merged: 75)

    private func with(_ change: (inout RowDetails) -> Void) -> RowDetails {
        var d = RowDetails(); change(&d); return d
    }

    /// #1518: the Mac's Row details defaults: State, Agents, Merged and Open PRs all on.
    func testRowDetailsDefaults() {
        XCTAssertEqual(RowDetails(), RowDetails(state: true, agents: true, openPRs: true, merged: true))
        XCTAssertEqual(RowDetails(), RowDetails(model: true, effort: true, age: true), "#1532: Model, Effort and Age on too")
    }

    private typealias Line = SessionMeta.DetailLine

    /// #1518: line 2 folds in the Mac's order: 3, 2, 1 chips with "+N" for the rest, then the
    /// open count alone, then merged alone, then nothing (the state word, outside, stays).
    func testDetailLinesFoldOrder() {
        let long = "o/" + String(repeating: "r", count: 20), cut = String(repeating: "r", count: 17) + "…#2"
        let m = SessionMeta(open: [pr("o/a", 1), pr(long, 2), pr("o/c", 3), pr("o/d", 4), pr("o/e", 5)], merged: 7)
        XCTAssertEqual(m.detailLines(RowDetails()), [
            Line(merged: 7, open: 5, chips: ["a#1", cut, "c#3"], more: 2),
            Line(merged: 7, open: 5, chips: ["a#1", cut], more: 3),
            Line(merged: 7, open: 5, chips: ["a#1"], more: 4),
            Line(merged: 7, open: 5),
            Line(merged: 7),
            Line(),
        ])
        XCTAssertEqual(SessionMeta(open: [pr("o/a", 1)]).detailLines(RowDetails()),
                       [Line(open: 1, chips: ["#1"]), Line(open: 1), Line()], "no +N when every PR has a chip")
        XCTAssertEqual(SessionMeta(merged: 4).detailLines(RowDetails()), [Line(merged: 4), Line()])
    }

    /// #1530: chips read "#N" when all open PRs share a repo, "repo#N" across several; the
    /// menu label, row action and VoiceOver text keep "repo#N" either way.
    func testChipRepoOnlyAcrossRepos() {
        let one = SessionMeta(open: [pr("o/a", 1), pr("o/a", 2)])
        XCTAssertEqual(one.detailLines(RowDetails()).first?.chips, ["#1", "#2"])
        let two = SessionMeta(open: [pr("o/a", 1), pr("o/b", 2)])
        XCTAssertEqual(two.detailLines(RowDetails()).first?.chips, ["a#1", "b#2"])
        let u = URL(string: "https://github.com/o/a/pull/1")!
        let m = SessionMeta(open: [.init(url: u, repo: "o/a", num: 1, title: ""), pr("o/a", 2)])
        let sess = DchSession(name: "x", alias: nil, meta: m)
        XCTAssertEqual(sess.rowActions(ops: [], busy: true), [.rename, .openPR(chip: "a#1", url: u)], "menu and VoiceOver action keep the repo")
        XCTAssertEqual(sess.rowAccessibility(RowDetails()), "x, 2 open pull requests")
    }

    /// #1518: a count shows only above 0; a hidden detail drops out of every fold.
    func testDetailLinesCountsAndToggles() {
        XCTAssertEqual(SessionMeta(open: [], merged: 0).detailLines(RowDetails()), [Line()], "zero merged: no group")
        XCTAssertEqual(full.detailLines(with { $0.openPRs = false }), [Line(merged: 75), Line()])
        XCTAssertEqual(full.detailLines(with { $0.merged = false }),
                       [Line(open: 1, chips: ["#12"]), Line(open: 1), Line()])
        XCTAssertEqual(full.detailLines(with { $0.openPRs = false; $0.merged = false }), [Line()])
    }

    /// #1518: each fold is narrower than the one before, so as the row narrows ViewThatFits
    /// drops the chips one by one, then the open count, then merged, never skipping back.
    @MainActor func testEachFoldIsNarrower() {
        let m = SessionMeta(open: (1...5).map { pr("o/sample-app", $0) }, merged: 135)
        let widths = m.detailLines(RowDetails()).map {
            UIHostingController(rootView: SessionRow.detailLine($0).font(.footnote)).sizeThatFits(in: CGSize(width: 1000, height: 100)).width
        }
        XCTAssertEqual(widths.count, 6)
        for i in 1..<widths.count { XCTAssertLessThan(widths[i], widths[i - 1], "fold \(i)") }
    }

    /// #1518: the Mac's state mark and words.
    func testStateMarkAndWord() {
        XCTAssertEqual(SessionStateStyle.allCases.map { SessionRow.mark($0) }, ["\u{2733}\u{FE0E}", "!", "\u{25CF}", "\u{25CF}"])
        XCTAssertEqual(SessionRow.mark(nil), "\u{25CB}", "no state: ○")
        XCTAssertEqual(SessionStateStyle.allCases.map(\.label), ["Working", "Needs input", "Idle", "Done"])
        // The Live Activity's line keeps its own "+N agents" wording.
        XCTAssertEqual(SessionStateStyle.agents(1), "+1 agent")
        XCTAssertNil(SessionStateStyle.agents(0))
    }

    /// #1518: the row's touch actions: Rename, Restart on `.restart`, Stop, then Open for each
    /// linked PR; a running verb leaves Rename and the PRs.
    func testRowActions() {
        let u = URL(string: "https://github.com/o/repo/pull/12")!
        let meta = SessionMeta(open: [.init(url: u, repo: "o/repo", num: 12, title: ""), pr("o/nolink", 3)])
        let s = DchSession(name: "a", alias: nil, meta: meta)
        XCTAssertEqual(s.rowActions(ops: [.restart, .stop], busy: false),
                       [.rename, .restart, .stop, .openPR(chip: "repo#12", url: u)])
        XCTAssertEqual(s.rowActions(ops: [], busy: false), [.rename, .stop, .openPR(chip: "repo#12", url: u)], "no restart verb")
        XCTAssertEqual(s.rowActions(ops: [.restart], busy: true), [.rename, .openPR(chip: "repo#12", url: u)])
        XCTAssertEqual(DchSession(name: "b", alias: nil).rowActions(ops: [.restart], busy: false), [.rename, .restart, .stop])
    }

    /// QA at accessibility sizes: the fixed agents chip squeezed the title to "…" and
    /// pushed the row past the screen edge.
    @MainActor func testRowFitsAtAccessibilitySizes() {
        let store = UserDefaults(suiteName: "SessionMetaTests.row")!
        store.removePersistentDomain(forName: "SessionMetaTests.row")   // the default toggles
        func size(_ s: DchSession, _ t: DynamicTypeSize, _ w: CGFloat) -> CGSize {
            UIHostingController(rootView: SessionRow(session: s).environment(\.dynamicTypeSize, t).defaultAppStorage(store))
                .sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude))
        }
        let meta = SessionMeta(open: [pr("o/sample-codebase1", 370)] + (1...5).map { pr("o/r", $0) }, merged: 100_000)
        let row = DchSession(name: "sample-1", alias: "A very long alias for this row", state: "blocked", agents: 12, meta: meta)
        var lone = row; lone.agents = 0
        var short = row; short.alias = "x"
        for (t, w) in [(DynamicTypeSize.accessibility1, 300.0), (.accessibility5, 300), (.accessibility5, 200)] {
            XCTAssertLessThanOrEqual(size(row, t, w).width, w + 0.5, "\(t) at \(w): nothing pushes the row wider")   // ⅓ pt rounding
            XCTAssertGreaterThan(size(row, t, w).height, size(lone, t, w).height, "\(t): the agents chip has its own line")
            XCTAssertGreaterThan(size(row, t, w).height, size(short, t, w).height, "\(t): the title wraps, not cut to …")
        }
        XCTAssertEqual(size(row, .large, 300).height, size(lone, .large, 300).height, "below them the chip sits by the title")
    }

    /// #1532 QA: at AX-XXXL "Opus 4.7" and "xhigh" ran past the row's right edge and pushed the
    /// state mark past its left one. Laid out at a row's width, every drawn layer stays inside it.
    @MainActor func testBadgesFitAtTheLargestSize() {
        let store = UserDefaults(suiteName: "SessionMetaTests.axBadges")!
        store.removePersistentDomain(forName: "SessionMetaTests.axBadges")   // the default toggles
        let s = DchSession(name: "a", alias: "qa1532-a-rather-long-session-name", state: "idle", agents: 2,
                           model: "Opus 4.7", effort: "xhigh", activity: 60)
        for w in [330.0, 300, 200] as [CGFloat] {
            let host = UIHostingController(rootView: SessionRow(session: s).environment(\.dynamicTypeSize, .accessibility5).defaultAppStorage(store))
            let size = host.sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(size.width, w + 0.5, "\(w): the content fits the row")
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: w, height: size.height))
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            func drawn(_ l: CALayer) -> [CGRect] {
                (l.sublayers ?? []).flatMap { c in c.sublayers?.isEmpty == false ? drawn(c) : [c.convert(c.bounds, to: host.view.layer)] }
            }
            let frames = drawn(host.view.layer).filter { $0.width > 0 && $0.height > 0 }
            XCTAssertFalse(frames.isEmpty)
            XCTAssertGreaterThanOrEqual(frames.map(\.minX).min() ?? -1, -0.5, "\(w): the state mark starts inside the row")
            XCTAssertLessThanOrEqual(frames.map(\.maxX).max() ?? .infinity, w + 0.5, "\(w): no pill past the right edge")
            window.isHidden = true
        }
    }

    /// #1551 QA: at AX-XXXL (and xxxLarge) the state mark's right side was cut flat: its column was narrower
    /// than the glyph. Every mark draws at least its own width, and the titles still line up.
    @MainActor func testStateMarkDrawsWholeAtEverySize() {
        let store = UserDefaults(suiteName: "SessionMetaTests.mark")!
        store.removePersistentDomain(forName: "SessionMetaTests.mark")
        let states: [String?] = SessionStateStyle.allCases.map(\.rawValue) + [nil]
        for t in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility5] {
            var titleX: Set<CGFloat> = []
            for st in states {
                let mark = SessionRow.mark(SessionStateStyle(st))
                let glyph = UIHostingController(rootView: Text(verbatim: mark).font(.subheadline.bold())
                    .environment(\.dynamicTypeSize, t)).sizeThatFits(in: CGSize(width: 1000, height: 1000)).width
                let host = UIHostingController(rootView: SessionRow(session: DchSession(name: "a", alias: "Docs", state: st))
                    .environment(\.dynamicTypeSize, t).defaultAppStorage(store))
                let size = host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: size.height))
                window.rootViewController = host
                window.isHidden = false
                host.view.frame = window.bounds
                host.view.layoutIfNeeded()
                func drawn(_ l: CALayer) -> [CGRect] {
                    (l.sublayers ?? []).flatMap { c in c.sublayers?.isEmpty == false ? drawn(c) : [c.convert(c.bounds, to: host.view.layer)] }
                }
                let frames = drawn(host.view.layer).filter { $0.width > 0 && $0.height > 0 }.sorted { $0.minX < $1.minX }
                let markFrame = try! XCTUnwrap(frames.first)
                XCTAssertGreaterThanOrEqual(markFrame.width, glyph - 0.5, "\(t) \(mark): the mark is drawn whole")
                let title = try! XCTUnwrap(frames.first { $0.minX > markFrame.minX + 0.5 })
                XCTAssertGreaterThanOrEqual(title.minX, markFrame.maxX - 0.5, "\(t) \(mark): the title clears the mark")
                // The column (the title's x less the 10 pt spacing) holds the mark; ✳'s ink runs past its advance at any size.
                XCTAssertGreaterThanOrEqual(title.minX - 10, glyph - 0.5, "\(t) \(mark): the column is as wide as the mark")
                titleX.insert((title.minX * 2).rounded() / 2)
                window.isHidden = true
            }
            XCTAssertEqual(titleX.count, 1, "\(t): the titles line up across states: \(titleX)")
            if t == .large { XCTAssertEqual(titleX, [24], "the default size keeps its 14 pt column") }
        }
    }

    /// VoiceOver reads the title and state, then only what is toggled on, in the Mac's words.
    func testRowAccessibilityFollowsToggles() {
        let s = DchSession(name: "sec-1", alias: "Docs", state: "working", agents: 4, meta: full)
        XCTAssertEqual(s.rowAccessibility(RowDetails()),
                       "Docs, Working, 4 agents, 75 merged pull requests, 1 open pull request")
        XCTAssertEqual(s.rowAccessibility(RowDetails(agents: false, openPRs: false, merged: false)), "Docs, Working",
                       "no dch name under the alias")
        XCTAssertEqual(s.rowAccessibility(with { $0.agents = false }),
                       "Docs, Working, 75 merged pull requests, 1 open pull request")
        XCTAssertEqual(DchSession(name: "a", alias: nil, agents: 1).rowAccessibility(RowDetails()), "a, 1 agent")
    }

    /// #1518: each toggle hides its piece and frees its room; all off leaves the title (and
    /// the mark) on one line.
    @MainActor func testTogglesHideTheirPieces() {
        let store = UserDefaults(suiteName: "SessionMetaTests.toggles")!
        defer { store.removePersistentDomain(forName: "SessionMetaTests.toggles") }
        func height(_ s: DchSession) -> CGFloat {
            UIHostingController(rootView: SessionRow(session: s).defaultAppStorage(store))
                .sizeThatFits(in: CGSize(width: 390, height: 2000)).height
        }
        let row = DchSession(name: "a", alias: "Docs", state: "working", agents: 2, meta: full)
        let bare = DchSession(name: "a", alias: "Docs")
        let two = height(row)
        XCTAssertGreaterThan(two, height(bare), "two lines with details, one without")
        store.set(false, forKey: RowDetails.Key.state)
        // #1530: caption chips are a point shorter than the footnote state word.
        XCTAssertGreaterThan(height(row), height(bare), "the counts keep line 2")
        for k in [RowDetails.Key.openPRs, RowDetails.Key.merged] { store.set(false, forKey: k) }
        XCTAssertEqual(height(row), height(bare), "all off: the title alone")
        func ideal() -> CGFloat {
            UIHostingController(rootView: SessionRow(session: row).fixedSize().defaultAppStorage(store))
                .sizeThatFits(in: CGSize(width: 1000, height: 1000)).width
        }
        let wide = ideal()
        store.set(false, forKey: RowDetails.Key.agents)
        XCTAssertLessThan(ideal(), wide, "Agents off drops the capsule")
    }

    func testTransportListDecode() throws {
        let rows = try ProsperTransport.decodeList(Data(#"[{"name":"a","agents":2,"meta":{"prs":{"open":[{"repo":"o/r","num":5}],"merged":1}}},{"name":"b"},{"x":1}]"#.utf8))
        XCTAssertEqual(rows.map(\.name), ["a", "b"])
        XCTAssertEqual(rows[0].meta, SessionMeta(open: [pr("o/r", 5)], merged: 1))
        XCTAssertNil(rows[1].meta)
        XCTAssertEqual(try ProsperTransport.decodeList(Data("[]".utf8)), [])
    }

    /// An unreadable list is an error, not "no sessions".
    func testTransportListUnparseableThrows() {
        for bad in [#"[{"name":"a","n":1e400}]"#, #"[{"name":"\ud800"}]"#, "{}", ""] {
            XCTAssertThrowsError(try ProsperTransport.decodeList(Data(bad.utf8)), bad)
        }
    }

    // MARK: - Model, effort and age (#1532)

    /// golden/02-list (Mac #1519), every optional key set, then a row as an older Mac sends it.
    private let golden = #"[{"agents":2,"alias":"API","activity":1784995200,"cwd":"/Users/me/api","effort":"xhigh","meta":{"prs":{"open":[]}},"meta_epoch":1784995100,"model":"Opus 4.7","name":"api","state":"idle"},{"name":"old","state":"idle"}]"#

    private func row(_ keys: String) throws -> DchSession {
        try XCTUnwrap(try ProsperTransport.decodeList(Data("[{\"name\":\"a\"\(keys)}]".utf8)).first)
    }

    func testListModelEffortActivityDecode() throws {
        let rows = try ProsperTransport.decodeList(Data(golden.utf8))
        XCTAssertEqual(rows.map(\.model), ["Opus 4.7", nil])
        XCTAssertEqual(rows.map(\.effort), ["xhigh", nil])
        XCTAssertEqual(rows.map(\.activity), [1_784_995_200, nil], "a missing key is nil: nothing shows")
        // The model: printable ASCII up to 128 bytes, trimmed.
        let long = String(repeating: "m", count: 128)
        XCTAssertEqual(try row(#","model":"\#(long)""#).model, long, "128 bytes is the cap")
        XCTAssertNil(try row(#","model":"\#(long)x","effort":"high""#).model, "129 bytes: dropped")
        XCTAssertNil(try row(#","model":"\#(long)x","effort":"high""#).effort, "and its effort with it")
        XCTAssertEqual(try row(#","model":"  Sonnet 4.5 ""#).model, "Sonnet 4.5")
        for bad in [#""""#, #""   ""#, #""Opus\u00e9""#, #""Opus\n4""#, #""Opus\u0007""#, #""Op\u202eus""#, "7", "true", "null"] {
            XCTAssertNil(try row(",\"model\":\(bad)").model, bad)
        }
        // The effort: the five words, only with a model.
        for e in ["low", "medium", "high", "xhigh", "max"] { XCTAssertEqual(try row(#","model":"M","effort":"\#(e)""#).effort, e) }
        for bad in [#""ultra""#, #""High""#, #""""#, "3"] { XCTAssertNil(try row(#","model":"M","effort":"# + bad).effort, bad) }
        XCTAssertNil(try row(#","effort":"high""#).effort, "no model, no effort")
        // The activity: a positive integer.
        for bad in ["0", "-60", "1.5", "true", #""1784995200""#, "null", "[1]"] { XCTAssertNil(try row(",\"activity\":\(bad)").activity, bad) }
        XCTAssertEqual(try row(#","activity":60"#).activity, 60)
    }

    /// A row whose keys vanish (an older Mac, the fork-list fallback) drops its badges and age:
    /// it is the bare row again, never the stale one.
    @MainActor func testVanishedKeysDropBadges() throws {
        let store = UserDefaults(suiteName: "SessionMetaTests.vanish")!
        store.removePersistentDomain(forName: "SessionMetaTests.vanish")
        let now = Date(timeIntervalSince1970: 1_784_995_500)
        let with = try row(#","state":"idle","model":"Opus 4.7","effort":"high","activity":1784995200"#)
        let without = try row(#","state":"idle""#)
        XCTAssertEqual(with.rowAccessibility(RowDetails(), now: now), "a, Opus 4.7, high effort, Idle, active 5 minutes ago")
        XCTAssertEqual(without, DchSession(name: "a", alias: nil, state: "idle"))
        XCTAssertEqual(without.badgeFolds(RowDetails()), [[]])
        XCTAssertNil(without.age(RowDetails(), now: now))
        XCTAssertEqual(without.rowAccessibility(RowDetails(), now: now), "a, Idle")
        func ideal(_ s: DchSession) -> CGFloat {
            UIHostingController(rootView: SessionRow(session: s).fixedSize().defaultAppStorage(store))
                .sizeThatFits(in: CGSize(width: 1000, height: 1000)).width
        }
        XCTAssertGreaterThan(ideal(with), ideal(without), "the badges draw, then go")
    }

    /// Line 1 folds as on the Mac: both badges, the effort alone, none; a hidden model leaves the effort.
    func testBadgeFolds() {
        let s = DchSession(name: "a", alias: nil, model: "Opus 4.7", effort: "max")
        typealias B = DchSession.Badge
        XCTAssertEqual(s.badgeFolds(RowDetails()), [[B.model("Opus 4.7"), .effort("max")], [.effort("max")], []])
        XCTAssertEqual(s.badgeFolds(with { $0.model = false }), [[B.effort("max")], []])
        XCTAssertEqual(s.badgeFolds(with { $0.effort = false }), [[B.model("Opus 4.7")], []])
        XCTAssertEqual(s.badgeFolds(with { $0.model = false; $0.effort = false }), [[]])
        XCTAssertEqual(DchSession(name: "a", alias: nil, model: "M").badgeFolds(RowDetails()), [[B.model("M")], []])
    }

    /// Each fold is narrower, and a long model is cut, so the name keeps its room.
    @MainActor func testBadgeFoldsNarrowAndModelIsCut() {
        func width(_ b: [DchSession.Badge]) -> CGFloat {
            UIHostingController(rootView: SessionRow.badges(b)).sizeThatFits(in: CGSize(width: 1000, height: 100)).width
        }
        let folds = DchSession(name: "a", alias: nil, model: "Opus 4.7", effort: "medium").badgeFolds(RowDetails())
        XCTAssertGreaterThan(width(folds[0]), width(folds[1]))
        XCTAssertGreaterThan(width(folds[1]), width(folds[2]))
        XCTAssertEqual(width([.model(String(repeating: "m", count: 128))]), width([.model(String(repeating: "m", count: 17))]),
                       "a long model is cut to 16 characters")
        XCTAssertGreaterThan(width([.model(String(repeating: "m", count: 16))]), width([.model(String(repeating: "m", count: 15))]),
                             "16 stay whole")
    }

    /// The Mac's age: whole units rounded down, at each boundary; "now" under a minute and for a future stamp.
    func testAgeFormat() {
        let cases: [(TimeInterval, String, String)] = [
            (-30, "now", "active just now"), (.nan, "now", "active just now"), (0, "now", "active just now"), (59, "now", "active just now"),
            (60, "1m", "active 1 minute ago"), (300, "5m", "active 5 minutes ago"), (3599, "59m", "active 59 minutes ago"),
            (3600, "1h", "active 1 hour ago"), (86399, "23h", "active 23 hours ago"), (86400, "1d", "active 1 day ago"),
            (365 * 86400 - 1, "364d", "active 364 days ago"), (365 * 86400, "1y", "active 1 year ago"), (1e300, "99y", "active 99 years ago")]
        for (t, short, spoken) in cases {
            XCTAssertEqual(DchSession.age(t).short, short, "\(t)")
            XCTAssertEqual(DchSession.age(t).spoken, spoken, "\(t)")
        }
        let now = Date(timeIntervalSince1970: 7200)
        let s = DchSession(name: "a", alias: nil, state: "idle", activity: 3600)
        XCTAssertEqual(s.age(RowDetails(), now: now)?.short, "1h")
        XCTAssertNil(s.age(with { $0.age = false }, now: now), "Age off")
        var working = s; working.state = "working"
        XCTAssertNil(working.age(RowDetails(), now: now), "none on a working row, as on the Mac")
    }

    /// #1532 QA: the age came from TimelineView's date, the start of the minute, so 300 s ago read "4m"
    /// for most of a minute. The row draws at the real clock: 300 s before it is "5m" at any tick.
    func testRowAgeIsFromTheRealNow() {
        let clock = Date(timeIntervalSince1970: 1_784_995_259)   // 59 s into a minute
        let s = DchSession(name: "a", alias: nil, state: "idle", activity: 1_784_995_259 - 300)
        for tick in [1_784_995_200, 1_784_995_140, 1_784_995_259] as [TimeInterval] {
            let at = SessionRow.drawDate(tick: Date(timeIntervalSince1970: tick), clock: clock)
            XCTAssertEqual(s.age(RowDetails(), now: at)?.short, "5m", "tick \(tick)")
            XCTAssertEqual(s.rowAccessibility(RowDetails(), now: at), "a, Idle, active 5 minutes ago")
        }
    }

    /// VoiceOver reads the new parts in the toggles' order, and only those toggled on.
    func testRowAccessibilityModelEffortAge() {
        let s = DchSession(name: "a", alias: "Docs", state: "blocked", agents: 1, meta: full, model: "Sonnet 4.5", effort: "low", activity: 0)
        let now = Date(timeIntervalSince1970: 172_800)
        XCTAssertEqual(s.rowAccessibility(RowDetails(), now: now),
                       "Docs, Sonnet 4.5, low effort, Needs input, 1 agent, 75 merged pull requests, 1 open pull request, active 2 days ago")
        XCTAssertEqual(s.rowAccessibility(with { $0.model = false; $0.age = false }, now: now),
                       "Docs, low effort, Needs input, 1 agent, 75 merged pull requests, 1 open pull request")
        XCTAssertEqual(s.rowAccessibility(with { $0.effort = false; $0.agents = false; $0.merged = false; $0.openPRs = false }, now: now),
                       "Docs, Sonnet 4.5, Needs input, active 2 days ago")
    }

    /// Each new toggle hides its piece: Model and Effort narrow line 1, Age takes line 2 away.
    @MainActor func testModelEffortAgeToggles() {
        let store = UserDefaults(suiteName: "SessionMetaTests.badgeToggles")!
        store.removePersistentDomain(forName: "SessionMetaTests.badgeToggles")
        defer { store.removePersistentDomain(forName: "SessionMetaTests.badgeToggles") }
        store.set(false, forKey: RowDetails.Key.state)
        let s = DchSession(name: "a", alias: "Docs", state: "idle", model: "Opus 4.7", effort: "high",
                           activity: Int(Date().timeIntervalSince1970) - 600)
        func size() -> CGSize {
            UIHostingController(rootView: SessionRow(session: s).fixedSize().defaultAppStorage(store))
                .sizeThatFits(in: CGSize(width: 1000, height: 1000))
        }
        let all = size()
        store.set(false, forKey: RowDetails.Key.effort)
        let modelOnly = size()
        XCTAssertLessThan(modelOnly.width, all.width, "Effort off")
        store.set(false, forKey: RowDetails.Key.model)
        XCTAssertLessThan(size().width, modelOnly.width, "Model off")
        store.set(false, forKey: RowDetails.Key.age)
        XCTAssertLessThan(size().height, all.height, "Age off: no line 2 left")
    }

    /// #1547: the agents chip draws the robot, not the emoji: the geometry fills its box inside the stroke inset, the chip is
    /// glyph + 3 + count + padding wide (the emoji chip is not), and no taller than the emoji chip was.
    @MainActor func testAgentsChipDrawsRobotNotEmoji() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let g = RobotGeometry.paths(in: box)
        XCTAssertFalse(g.line.isEmpty); XCTAssertFalse(g.fill.isEmpty)
        let inset = box.insetBy(dx: -box.width * RobotGeometry.strokeFraction / 2, dy: -box.height * RobotGeometry.strokeFraction / 2)
        XCTAssertTrue(inset.contains(g.line.boundingRect) && inset.contains(g.fill.boundingRect), "inside the box, stroke included")
        XCTAssertGreaterThan(g.line.boundingRect.width, 80)
        func size<V: View>(_ v: V) -> CGSize { UIHostingController(rootView: v).sizeThatFits(in: CGSize(width: 1000, height: 100)) }
        let font = Font.caption2.monospaced().weight(.medium)
        let digit = size(Text(verbatim: "3").font(font)).width
        let chip = size(SessionRow.agentsCapsule(3))
        XCTAssertEqual(chip.width, size(RobotGlyph()).width + 3 + digit + 10, accuracy: 0.5)
        let emoji = size(Text(verbatim: "\u{1F916} 3").font(font).padding(.horizontal, 5).padding(.vertical, 1))
        XCTAssertNotEqual(chip.width, emoji.width, accuracy: 0.5)
        XCTAssertLessThanOrEqual(chip.height, emoji.height + 0.01, "the chip keeps the emoji chip's height")
    }

    /// #1547: the glyph's side follows Dynamic Type.
    @MainActor func testRobotGlyphScalesWithDynamicType() {
        func side(_ t: DynamicTypeSize) -> CGFloat {
            UIHostingController(rootView: RobotGlyph().environment(\.dynamicTypeSize, t)).sizeThatFits(in: CGSize(width: 1000, height: 1000)).width
        }
        XCTAssertEqual(side(.large), 11 * RobotGeometry.sideFactor, accuracy: 0.5)
        XCTAssertGreaterThan(side(.accessibility5), side(.large) * 1.5)
    }

    /// #1554: the glyph keeps its share of the chip's height at accessibility sizes.
    @MainActor func testRobotGlyphKeepsProportionOfChip() {
        func ratio(_ t: DynamicTypeSize) -> CGFloat {
            let big = CGSize(width: 2000, height: 2000)
            let g = UIHostingController(rootView: RobotGlyph().environment(\.dynamicTypeSize, t)).sizeThatFits(in: big).height
            let c = UIHostingController(rootView: SessionRow.agentsCapsule(2).environment(\.dynamicTypeSize, t)).sizeThatFits(in: big).height
            return g / c
        }
        XCTAssertEqual(ratio(.accessibility5), ratio(.large), accuracy: 0.03)
    }
}
