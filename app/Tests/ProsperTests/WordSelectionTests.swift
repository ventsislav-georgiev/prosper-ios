import XCTest
import UIKit
import SwiftTerm
@testable import Prosper

@MainActor
final class WordSelectionTests: XCTestCase {

    // MARK: - Word rules

    private func cells(_ s: String) -> [Character?] { s.map { $0 } }

    func testAWordIsLettersDigitsUnderscoreDash() {
        let row = cells("ls my_file-2 now")
        XCTAssertEqual(TerminalMath.wordRange(row, at: 3), 3..<12)
        XCTAssertEqual(TerminalMath.wordRange(row, at: 11), 3..<12)
        XCTAssertEqual(TerminalMath.wordRange(row, at: 0), 0..<2)
        XCTAssertEqual(TerminalMath.wordRange(row, at: 15), 13..<16)
    }

    private func word(_ s: String, at col: Int) -> String? {
        TerminalMath.wordRange(cells(s), at: col).map { String(Array(s)[$0]) }
    }

    func testPathsAndURLPathsComeWhole() {
        let s = "open /usr/local/bin/run.sh; see https://example.com/a/b.html"
        XCTAssertEqual(word(s, at: 10), "/usr/local/bin/run.sh", "the path, without the `;`")
        XCTAssertEqual(word(s, at: 45), "//example.com/a/b.html", "`:` ends a word, as in SwiftTerm")
        XCTAssertEqual(word(s, at: 33), "https")
    }

    func testWhitespacePunctuationAndPastTheLineEndSelectNothing() {
        let row: [Character?] = ["a", " ", "$", "b", "\0", "\0"]
        XCTAssertNil(TerminalMath.wordRange(row, at: 1))
        XCTAssertNil(TerminalMath.wordRange(row, at: 2))
        XCTAssertNil(TerminalMath.wordRange(row, at: 4), "a never-written cell past the end")
        XCTAssertNil(TerminalMath.wordRange(row, at: 6))
        XCTAssertNil(TerminalMath.wordRange(row, at: -1))
        XCTAssertEqual(TerminalMath.wordRange(row, at: 3), 3..<4)
    }

    func testAWideCellJoinsItsWord() {
        let row: [Character?] = ["漢", nil, "字", nil, "x", " ", "日", nil]
        XCTAssertEqual(TerminalMath.wordRange(row, at: 0), 0..<5)
        XCTAssertEqual(TerminalMath.wordRange(row, at: 1), 0..<5, "the second half of a wide char")
        XCTAssertEqual(TerminalMath.wordRange(row, at: 3), 0..<5)
        XCTAssertEqual(TerminalMath.wordRange(row, at: 7), 6..<8, "a wide char at the line end")
    }

    // MARK: - Handle drag math

    func testAHandleLandsOnTheNearestColumnGap() {
        let cell = CGSize(width: 10, height: 20)
        let c = TerminalMath.handleCell(point: CGPoint(x: 34, y: 105), cell: cell, lines: 0...9, cols: 40)
        XCTAssertEqual(c.row, 5)
        XCTAssertEqual(c.col, 3)
        XCTAssertEqual(TerminalMath.handleCell(point: CGPoint(x: 36, y: 105), cell: cell, lines: 0...9, cols: 40).col, 4)
        let low = TerminalMath.handleCell(point: CGPoint(x: 999, y: 999), cell: cell, lines: 2...9, cols: 40)
        XCTAssertEqual(low.row, 9)
        XCTAssertEqual(low.col, 40, "the end handle can sit after the last column")
        let high = TerminalMath.handleCell(point: CGPoint(x: -5, y: -5), cell: cell, lines: 2...9, cols: 40)
        XCTAssertEqual(high.row, 2)
        XCTAssertEqual(high.col, 0)
    }

    func testDraggingAnEndPastTheOtherSwapsThem() {
        let s = (row: 3, col: 4), e = (row: 3, col: 9)
        var d = TerminalMath.dragSelection(start: s, end: e, movingStart: false, to: (3, 12))
        XCTAssertTrue(d.start == s && d.end == (3, 12) && !d.movingStart)
        d = TerminalMath.dragSelection(start: s, end: e, movingStart: false, to: (3, 1))
        XCTAssertTrue(d.start == (3, 1) && d.end == s && d.movingStart, "the end dragged before the start")
        d = TerminalMath.dragSelection(start: s, end: e, movingStart: true, to: (5, 0))
        XCTAssertTrue(d.start == e && d.end == (5, 0) && !d.movingStart, "the start dragged a line below the end")
        d = TerminalMath.dragSelection(start: s, end: e, movingStart: true, to: e)
        XCTAssertTrue(d.start == s && d.end == e && d.movingStart, "never shrinks to nothing")
    }

    // MARK: - On the terminal

