import XCTest
import UIKit
import SwiftTerm
@testable import Prosper

/// A tap on a URL the terminal printed opens it in the browser: an OSC 8 hyperlink or
/// plain http(s) text, wrapped rows joined. It wins over a mouse-mode app's click and
/// over raising the keyboard. Nothing but http(s) ever opens.
@MainActor
final class LinkTapTests: XCTestCase {

    private func makeVC() async throws -> (TerminalHostVC, TerminalView, SpyStream, Box) {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport, session: DchSession(name: "t", alias: nil))
        let vc = TerminalHostVC(conn: conn, handle: TermHandle())
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        vc.view.layoutIfNeeded()
        vc.startIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        transport.stream.emit("$ ")
        try await Task.sleep(nanoseconds: 50_000_000)
        let opened = Box()
        vc.openURL = { opened.urls.append($0) }
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        return (vc, tv, transport.stream, opened)
    }

    final class Box { var urls: [URL] = [] }

    /// Center of the screen cell at `row`, `col`, in `tv` coordinates.
    private func point(_ tv: TerminalView, row: Int, col: Int) -> CGPoint {
        let cell = tv.caretFrame.size
        return CGPoint(x: (CGFloat(col) + 0.5) * cell.width,
                       y: (CGFloat(tv.getTerminal().buffer.yDisp + row) + 0.5) * cell.height)
    }

    /// Column where `needle` starts on screen row `row`.
    private func col(of needle: String, row: Int, _ tv: TerminalView) throws -> Int {
        let line = try XCTUnwrap(tv.getTerminal().getLine(row: row)?.translateToString(trimRight: true))
        let r = try XCTUnwrap(line.range(of: needle), "\(needle) not on row \(row): \(line)")
        return line.distance(from: line.startIndex, to: r.lowerBound)
    }

    func testTapInsideAPlainURLOpensItOutsideDoesNot() async throws {
        let (vc, tv, _, _) = try await makeVC()
        tv.feed(text: "\u{1b}[2J\u{1b}[Hsee https://example.com/a. (https://example.com/b) end\r\n")
        let a = try col(of: "https://example.com/a", row: 0, tv)
        let b = try col(of: "https://example.com/b", row: 0, tv)

        XCTAssertEqual(vc.link(at: point(tv, row: 0, col: a))?.absoluteString, "https://example.com/a")
        XCTAssertEqual(vc.link(at: point(tv, row: 0, col: a + 20))?.absoluteString, "https://example.com/a")
        XCTAssertNil(vc.link(at: point(tv, row: 0, col: a + 21)), "the trailing period is not the link")
        XCTAssertNil(vc.link(at: point(tv, row: 0, col: 1)), "plain text is not a link")
        XCTAssertEqual(vc.link(at: point(tv, row: 0, col: b + 5))?.absoluteString, "https://example.com/b",
                       "the closing parenthesis must not join the URL")
        XCTAssertNil(vc.link(at: point(tv, row: 0, col: b + 21)), "the closing parenthesis is not the link")
    }

    /// A URL longer than the row soft-wraps; a tap on either half opens the whole thing.
    func testAURLWrappedAcrossTwoRowsOpensWhole() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let cols = tv.getTerminal().cols
        let url = "https://example.com/apps/install/" + String(repeating: "p", count: 30)
        tv.feed(text: "\u{1b}[2J\u{1b}[H" + String(repeating: "x", count: cols - 20) + " " + url + "\r\n")
        let start = try col(of: "https://", row: 0, tv)

        XCTAssertEqual(vc.link(at: point(tv, row: 0, col: start + 2))?.absoluteString, url)
        XCTAssertEqual(vc.link(at: point(tv, row: 1, col: 3))?.absoluteString, url,
                       "the wrapped tail must open the full URL, not a fragment")
    }

    /// `text` padded with leading spaces so its last character lands on column `lastCol`.
    private func endingAt(_ lastCol: Int, _ text: String) -> String {
        String(repeating: " ", count: lastCol + 1 - text.count) + text
    }

    func testProseUnderAURLNearTheEdgeIsNotPartOfIt() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let cols = tv.getTerminal().cols
        // Ends 3 short of the edge: past SwiftTerm's cols − cols/5 join line, short of ours.
        tv.feed(text: "\u{1b}[2J\u{1b}[H" + endingAt(cols - 3, "see https://example.com/docs") + "\r\n  for details.\r\n")
        let c = try col(of: "https://", row: 0, tv)

        XCTAssertEqual(vc.link(at: point(tv, row: 0, col: c + 3))?.absoluteString, "https://example.com/docs")
        XCTAssertNil(vc.link(at: point(tv, row: 1, col: 3)), "the prose below is not the link")
    }

    func testStackedURLsOpenOneEach() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let cols = tv.getTerminal().cols
        // Near the edge (the first pair), and right at it, where the rows join and the
        // second "https://" has to split them.
        for last in [cols - 4, cols - 1] {
            tv.feed(text: "\u{1b}[2J\u{1b}[H" + endingAt(last, "https://example.com/pull/1") + "\r\n"
                    + endingAt(last, "https://example.com/pull/2") + "\r\n")
            let c = try col(of: "https://", row: 0, tv)
            XCTAssertEqual(vc.link(at: point(tv, row: 0, col: c + 3))?.absoluteString, "https://example.com/pull/1", "\(last)")
            XCTAssertEqual(vc.link(at: point(tv, row: 1, col: last))?.absoluteString, "https://example.com/pull/2", "\(last)")
            XCTAssertEqual(vc.link(at: point(tv, row: 1, col: c + 3))?.absoluteString, "https://example.com/pull/2", "\(last)")
        }
    }

    func testASoftWrappedURLStillJoinsAndStopsAtItsEnd() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let cols = tv.getTerminal().cols
        let url = "https://example.com/" + String(repeating: "s", count: cols)
        tv.feed(text: "\u{1b}[2J\u{1b}[H" + url + " ok\r\n  next\r\n")
        XCTAssertTrue(tv.getTerminal().getLine(row: 1)?.isWrapped ?? false, "precondition: a soft wrap")

        XCTAssertEqual(vc.link(at: point(tv, row: 0, col: 3))?.absoluteString, url)
        XCTAssertEqual(vc.link(at: point(tv, row: 1, col: 2))?.absoluteString, url)
        XCTAssertNil(vc.link(at: point(tv, row: 2, col: 3)))
    }

    func testAWideCharWrappedFromTheLastColumnKeepsTheURLWhole() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let t = tv.getTerminal()
        let url = "https://example.com/" + String(repeating: "a", count: t.cols - 21) + "日本/x"
        tv.feed(text: "\u{1b}[2J\u{1b}[H" + url + " end\r\n")
        XCTAssertTrue(t.getLine(row: 1)?.isWrapped ?? false, "precondition: a soft wrap")
        XCTAssertEqual(t.getLine(row: 0)?[t.cols - 1].getCharacter(), "\0", "precondition: 日 left the last cell empty")

        let want = URL(string: url)?.absoluteString
        XCTAssertEqual(vc.link(at: point(tv, row: 0, col: 3))?.absoluteString, want)
        XCTAssertEqual(vc.link(at: point(tv, row: 1, col: 1))?.absoluteString, want, "the wide char's half of the URL")
    }

    private func span(_ rows: [[Character?]], wrapped: Set<Int> = [], row: Int, col: Int)
        -> (url: String, start: (row: Int, col: Int), end: (row: Int, col: Int))? {
        TerminalMath.webLinkSpan(row: row, col: col, cols: rows[0].count) { i in
            rows.indices.contains(i) ? (rows[i], wrapped.contains(i)) : nil
        }
    }

    func testAWrappedWideCharSpanEndsAfterIt() {
        let rows: [[Character?]] = [Array("https://example.com/aa") + ["\0"], ["日", nil, "本", nil, "/", "x", " ", "e"]]
        for (row, col) in [(0, 3), (1, 0), (1, 3)] {
            let s = span(rows, wrapped: [1], row: row, col: col)
            XCTAssertEqual(s?.url, "https://example.com/aa日本/x", "\(row),\(col)")
            XCTAssertTrue(s.map { $0.start == (0, 0) && $0.end == (1, 6) } == true, "\(row),\(col)")
        }
    }

    func testARealSpaceBeforeASoftWrapStillEndsTheURL() {
        let rows: [[Character?]] = [Array("see https://example.com/a "), Array("bcd and more")]
        XCTAssertEqual(span(rows, wrapped: [1], row: 0, col: 6)?.url, "https://example.com/a")
        XCTAssertNil(span(rows, wrapped: [1], row: 1, col: 1), "the next row's word is not the link")
    }

    func testTheSecondHalfOfAWideCharEndingAURLOpensIt() {
        let rows: [[Character?]] = [Array("https://example.com/日") + [nil] + Array(" end")]
        XCTAssertEqual(span(rows, row: 0, col: 21)?.url, "https://example.com/日")
        XCTAssertTrue(span(rows, row: 0, col: 21).map { $0.end == (0, 22) } == true, "the end is past the whole glyph")
    }

    func testATrailingCommaIsNotTheLink() {
        XCTAssertEqual(span([Array("https://example.com/a, b")], row: 0, col: 4)?.url, "https://example.com/a")
        XCTAssertNil(span([Array("https://example.com/a, b")], row: 0, col: 21))
    }

    func testAHardWrapAtTheEdgeStillJoins() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let cols = tv.getTerminal().cols
        // Claude Code's way: the URL broken at the last column (or one short), and the rest
        // on the next row under the same indent.
        for last in [cols - 1, cols - 2] {
            let head = "https://example.com/apps/" + String(repeating: "h", count: last + 1 - 27)
            let url = head + "/installations/new"
            tv.feed(text: "\u{1b}[2J\u{1b}[H  " + head + "\r\n  /installations/new\r\n")
            XCTAssertFalse(tv.getTerminal().getLine(row: 1)?.isWrapped ?? true, "precondition: a hard wrap")

            XCTAssertEqual(vc.link(at: point(tv, row: 0, col: 4))?.absoluteString, url, "\(last)")
            XCTAssertEqual(vc.link(at: point(tv, row: 1, col: 5))?.absoluteString, url, "\(last)")
            XCTAssertNil(vc.link(at: point(tv, row: 1, col: 0)), "the indent is not the link")
        }
    }

    /// Under a row whose ink reaches the edge, the next row's first run joins as the URL's
    /// tail only when it looks like one: it carries / ? = & # % or an inner ".", or it is
    /// all the row's ink. The indent before it never counts, nor a sentence's last ".".
    func testOnlyAURLTailJoinsUnderARowAtTheEdge() {
        let head = "https://example.com/" + String(repeating: "h", count: 20)   // 40 columns, full
        let cases: [(lower: String, url: String)] = [
            (lower: "  /new?state=abc123", url: head + "/new?state=abc123"),
            (lower: "x=1&y=2 then more", url: head + "x=1&y=2"),
            (lower: "a.html and more", url: head + "a.html"),
            (lower: "  2/files then more", url: head + "2/files"),
            (lower: "  abc123", url: head + "abc123"),
            (lower: "Next step here", url: head),
            (lower: "  for details.", url: head),
            (lower: "Next. Then more", url: head),
            (lower: "Next.", url: head),
            (lower: "   ", url: head),
        ]
        for k in cases {
            XCTAssertEqual(span([Array(head), Array(k.lower)], row: 0, col: 3)?.url, k.url, k.lower)
        }
        XCTAssertNil(span([Array(head), Array("Next step here")], row: 1, col: 1), "the word is no link")
    }

    /// #1079: the cases table for a URL a program broke across two rows with a real newline,
    /// 40 columns. `up(indent, gap, end)` is the upper row: its URL ends `gap` columns short
    /// of the edge, on `end`. "join" opens the URL whole from either row; "keep" opens the
    /// upper half and the lower row's word is no link. "undecidable" rows can't be told
    /// from the screen alone; they pin the side chosen.
    func testSplitURLCasesTable() {
        func up(_ indent: Int, _ gap: Int, _ end: String = "") -> String {
            let s = String(repeating: " ", count: indent) + "https://example.com/"
            return (s + String(repeating: "h", count: 40 - gap - s.count - end.count) + end)
                .padding(toLength: 40, withPad: " ", startingAt: 0)
        }
        func url(_ u: String) -> String {
            String(u[u.range(of: "https")!.lowerBound...]).trimmingCharacters(in: .whitespaces)
        }
        let bullet = "⏺" + up(2, 0).dropFirst()
        let cases: [(name: String, upper: String, lower: String, tail: String?)] = [
            ("join: edge, path tail", up(2, 0), "  /installations/new", "/installations/new"),
            ("join: one short, path tail", up(2, 1), "  /installations/new", "/installations/new"),
            ("join: edge, hyphen, prose after", up(2, 0), "  my-page then more", "my-page"),
            ("join: edge, underscore, prose after", up(2, 0), "  file_name then more", "file_name"),
            ("join: edge, lone digit and a period", up(2, 0), "  2.", "2"),
            ("join: edge, lone lowercase id", up(2, 0), "  abc123", "abc123"),
            ("join: 3 short, lone path tail", up(2, 3), "  allations/new", "allations/new"),
            ("join: 4 short, starts with /, prose after", up(2, 4), "  /new?x=1 to finish", "/new?x=1"),
            ("join: 3 short, cut after =, plain tail", up(2, 3, "?state="), "  abc123 to continue", "abc123"),
            ("join: edge, cut after -, plain tail", up(2, 0, "-"), "  page for details", "page"),
            ("join: bullet row, tail under the text", bullet, "  /new", "/new"),
            ("join: edge, outdented, strong tail", up(4, 0), "/new?x=1", "/new?x=1"),
            ("undecidable, join: edge, a path word", up(2, 0), "  src/a.swift is next", "src/a.swift"),
            ("undecidable, join: edge, lone lowercase word", up(2, 0), "  thanks", "thanks"),
            ("keep: edge, capitalised lone word", up(2, 0), "  Thanks", nil),
            ("keep: edge, e.g.", up(2, 0), "  e.g. the docs", nil),
            ("keep: edge, a list item", up(2, 0), "  - next item", nil),
            ("keep: edge, a bullet glyph", up(2, 0), "⏺ Done", nil),
            ("keep: edge, a box rule", up(2, 0), "│ boxed", nil),
            ("keep: 3 short, path word, prose after", up(2, 3), "  src/a.swift is next", nil),
            ("keep: 3 short, lone plain word", up(2, 3), "  abc123", nil),
            ("keep: 5 short, path tail", up(2, 5), "  /new?x=1", nil),
            ("keep: edge, outdented lone word", up(4, 0), "  abc123", nil),
            ("keep: 3 short, outdented path", up(4, 3), "a/b", nil),
            ("keep: edge, cut after =, outdented word", up(4, 0, "?a="), "abc123", nil),
            ("undecidable, keep: edge, plain piece, prose after", up(2, 0, "1"), "  2 for details", nil),
            ("undecidable, keep: edge, lone word and a period", up(2, 0), "  today.", nil),
        ]
        for k in cases {
            let rows = [Array(k.upper), Array(k.lower)].map { $0.map(Optional.some) }
            let want = url(k.upper) + (k.tail ?? "")
            let a = k.lower.firstIndex(where: { $0 != " " }).map { k.lower.distance(from: k.lower.startIndex, to: $0) } ?? 0
            XCTAssertEqual(span(rows, row: 0, col: 6)?.url, want, k.name)
            XCTAssertEqual(span(rows, row: 1, col: a)?.url, k.tail == nil ? nil : want, k.name)
        }
    }

    /// #1079 live: a program wrapping 3 columns short of the edge, Claude Code's indent.
    func testAHardWrapAFewColumnsShortJoinsAURLTail() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let cols = tv.getTerminal().cols
        let head = "https://example.com/apps/" + String(repeating: "h", count: cols - 30)   // ends at cols − 4
        tv.feed(text: "\u{1b}[2J\u{1b}[H  " + head + "\r\n  allations/new\r\n  Next step here\r\n")
        XCTAssertFalse(tv.getTerminal().getLine(row: 1)?.isWrapped ?? true, "precondition: a hard wrap")

        XCTAssertEqual(vc.link(at: point(tv, row: 0, col: 4))?.absoluteString, head + "allations/new")
        XCTAssertEqual(vc.link(at: point(tv, row: 1, col: 4))?.absoluteString, head + "allations/new")
        XCTAssertNil(vc.link(at: point(tv, row: 2, col: 3)), "the prose below is not the link")
    }

    func testAnOSC8HyperlinkOpensItsTarget() async throws {
        let (vc, tv, _, _) = try await makeVC()
        tv.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}]8;;https://example.com/osc\u{1b}\\click here\u{1b}]8;;\u{1b}\\ "
                + "\u{1b}]8;;javascript:alert(1)\u{1b}\\evil\u{1b}]8;;\u{1b}\\\r\n")

        XCTAssertEqual(vc.link(at: point(tv, row: 0, col: 2))?.absoluteString, "https://example.com/osc")
        XCTAssertNil(vc.link(at: point(tv, row: 0, col: 12)), "a javascript: hyperlink must never open")
    }

    func testOnlyHTTPAndHTTPSOpen() {
        XCTAssertNotNil(TerminalHostVC.webURL("http://example.com"))
        XCTAssertNotNil(TerminalHostVC.webURL("HTTPS://example.com/x?y=1"))
        for s in ["file:///etc/hosts", "javascript:alert(1)", "ssh://example.com", "myapp://open",
                  "mailto:a@example.com", "ftp://example.com", "https://", "example.com", ""] {
            XCTAssertNil(TerminalHostVC.webURL(s), s)
        }
        XCTAssertNil(TerminalHostVC.webURL(nil))
    }

    /// A file: URL on screen is found by SwiftTerm but must not open from a tap.
    func testAFileURLOnScreenIsIgnored() async throws {
        let (vc, tv, _, _) = try await makeVC()
        tv.feed(text: "\u{1b}[2J\u{1b}[Hfile:///tmp/report.txt\r\n")
        XCTAssertNil(vc.link(at: point(tv, row: 0, col: 4)))
    }

    /// Claude Code runs with mouse mode on. A tap on a link opens it and sends no click;
    /// a tap beside it still goes out as the click, exactly as before.
    func testLinkWinsOverAMouseModeClick() async throws {
        let (vc, tv, spy, opened) = try await makeVC()
        tv.feed(text: "\u{1b}[?1000h\u{1b}[2J\u{1b}[Hhttps://example.com/new\r\nplain text\u{1b}[12;1H")
        XCTAssertNotEqual(tv.getTerminal().mouseMode, .off, "precondition: mouse mode is on")
        let before = spy.sent.count

        vc.tap(at: point(tv, row: 0, col: 3))
        XCTAssertEqual(opened.urls.map(\.absoluteString), ["https://example.com/new"])
        XCTAssertEqual(spy.sent.count, before, "the remote app must not see a click on a link")

        vc.tap(at: point(tv, row: 1, col: 3))
        XCTAssertEqual(opened.urls.count, 1)
        XCTAssertGreaterThan(spy.sent.count, before, "a tap off the link is still the mouse click")
    }

    /// The same on the caret row, where a tap would otherwise raise the keyboard.
    func testLinkWinsOnTheInputRow() async throws {
        let (vc, tv, _, opened) = try await makeVC()
        tv.feed(text: "\u{1b}[2J\u{1b}[H$ open https://example.com/here")
        let c = try col(of: "https://", row: 0, tv)

        vc.tap(at: point(tv, row: 0, col: c + 1))
        XCTAssertEqual(opened.urls.map(\.absoluteString), ["https://example.com/here"])
    }
}
