import XCTest
import SwiftTerm
@testable import Prosper

/// Rotation regression: a bounds change must leave the terminal's pixels inside the
/// visible window. SwiftTerm draws rows at absolute *content* offsets while its
/// UIScrollView shifts the visible window by `contentOffset`; if the two disagree
/// after a size change the screen paints blank. We render the view the way UIKit
/// does (translating by the scroll offset) and measure where the ink landed.
final class TerminalRotationTests: XCTestCase {

    private func makeView(_ size: CGSize) -> TerminalView {
        let tv = TerminalView(frame: CGRect(origin: .zero, size: size),
                             font: TerminalFont.mono(size: TerminalPrefs.fontSize))
        tv.backgroundColor = .black
        tv.nativeBackgroundColor = .black
        tv.isScrollEnabled = false
        tv.contentInsetAdjustmentBehavior = .never
        tv.contentMode = .redraw
        tv.layoutIfNeeded()
        return tv
    }

    /// Fill every row with visible text so any blank band is a rendering fault, not
    /// empty content.
    private func fillScreen(_ tv: TerminalView) {
        let t = tv.getTerminal()
        var s = ""
        for r in 0..<t.rows {
            s += "R\(r)" + String(repeating: "X", count: max(1, t.cols - 6)) + (r == t.rows - 1 ? "" : "\r\n")
        }
        tv.feed(text: s)
        tv.layoutIfNeeded()
    }

    /// Which pixel rows of the viewport have any non-black ink, as a 0…1 fraction.
    /// The context is translated by `contentOffset` because that is what UIKit does
    /// for a scroll view's own `draw` — without it we'd be measuring content
    /// coordinates and any scrolled-back buffer would look blank.
    private func inkFraction(_ tv: TerminalView) -> Double {
        let w = Int(tv.bounds.width), h = Int(tv.bounds.height)
        guard w > 0, h > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: w * 4, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        // Bitmap contexts are bottom-up; flip to match UIKit, then apply the scroll
        // offset exactly like the window server would.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -tv.contentOffset.x, y: -tv.contentOffset.y)
        UIGraphicsPushContext(ctx)          // SwiftTerm's draw() pulls from the UIKit stack
        tv.draw(tv.bounds)
        UIGraphicsPopContext()

        var rowsWithInk = 0
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4] > 24 || pixels[(y * w + x) * 4 + 1] > 24 {
                rowsWithInk += 1
                break
            }
        }
        return Double(rowsWithInk) / Double(h)
    }

    func testPortraitScreenHasInk() {
        let tv = makeView(CGSize(width: 390, height: 700))
        fillScreen(tv)
        XCTAssertGreaterThan(inkFraction(tv), 0.2, "a full screen of text must cover the viewport")
    }

    /// The bug report: rotate portrait → landscape and the text goes missing. After
    /// the rotation the grid is shorter, so the buffer scrolls — the visible window
    /// must still land on the painted rows.
    func testLandscapeAfterRotationHasInk() {
        let tv = makeView(CGSize(width: 390, height: 700))
        fillScreen(tv)
        tv.frame = CGRect(x: 0, y: 0, width: 700, height: 390)   // rotate
        tv.layoutIfNeeded()
        XCTAssertGreaterThan(inkFraction(tv), 0.2, "rotation left the visible window off the content")
    }

    /// Rotating back must not park the ink off-screen either.
    func testRotationRoundTripKeepsInkInsideViewport() {
        let tv = makeView(CGSize(width: 390, height: 700))
        fillScreen(tv)
        tv.frame = CGRect(x: 0, y: 0, width: 700, height: 390)
        tv.layoutIfNeeded()
        tv.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        tv.layoutIfNeeded()
        XCTAssertGreaterThan(inkFraction(tv), 0.2, "round-trip rotation lost the screen")
    }

    /// A dch mirror snapshot (`dch --read --ansi`, bare LFs) must land one line per
    /// row starting at the top — the CR insertion is what makes that true. Without
    /// it every line would start where the previous one ended and the screen would
    /// stair-step off the right edge.
    func testSnapshotFeedLandsLinesAtColumnZero() {
        let tv = makeView(CGSize(width: 390, height: 700))
        let screen = "alpha\nbravo\ncharlie\n"
        var out = Array("\u{1b}[H\u{1b}[2J".utf8)
        for b in Array(screen.utf8) {
            if b == 0x0a { out.append(0x0d) }
            out.append(b)
        }
        tv.feed(byteArray: out[...])
        let t = tv.getTerminal()
        XCTAssertEqual(t.getLine(row: 0)?.translateToString(trimRight: true), "alpha")
        XCTAssertEqual(t.getLine(row: 1)?.translateToString(trimRight: true), "bravo")
        XCTAssertEqual(t.getLine(row: 2)?.translateToString(trimRight: true), "charlie")
    }
}