    private func makeVC() async throws -> (TerminalHostVC, TerminalView, SpyStream, LinkBox) {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport, session: DchSession(name: "t", alias: nil))
        let vc = TerminalHostVC(conn: conn, handle: TermHandle())
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        vc.view.layoutIfNeeded()
        vc.startIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        transport.stream.emit("$ ")
        try await Task.sleep(nanoseconds: 50_000_000)
        let opened = LinkBox()
        vc.openURL = { opened.urls.append($0) }
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        return (vc, tv, transport.stream, opened)
    }

    final class LinkBox { var urls: [URL] = [] }

    private func point(_ tv: TerminalView, row: Int, col: Int, dx: CGFloat = 0.5) -> CGPoint {
        let cell = tv.caretFrame.size
        return CGPoint(x: (CGFloat(col) + dx) * cell.width,
                       y: (CGFloat(tv.getTerminal().buffer.yDisp + row) + 0.5) * cell.height)
    }

    private func feed(_ vc: TerminalHostVC, _ s: String) { vc.feed(ArraySlice(Array(s.utf8))) }

    private func selected(_ vc: TerminalHostVC, _ tv: TerminalView) -> String? {
        guard let s = vc.selection else { return nil }
        return tv.getTerminal().getText(start: Position(col: s.start.col, row: s.start.row),
                                        end: Position(col: s.end.col, row: s.end.row))
    }

    func testTheSingleTapWaitsForTheDoubleTap() async throws {
        let (vc, _, _, _) = try await makeVC()
        let single = try XCTUnwrap(vc.singleTap), double = try XCTUnwrap(vc.doubleTap)
        XCTAssertEqual(double.numberOfTapsRequired, 2)
        XCTAssertTrue(vc.gestureRecognizer(single, shouldRequireFailureOf: double))
        XCTAssertFalse(vc.gestureRecognizer(double, shouldRequireFailureOf: single))
    }

    func testADoubleTapInMouseModeSelectsLocallyAndSendsNothing() async throws {
        let (vc, tv, spy, opened) = try await makeVC()
        feed(vc, "\u{1b}[?1000h\u{1b}[2J\u{1b}[Hrun build_all now https://example.com/x\r\n\u{1b}[12;1H")
        XCTAssertNotEqual(tv.getTerminal().mouseMode, .off, "precondition: mouse mode is on")
        let before = spy.sent.count

        vc.selectWord(at: point(tv, row: 0, col: 6))
        XCTAssertEqual(selected(vc, tv), "build_all")
        XCTAssertTrue(tv.hasActiveSelection, "SwiftTerm draws it, handles included")
        vc.selectWord(at: point(tv, row: 0, col: 30))
        XCTAssertEqual(selected(vc, tv), "//example.com/x", "a double tap on a link selects, never opens")
        XCTAssertEqual(opened.urls, [])
        XCTAssertEqual(spy.sent.count, before, "no mouse click reaches the app")

        vc.selectWord(at: point(tv, row: 0, col: 3))
        XCTAssertNil(vc.selection, "whitespace selects nothing")
        XCTAssertFalse(tv.hasActiveSelection)
        vc.selectWord(at: point(tv, row: 0, col: 70))
        XCTAssertNil(vc.selection, "past the line end selects nothing")
    }

    func testADoubleTapOnAWideCharSelectsTheWholeRun() async throws {
        let (vc, tv, _, _) = try await makeVC()
        feed(vc, "\u{1b}[2J\u{1b}[H$ 漢字ab next\r\n")
        vc.selectWord(at: point(tv, row: 0, col: 3))
        XCTAssertEqual(selected(vc, tv), "漢字ab")
        XCTAssertEqual(vc.selection?.start.col, 2)
        XCTAssertEqual(vc.selection?.end.col, 8)
    }

    func testOutputKeepsTheSelectionUntilItScrollsTheTextAway() async throws {
        let (vc, tv, _, _) = try await makeVC()
        feed(vc, "\u{1b}[?1000h\u{1b}[2J\u{1b}[Hkeep this word\r\n")
        vc.selectWord(at: point(tv, row: 0, col: 6))
        XCTAssertEqual(selected(vc, tv), "this")

        feed(vc, "\u{1b}[5;1Hspinner")
        XCTAssertEqual(selected(vc, tv), "this", "a repaint in place keeps it")
        XCTAssertTrue(tv.hasActiveSelection, "and SwiftTerm still draws it")

        feed(vc, String(repeating: "line\r\n", count: tv.getTerminal().rows + 2))
        XCTAssertNil(vc.selection, "output that scrolls clears it")
        XCTAssertFalse(tv.hasActiveSelection)
    }

    func testASingleTapClearsTheSelection() async throws {
        let (vc, tv, _, _) = try await makeVC()
        feed(vc, "\u{1b}[2J\u{1b}[Hone two\r\n")
        vc.selectWord(at: point(tv, row: 0, col: 1))
        XCTAssertNotNil(vc.selection)
        vc.tap(at: point(tv, row: 3, col: 1))
        XCTAssertNil(vc.selection)
        XCTAssertFalse(tv.hasActiveSelection)
    }

    func testCopyCopiesTheSelectedWord() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let borrowed = UIPasteboard.general.items
        defer { UIPasteboard.general.items = borrowed }
        feed(vc, "\u{1b}[2J\u{1b}[Hcat /tmp/notes.txt\r\n")
        vc.selectWord(at: point(tv, row: 0, col: 8))
        vc.copySelection()
        XCTAssertEqual(UIPasteboard.general.string, "/tmp/notes.txt")
        XCTAssertNil(vc.selection, "Copy ends the selection")
    }

    func testTheHandlesStandOnTheSelectionEnds() async throws {
        let (vc, tv, _, _) = try await makeVC()
        feed(vc, "\u{1b}[2J\u{1b}[Hsome selection here\r\n")
        vc.selectWord(at: point(tv, row: 0, col: 6))   // "selection", cols 5..<14
        XCTAssertEqual(vc.handle(at: point(tv, row: 0, col: 5, dx: 0)), true)
        XCTAssertEqual(vc.handle(at: point(tv, row: 0, col: 14, dx: 0)), false)
        XCTAssertEqual(vc.handle(at: point(tv, row: 1, col: 14, dx: 0.3)), false, "a finger's slop below")
        XCTAssertNil(vc.handle(at: point(tv, row: 0, col: 9)), "the middle of the word is no handle")
        XCTAssertNil(vc.handle(at: point(tv, row: 4, col: 5)))
    }
}
