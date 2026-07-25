import XCTest
import SwiftTerm
@testable import Prosper

/// Painting dch's mirror must not move the cursor or leak colors. A bare mirror is
/// cell contents only — no cursor position, ends mid-SGR — so the paint is wrapped
/// in DECSC/DECRC. Without that the caret parked at the bottom of the screen and the
/// input row drew in the wrong place. When the server does know the caret
/// (`dch --read --cursor`) it appends a CUP and that wins.
final class SnapshotPaintTests: XCTestCase {

    /// The real paint bytes, so this can't drift from what the app sends.
    private func paint(_ tv: TerminalView, mirror: String) {
        let bytes = ArraySlice(Array(mirror.utf8))
        tv.feed(byteArray: TerminalMath.snapshotPaint(bytes)[...])
    }

    private func makeView() -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700),
                             font: TerminalFont.mono(size: TerminalPrefs.fontSize))
        tv.layoutIfNeeded()
        return tv
    }

    func testCursorSurvivesTheSnapshot() {
        let tv = makeView()
        // Put the cursor where a TUI's input row would be: row 4, column 8.
        tv.feed(text: "\u{1b}[5;9H")
        let before = tv.getTerminal().getCursorLocation()

        paint(tv, mirror: "top line\nsecond\nthird\nfourth\nfifth\nsixth\n")

        XCTAssertEqual(tv.getTerminal().getCursorLocation().x, before.x)
        XCTAssertEqual(tv.getTerminal().getCursorLocation().y, before.y)
    }

    /// The mirror's own colors must not bleed into what the program writes next.
    /// dch's reported caret (a CUP the server appends) beats the guess — placing the
    /// caret a row off is what drew the input row outside its box.
    func testReportedCursorWinsOverTheLiveOne() {
        let tv = makeView()
        tv.feed(text: "\u{1b}[20;1H")

        paint(tv, mirror: "alpha\nbravo\ncharlie\n\u{1b}[3;5H")

        let at = tv.getTerminal().getCursorLocation()
        XCTAssertEqual(at.y, 2, "caret row ignored dch's cursor")
        XCTAssertEqual(at.x, 4, "caret column ignored dch's cursor")
    }

    func testCUPDetection() {
        func ends(_ s: String) -> Bool { TerminalMath.endsWithCUP(ArraySlice(Array(s.utf8))) }
        XCTAssertTrue(ends("screen\u{1b}[7;12H"))
        XCTAssertTrue(ends("\u{1b}[1;1H"))
        XCTAssertFalse(ends("screen\u{1b}[0m\n"), "a plain mirror must keep save/restore")
        XCTAssertFalse(ends("screen\u{1b}[H"), "no row/col — nothing to trust")
        XCTAssertFalse(ends("screen\u{1b}[12H"), "CUP needs both coordinates")
        XCTAssertFalse(ends("H"))
        XCTAssertFalse(ends(""))
    }

    func testAttributesDoNotLeakOutOfTheSnapshot() {
        let tv = makeView()
        let plain = tv.getTerminal().currentAttribute

        paint(tv, mirror: "\u{1b}[31;44mred on blue\u{1b}[0m\n\u{1b}[1;32mgreen\n")

        XCTAssertEqual(tv.getTerminal().currentAttribute, plain,
            "SGR state leaked past the snapshot — later output would be miscolored")
    }

    /// The screen the mirror describes has to actually land, one line per row from
    /// the top.
    func testMirrorContentLandsFromTheTop() {
        let tv = makeView()
        tv.feed(text: "stale junk everywhere\r\nmore junk\r\n")
        paint(tv, mirror: "alpha\nbravo\n")
        let t = tv.getTerminal()
        XCTAssertEqual(t.getLine(row: 0)?.translateToString(trimRight: true), "alpha")
        XCTAssertEqual(t.getLine(row: 1)?.translateToString(trimRight: true), "bravo")
        XCTAssertEqual(t.getLine(row: 2)?.translateToString(trimRight: true), "")
    }
}
