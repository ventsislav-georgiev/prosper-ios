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
        XCTAssertEqual(word("vim ~/proj/x.swift:12", at: 7), "~/proj/x.swift", "`~/` stays, never an absolute path")
    }

    func testALinkSpanCoversTheWholeURL() {
        let rows = ["see https://example.com/a?x=1&y=2 now", "next"]
        let span = TerminalMath.webLinkSpan(row: 0, col: 15, cols: 40) { i in
            rows.indices.contains(i) ? (cells(rows[i]), false) : nil
        }
        XCTAssertEqual(span?.url, "https://example.com/a?x=1&y=2")
        XCTAssertTrue(span.map { $0.start == (0, 4) && $0.end == (0, 33) } == true)
        XCTAssertNil(TerminalMath.webLinkSpan(row: 0, col: 1, cols: 40) { i in
            rows.indices.contains(i) ? (cells(rows[i]), false) : nil
        })
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

    func testTheSingleTapWaitsForTheDoubleTapAndThePan() async throws {
        let (vc, _, _, _) = try await makeVC()
        let single = try XCTUnwrap(vc.singleTap), double = try XCTUnwrap(vc.doubleTap)
        let pan = try XCTUnwrap(vc.selectPan)
        XCTAssertEqual(double.numberOfTapsRequired, 2)
        XCTAssertTrue(vc.gestureRecognizer(single, shouldRequireFailureOf: double))
        XCTAssertFalse(vc.gestureRecognizer(double, shouldRequireFailureOf: single))
        XCTAssertTrue(vc.gestureRecognizer(single, shouldRequireFailureOf: pan), "a short handle drag is no tap")
        XCTAssertFalse(vc.gestureRecognizer(double, shouldRequireFailureOf: pan))
    }

    func testSwiftTermsMousePanWaitsWhileASelectionShows() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let pan = try XCTUnwrap(vc.selectPan), lp = try XCTUnwrap(vc.longPress)
        let before = tv.gestureRecognizers ?? []
        feed(vc, "\u{1b}[?1000h\u{1b}[2J\u{1b}[Hpick me\r\n")
        let mouse = try XCTUnwrap(tv.gestureRecognizers?.first { g in !before.contains { $0 === g } },
                                  "SwiftTerm adds its mouse pan when mouse mode turns on")
        XCTAssertTrue(mouse is UIPanGestureRecognizer)
        XCTAssertFalse(vc.gestureRecognizer(pan, shouldBeRequiredToFailBy: mouse), "no selection: as before")
        vc.selectWord(at: point(tv, row: 0, col: 1))
        XCTAssertNotNil(vc.selection)
        XCTAssertTrue(vc.gestureRecognizer(pan, shouldBeRequiredToFailBy: mouse))
        XCTAssertTrue(vc.gestureRecognizer(lp, shouldBeRequiredToFailBy: mouse))
        XCTAssertFalse(vc.gestureRecognizer(lp, shouldBeRequiredToFailBy: pan), "the pan waits on the hold, not back")
        vc.clearSelection()
        XCTAssertFalse(vc.gestureRecognizer(pan, shouldBeRequiredToFailBy: mouse))
    }

    func testTheScrollStripLetsTapsThroughWhileHidden() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let strip = try XCTUnwrap(vc.view.subviews.first { $0 !== tv && $0.frame.maxX == vc.view.bounds.maxX
                                                          && $0.frame.width == 44 })
        let edge = vc.view.bounds.maxX - 6
        XCTAssertTrue(vc.view.hitTest(CGPoint(x: edge, y: strip.frame.minY + 20), with: nil)?.isDescendant(of: tv) == true,
                      "hidden: a tap on the last column reaches the terminal")
        XCTAssertTrue(vc.view.hitTest(CGPoint(x: edge, y: strip.frame.midY), with: nil) === strip,
                      "the pill's own band still grabs")
        vc.tap(at: point(tv, row: 5, col: 1))   // a tap shows the pill
        XCTAssertTrue(vc.view.hitTest(CGPoint(x: edge, y: strip.frame.minY + 20), with: nil) === strip,
                      "shown: the whole strip, as before")
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
        XCTAssertEqual(selected(vc, tv), "https://example.com/x", "a double tap on a link selects it whole, never opens")
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

    func testTrimmingAFullScrollbackClearsIt() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let t = tv.getTerminal()
        t.changeScrollback(3)
        feed(vc, String(repeating: "line\r\n", count: t.rows + 10) + "pick me")
        vc.selectWord(at: point(tv, row: t.rows - 1, col: 1))
        XCTAssertEqual(selected(vc, tv), "pick")
        let yDisp = t.buffer.yDisp, trimmed = t.buffer.totalLinesTrimmed
        feed(vc, "\r\n")
        XCTAssertEqual(t.buffer.yDisp, yDisp, "precondition: the view didn't move")
        XCTAssertGreaterThan(t.buffer.totalLinesTrimmed, trimmed, "precondition: a line was trimmed")
        XCTAssertNil(vc.selection, "the text moved up a line under it")
    }

    func testSwitchingScreensClearsIt() async throws {
        let (vc, tv, _, _) = try await makeVC()
        let t = tv.getTerminal()
        feed(vc, "\u{1b}[2J\u{1b}[Hmain words\r\n")
        vc.selectWord(at: point(tv, row: 0, col: 1))
        XCTAssertEqual(selected(vc, tv), "main")
        feed(vc, "\u{1b}[?1049h\u{1b}[Halt words")
        XCTAssertTrue(t.isCurrentBufferAlternate)
        XCTAssertEqual(t.buffer.yDisp, 0, "precondition: same yDisp")
        XCTAssertNil(vc.selection, "the alternate screen is other text")
        vc.selectWord(at: point(tv, row: 0, col: 1))
        XCTAssertEqual(selected(vc, tv), "alt")
        feed(vc, "\u{1b}[?1049l")
        XCTAssertFalse(t.isCurrentBufferAlternate)
        XCTAssertNil(vc.selection, "and back")
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
        let name = UIPasteboard.Name("word-selection-tests")
        let pb = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        vc.pasteboard = pb   // never the general one: reading it back can prompt
        feed(vc, "\u{1b}[2J\u{1b}[Hcat /tmp/notes.txt\r\n")
        vc.selectWord(at: point(tv, row: 0, col: 8))
        vc.copySelection()
        XCTAssertEqual(pb.string, "/tmp/notes.txt")
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

    // `selectWord` on "some selection here": "selection" is cols 5..<14 on row 0.
    private func selectionVC() async throws -> (TerminalHostVC, TerminalView) {
        let (vc, tv, _, _) = try await makeVC()
        feed(vc, "\u{1b}[2J\u{1b}[Hsome selection here\r\n")
        vc.selectWord(at: point(tv, row: 0, col: 6))
        return (vc, tv)
    }

    func testTheGrabRadiusIs22PointsEachWay() async throws {
        let (vc, tv) = try await selectionVC()
        let end = point(tv, row: 0, col: 14, dx: 0), start = point(tv, row: 0, col: 5, dx: 0)
        XCTAssertEqual(vc.handle(at: CGPoint(x: end.x + 21.9, y: end.y)), false)
        XCTAssertNil(vc.handle(at: CGPoint(x: end.x + 22.1, y: end.y)))
        XCTAssertEqual(vc.handle(at: CGPoint(x: start.x - 21.9, y: start.y)), true)
        XCTAssertNil(vc.handle(at: CGPoint(x: start.x - 22.1, y: start.y)))
    }

    func testATieGoesToTheStartHandle() async throws {
        let (vc, tv, _, _) = try await makeVC()
        feed(vc, "\u{1b}[2J\u{1b}[H\r\n\r\nx b y\r\n")
        vc.selectWord(at: point(tv, row: 2, col: 2))
        XCTAssertEqual(selected(vc, tv), "b")
        // 15 pt above the row, between the two: the same distance to both handles.
        let p = point(tv, row: 2, col: 2)
        XCTAssertEqual(vc.handle(at: CGPoint(x: p.x, y: p.y - tv.caretFrame.height / 2 - 15)), true)
    }

    func testTheGrabIsMeasuredFromTheTouchDownBothWays() async throws {
        for way: CGFloat in [-1, 1] {
            let (vc, tv) = try await selectionVC()
            let end = point(tv, row: 0, col: 14, dx: 0)
            // 18 pt right of the end handle; the pan begins 12 pt along the drag.
            vc.touchDown = CGPoint(x: end.x + 18, y: end.y)
            XCTAssertTrue(vc.dragHandle(.began, at: CGPoint(x: end.x + 18 + 12 * way, y: end.y)),
                          way < 0 ? "dragging back across" : "dragging away")
            _ = vc.dragHandle(.ended, at: CGPoint(x: end.x + 18 + 12 * way, y: end.y))
        }
    }

    func testTheMenuComesBackAfterAHandleDrag() async throws {
        let (vc, tv) = try await selectionVC()
        var shown = 0
        vc.presentMenu = { _ in shown += 1 }
        vc.touchDown = point(tv, row: 0, col: 14, dx: 0)
        XCTAssertTrue(vc.dragHandle(.began, at: vc.touchDown!))
        XCTAssertTrue(vc.dragHandle(.changed, at: point(tv, row: 0, col: 16, dx: 0)))
        XCTAssertEqual(shown, 0, "not while dragging")
        XCTAssertTrue(vc.dragHandle(.ended, at: point(tv, row: 0, col: 16, dx: 0)))
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(selected(vc, tv), "selection h")
        vc.touchDown = point(tv, row: 0, col: 9)
        XCTAssertFalse(vc.dragHandle(.began, at: vc.touchDown!), "off the handles the pan keeps its own job")
    }

    /// Drags the start handle of a word on the top row above the top edge; returns
    /// yDisp before and after.
    private func dragAboveTheTop(mouse: Bool) async throws -> (Int, Int) {
        let (vc, tv, _, _) = try await makeVC()
        let t = tv.getTerminal()
        feed(vc, (mouse ? "\u{1b}[?1000h" : "") + String(repeating: "line\r\n", count: t.rows + 20))
        XCTAssertGreaterThan(t.buffer.yDisp, 0, "precondition: scrollback above")
        vc.selectWord(at: point(tv, row: 0, col: 1))
        XCTAssertEqual(selected(vc, tv), "line")
        vc.touchDown = point(tv, row: 0, col: 0, dx: 0)
        XCTAssertTrue(vc.dragHandle(.began, at: vc.touchDown!))
        let before = t.buffer.yDisp
        let top = tv.convert(CGPoint(x: 0, y: vc.view.safeAreaInsets.top), from: vc.view).y
        _ = vc.dragHandle(.changed, at: CGPoint(x: vc.touchDown!.x, y: top - 10))
        return (before, t.buffer.yDisp)
    }

    func testAHandleDraggedPastTheTopScrollsTheScrollback() async throws {
        let (before, after) = try await dragAboveTheTop(mouse: false)
        XCTAssertEqual(after, before - 1)
    }

    func testInMouseModeAHandlePastTheTopClamps() async throws {
        let (before, after) = try await dragAboveTheTop(mouse: true)
        XCTAssertEqual(after, before, "the app has no local scrollback to move")
    }
}
