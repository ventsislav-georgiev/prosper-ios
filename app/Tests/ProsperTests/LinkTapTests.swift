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
