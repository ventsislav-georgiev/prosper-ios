import XCTest
import SwiftTerm
@testable import Prosper

/// Painting dch's mirror must not move the cursor or leak colors. The mirror is
/// cell contents only — it carries no cursor position and ends mid-SGR — so the
/// paint is wrapped in DECSC/DECRC. Without that the caret parked at the bottom of
/// the screen and the input row drew in the wrong place.
final class SnapshotPaintTests: XCTestCase {

    /// Byte-for-byte what TerminalScreen.applyScreen sends.
    private func paint(_ tv: TerminalView, mirror: String) {
        var out = Array("\u{1b}7\u{1b}[0m\u{1b}[H\u{1b}[2J".utf8)
        for b in Array(mirror.utf8) {
            if b == 0x0a { out.append(0x0d) }
            out.append(b)
        }
        out.append(contentsOf: Array("\u{1b}8".utf8))
        tv.feed(byteArray: out[...])
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
