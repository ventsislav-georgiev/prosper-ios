import XCTest
@testable import Prosper

/// The list row's PRs and tasks (the Mac's `meta`), decoded and drawn like Agent Island.
final class SessionMetaTests: XCTestCase {

    private func meta(_ json: String) -> SessionMeta? {
        SessionMeta(json: try! JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    private func pr(_ repo: String, _ num: Int?) -> SessionMeta.PR {
        .init(url: nil, repo: repo, num: num, title: "")
    }

    func testDecodeFull() {
        let m = meta(#"{"tasks":{"done":3,"total":7,"in_progress":1,"queued":2},"prs":{"open":[{"url":"https://github.com/o/prosper/pull/12","repo":"o/prosper","num":12,"title":"Fix it"}],"merged":4}}"#)
        XCTAssertEqual(m, SessionMeta(done: 3, total: 7, inProgress: 1, queued: 2,
                                      open: [.init(url: URL(string: "https://github.com/o/prosper/pull/12"),
                                                   repo: "o/prosper", num: 12, title: "Fix it")], merged: 4))
    }

    /// Absent or non-object meta is nil, so the row draws as before.
    func testDecodeAbsent() {
        XCTAssertNil(SessionMeta(json: nil))
        XCTAssertNil(SessionMeta(json: "x"))
        XCTAssertNil(SessionMeta(json: [1]))
    }

    func testDecodePartial() {
        let m = meta(#"{"tasks":{"queued":2},"prs":{"open":[{"repo":"o/r","url":"https://github.com/o/r/pull/1"}]}}"#)!
        XCTAssertEqual(m.queued, 2)
        XCTAssertNil(m.done); XCTAssertNil(m.total); XCTAssertNil(m.merged)
        XCTAssertEqual(m.open, [.init(url: URL(string: "https://github.com/o/r/pull/1"), repo: "o/r", num: nil, title: "")])
    }

    /// Wrong types and negative numbers drop only that field (or that PR); a meta left with nothing is nil.
    func testDecodeGarbage() {
        let m = meta(#"{"tasks":{"done":"3","total":-1,"in_progress":true,"queued":1.5},"prs":{"open":[1,"x",{"url":5,"repo":"o/r","num":-7,"title":["t"]},{"num":3},{"repo":"o/q","num":3,"url":"http://github.com/o/q/pull/3"},{"repo":"o/z","url":"https://evil.example/o/z/pull/1"}],"merged":"many"}}"#)!
        XCTAssertEqual(m, SessionMeta(open: [pr("o/r", nil), pr("o/q", 3), pr("o/z", nil)]))
        XCTAssertNil(meta(#"{"tasks":[],"prs":{"open":{"url":"x"},"merged":-2}}"#))
    }

    /// A meta with nothing to draw is nil, so the row gains no empty gap.
    func testNothingToShowIsNil() {
        for j in [#"{}"#, #"{"prs":{"open":[]}}"#, #"{"prs":{"open":[],"merged":0}}"#, #"{"tasks":{"done":0,"total":0}}"#] {
            XCTAssertNil(meta(j), j)
        }
        XCTAssertNotNil(meta(#"{"prs":{"open":[],"merged":4}}"#))
        XCTAssertNotNil(meta(#"{"tasks":{"queued":2}}"#))
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
        XCTAssertEqual(SessionMeta(done: 100_000, total: 100_000).taskLine, "99999+/99999+ done")
        XCTAssertEqual(SessionMeta(merged: 1_000_000).mergedLabel, "99999+ merged")
        XCTAssertEqual(meta("{\"tasks\":{\"done\":\(Int.max),\"total\":\(Int.max)}}")?.taskLine, "99999+/99999+ done", "Int.max")
    }

    func testTaskLine() {
        XCTAssertEqual(SessionMeta(done: 22, total: 26, inProgress: 2, queued: 2).taskLine,
                       "22/26 done · 2 in progress · 2 queued")
        XCTAssertEqual(SessionMeta(done: 22, total: 26, inProgress: 0).taskLine, "22/26 done")
        XCTAssertEqual(SessionMeta(inProgress: 2, queued: 2).taskLine, "2 in progress · 2 queued")
        XCTAssertEqual(SessionMeta(total: 5, queued: 1).taskLine, "0/5 done · 1 queued")
        XCTAssertEqual(SessionMeta(done: 7, total: 3).taskLine, "7/3 done", "done > total as is")
        XCTAssertNil(SessionMeta(done: 3).taskLine)
        XCTAssertNil(SessionMeta().taskLine)
    }

    func testChipsMoreAndMerged() {
        XCTAssertEqual(pr("o/prosper", 12).chip, "prosper#12")
        XCTAssertEqual(pr("o/prosper", nil).chip, "prosper")
        XCTAssertEqual(pr("o/averyverylongrepo", 1).chip, "averyverylongrepo#1", "full label unless cut")
        XCTAssertEqual(pr("o/averyverylongrepo", 1).chip(maxRepo: SessionMeta.maxRepo), "averyverylongrepo#1", "17 fits")
        XCTAssertEqual(pr("o/nineteencharsrepo12", 1).chip(maxRepo: SessionMeta.maxRepo), "nineteencharsrepo…#1", "19 cut to 18")
        XCTAssertEqual(pr("o/averyverylongrepo", 1).chip(maxRepo: SessionMeta.phoneRepo), "averyverylo…#1", "cut to 12")
        XCTAssertEqual(SessionMeta(merged: 4).mergedLabel, "4 merged")
        XCTAssertNil(SessionMeta(merged: 0).mergedLabel)
    }

    func testAccessibilityLabel() {
        let five = SessionMeta(open: [pr("o/a", 1), pr("o/b", 2), pr("o/c", 3), pr("o/d", 4), pr("o/e", nil)])
        XCTAssertEqual(five.prAccessibility, "open pull requests a#1, b#2, c#3 and 2 more")
        XCTAssertEqual(SessionMeta(open: [pr("o/a", 1)]).prAccessibility, "open pull requests a#1")
        XCTAssertNil(SessionMeta(merged: 3).prAccessibility)
    }

    /// Junk entries never hide valid PRs behind the cap, and the cap still holds.
    func testCapAfterFilter() {
        let valid = { (n: Int) in #"{"repo":"o/r","num":\#(n)}"# }
        let junk = Array(repeating: "1", count: 50) + (1...3).map(valid)
        XCTAssertEqual(meta(#"{"prs":{"open":["# + junk.joined(separator: ",") + "]}}")?.open.count, 3)
        XCTAssertEqual(meta(#"{"prs":{"open":["# + (1...60).map(valid).joined(separator: ",") + "]}}")?.open.count, 50)
    }

    func testQueuedZeroLeftOut() {
        XCTAssertEqual(SessionMeta(done: 1, total: 2, queued: 0).taskLine, "1/2 done")
        XCTAssertNil(SessionMeta(queued: 0).taskLine)
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

    private let full = SessionMeta(done: 41, total: 68, inProgress: 8, queued: 19,
                                   open: [.init(url: nil, repo: "o/repo", num: 12, title: "")], merged: 75)

    private func with(_ change: (inout RowDetails) -> Void) -> RowDetails {
        var d = RowDetails(); change(&d); return d
    }

    /// Agents, Open PRs and Merged on; Tasks done, In progress and Queued off, so a
    /// default row has no task summary.
    func testRowDetailsDefaults() {
        XCTAssertEqual(RowDetails(), RowDetails(agents: true, openPRs: true, merged: true,
                                                tasksDone: false, inProgress: false, queued: false))
        XCTAssertNil(full.summary(RowDetails()))
    }

    func testSummaryFollowsToggles() {
        XCTAssertEqual(full.summary(.all), "41/68 done · 8 in progress · 19 queued")
        XCTAssertEqual(full.summary(with { $0.tasksDone = true }), "41/68 done")
        XCTAssertEqual(full.summary(with { $0.inProgress = true }), "8 in progress")
        XCTAssertEqual(full.summary(with { $0.queued = true }), "19 queued")
        XCTAssertEqual(full.summary(with { $0.tasksDone = true; $0.queued = true }), "41/68 done · 19 queued")
        XCTAssertNil(SessionMeta(done: 1, total: 2, queued: 0).summary(with { $0.queued = true }), "a zero part is dropped")
        XCTAssertNil(SessionMeta(inProgress: 3).summary(with { $0.tasksDone = true }), "an unknown part is dropped")
        XCTAssertEqual(SessionMeta(inProgress: 100_000).summary(.all), "99999+ in progress")
    }

    func testPendingWording() {
        XCTAssertEqual(SessionMeta.moreLabel(1), "+1 pending PR")
        XCTAssertEqual(SessionMeta.moreLabel(5), "+5 pending PRs")
    }

    /// Up to 3 chips, widest first: each count with full labels, repos cut to 18, beside
    /// "+N pending PRs", then a bare "+N", then repos cut to 12, before fewer chips;
    /// none last.
    func testPRLinesWidestFirst() {
        let long = "o/" + String(repeating: "r", count: 20)
        let m = SessionMeta(open: [pr("o/a", 1), pr(long, 2), pr("o/c", 3), pr("o/d", 4), pr("o/e", 5)], merged: 7)
        let full = String(repeating: "r", count: 20) + "#2", cut = String(repeating: "r", count: 17) + "…#2"
        let phone = String(repeating: "r", count: 11) + "…#2"
        XCTAssertEqual(m.prLines(RowDetails()), [
            .init(chips: ["a#1", full, "c#3"], more: "+2 pending PRs", merged: "7 merged"),
            .init(chips: ["a#1", cut, "c#3"], more: "+2 pending PRs", merged: "7 merged"),
            .init(chips: ["a#1", full, "c#3"], more: "+2", merged: "7 merged"),
            .init(chips: ["a#1", cut, "c#3"], more: "+2", merged: "7 merged"),
            .init(chips: ["a#1", phone, "c#3"], more: "+2", merged: "7 merged"),
            .init(chips: ["a#1", full], more: "+3 pending PRs", merged: "7 merged"),
            .init(chips: ["a#1", cut], more: "+3 pending PRs", merged: "7 merged"),
            .init(chips: ["a#1", full], more: "+3", merged: "7 merged"),
            .init(chips: ["a#1", cut], more: "+3", merged: "7 merged"),
            .init(chips: ["a#1", phone], more: "+3", merged: "7 merged"),
            .init(chips: ["a#1"], more: "+4 pending PRs", merged: "7 merged"),
            .init(chips: ["a#1"], more: "+4", merged: "7 merged"),
            .init(chips: [], more: "+5 pending PRs", merged: "7 merged"),
        ])
        XCTAssertEqual(SessionMeta(open: [pr("o/a", 1)]).prLines(RowDetails()),
                       [.init(chips: ["a#1"], more: nil, merged: nil), .init(chips: [], more: "+1 pending PR", merged: nil)])
        // No pending chip (k == n): full, cut to 18, cut to 12.
        XCTAssertEqual(SessionMeta(open: [pr(long, 2)]).prLines(RowDetails()).map(\.chips),
                       [[full], [cut], [phone], []])
    }

    /// The screenshot row: a 16-character chip, 5 more and 75 merged. The short "+5"
    /// keeps the chip before the line falls back to no chips.
    func testShortPendingKeepsChip() throws {
        let lines = SessionMeta(open: [pr("o/sample-code1", 370)] + (1...5).map { pr("o/r", $0) }, merged: 75).prLines(RowDetails())
        let short = try XCTUnwrap(lines.firstIndex(of: .init(chips: ["sample-code1#370"], more: "+5", merged: "75 merged")))
        let none = try XCTUnwrap(lines.firstIndex { $0.chips.isEmpty })
        XCTAssertLessThan(short, none)
        XCTAssertEqual(lines[none], .init(chips: [], more: "+6 pending PRs", merged: "75 merged"))
    }

    /// A 20-character chip: the 12-character cut beside "+5" comes before no chips.
    func testPhoneCutKeepsChip() throws {
        let lines = SessionMeta(open: [pr("o/sample-codebase1", 370)] + (1...5).map { pr("o/r", $0) }, merged: 75).prLines(RowDetails())
        let phone = try XCTUnwrap(lines.firstIndex(of: .init(chips: ["sample-code…#370"], more: "+5", merged: "75 merged")))
        XCTAssertLessThan(phone, try XCTUnwrap(lines.firstIndex { $0.chips.isEmpty }))
        XCTAssertEqual(lines[phone - 1], .init(chips: ["sample-codebase1#370"], more: "+5", merged: "75 merged"),
                       "the 18 cut leaves a 16-character repo whole, so it was deduped")
    }

    func testPRLineToggles() {
        XCTAssertEqual(full.prLines(with { $0.openPRs = false }), [.init(chips: [], more: nil, merged: "75 merged")])
        XCTAssertEqual(full.prLines(with { $0.merged = false }).first, .init(chips: ["repo#12"], more: nil, merged: nil))
        XCTAssertEqual(full.prLines(with { $0.openPRs = false; $0.merged = false }), [], "no line 3")
        XCTAssertEqual(SessionMeta(merged: 4).prLines(with { $0.merged = false }), [])
        XCTAssertEqual(SessionMeta(done: 1, total: 2).prLines(RowDetails()), [], "no PRs, no line 3")
    }

    /// #531: a blank title leaves no dangling dash.
    func testMenuLabel() {
        let p = { (t: String) in SessionMeta.PR(url: nil, repo: "o/tab", num: 2, title: t) }
        XCTAssertEqual(p("").menuLabel, "tab#2")
        XCTAssertEqual(p("   ").menuLabel, "tab#2")
        XCTAssertEqual(p(SessionMeta.plain("\u{202E}\n")).menuLabel, "tab#2", "blank after plain()")
        XCTAssertEqual(p("Fix it").menuLabel, "tab#2 — \u{2068}Fix it\u{2069}")
    }

    func testStateWords() {
        XCTAssertEqual(SessionStateStyle.allCases.map(\.label), ["Working", "Needs input", "Idle", "Done"])
        XCTAssertEqual(SessionStateStyle.allCases.map(\.glyph), ["\u{2733}\u{FE0E}", "!", "\u{25CF}", "\u{25CF}"])
        XCTAssertEqual(SessionStateStyle.agents(1), "+1 agent")
        XCTAssertEqual(SessionStateStyle.agents(4), "+4 agents")
        XCTAssertNil(SessionStateStyle.agents(0))
    }

    /// VoiceOver reads the title and state, then only what is toggled on.
    func testRowAccessibilityFollowsToggles() {
        let s = DchSession(name: "sec-1", alias: "Docs", state: "working", agents: 4, meta: full)
        XCTAssertEqual(s.rowAccessibility(RowDetails()),
                       "Docs, Working, 4 agents, sec-1, open pull requests repo#12, 75 merged")
        XCTAssertEqual(s.rowAccessibility(.all),
                       "Docs, Working, 4 agents, sec-1, 41/68 done · 8 in progress · 19 queued, open pull requests repo#12, 75 merged")
        XCTAssertEqual(s.rowAccessibility(RowDetails(agents: false, openPRs: false, merged: false)), "Docs, Working, sec-1")
        XCTAssertEqual(s.rowAccessibility(with { $0.agents = false; $0.queued = true }),
                       "Docs, Working, sec-1, 19 queued, open pull requests repo#12, 75 merged")
        XCTAssertEqual(DchSession(name: "a", alias: nil, agents: 1).rowAccessibility(RowDetails()), "a, 1 agent")
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
}
