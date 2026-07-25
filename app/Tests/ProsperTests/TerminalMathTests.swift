import XCTest
@testable import Prosper

final class TerminalMathTests: XCTestCase {

    // MARK: jogLines — the scroll wheel feel

    /// The wheel rests centered, so a resting (or barely nudged) thumb must not
    /// scroll at all — otherwise the screen creeps whenever a finger sits on it.
    func testDeadZoneNeverScrolls() {
        var rem: CGFloat = 0
        XCTAssertEqual(TerminalMath.jogLines(offset: 0, travel: 90, elapsed: 1, remainder: &rem), 0)
        XCTAssertEqual(TerminalMath.jogLines(offset: 8, travel: 90, elapsed: 1, remainder: &rem), 0)
        XCTAssertEqual(TerminalMath.jogLines(offset: -8, travel: 90, elapsed: 1, remainder: &rem), 0)
    }

    /// Direction: pulled up scrolls up (negative), pulled down scrolls down.
    func testDirectionFollowsTheDeflection() {
        var rem: CGFloat = 0
        XCTAssertLessThan(TerminalMath.jogLines(offset: -90, travel: 90, elapsed: 1, remainder: &rem), 0)
        rem = 0
        XCTAssertGreaterThan(TerminalMath.jogLines(offset: 90, travel: 90, elapsed: 1, remainder: &rem), 0)
    }

    /// Full deflection runs at the stated top speed, and half a pull is much slower
    /// than half of it (the square law is what makes one short handle usable).
    func testSpeedGrowsFasterThanTheDeflection() {
        var rem: CGFloat = 0
        let full = TerminalMath.jogLines(offset: 90, travel: 90, elapsed: 1, remainder: &rem)
        XCTAssertEqual(CGFloat(full), TerminalMath.jogMaxLinesPerSecond, accuracy: 1)
        rem = 0
        let half = TerminalMath.jogLines(offset: 45, travel: 90, elapsed: 1, remainder: &rem)
        XCTAssertLessThan(CGFloat(half), CGFloat(full) / 3)
        XCTAssertGreaterThan(half, 0, "half a pull still has to scroll")
    }

    /// A display-link tick is ~16 ms, far less than one line at gentle deflections —
    /// without the carry a slow hold would truncate to zero forever.
    func testSlowHoldStillCreepsLineByLine() {
        var rem: CGFloat = 0
        var lines = 0
        for _ in 0..<60 { lines += TerminalMath.jogLines(offset: 30, travel: 90,
                                                        elapsed: 1.0 / 60, remainder: &rem) }
        XCTAssertGreaterThan(lines, 0, "a one-second gentle hold scrolled nothing")
        XCTAssertLessThan(lines, 15, "gentle hold should creep, not race")
    }

    /// Dragging past the cap doesn't scroll faster than the cap, and a zero-height
    /// track never divides by zero.
    func testDeflectionClampsAndDegenerateTrackIsSafe() {
        var rem: CGFloat = 0
        let capped = TerminalMath.jogLines(offset: 900, travel: 90, elapsed: 1, remainder: &rem)
        rem = 0
        let full = TerminalMath.jogLines(offset: 90, travel: 90, elapsed: 1, remainder: &rem)
        XCTAssertEqual(capped, full)
        rem = 0
        XCTAssertEqual(TerminalMath.jogLines(offset: 5, travel: 0, elapsed: 1, remainder: &rem), 0)
    }

    // MARK: gridCell — the selection mapping

    func testPointMapsToCell() {
        let (row, col) = TerminalMath.gridCell(point: CGPoint(x: 55, y: 105),
                                               size: CGSize(width: 100, height: 200),
                                               rows: 20, cols: 10)
        XCTAssertEqual(row, 10)
        XCTAssertEqual(col, 5)
    }

    func testOutOfBoundsClampsToEdges() {
        let size = CGSize(width: 100, height: 200)
        let below = TerminalMath.gridCell(point: CGPoint(x: -30, y: -30), size: size, rows: 20, cols: 10)
        XCTAssertEqual(below.row, 0); XCTAssertEqual(below.col, 0)
        let above = TerminalMath.gridCell(point: CGPoint(x: 500, y: 500), size: size, rows: 20, cols: 10)
        XCTAssertEqual(above.row, 19); XCTAssertEqual(above.col, 9)
    }

    func testDegenerateGridIsSafe() {
        let cell = TerminalMath.gridCell(point: CGPoint(x: 10, y: 10), size: .zero, rows: 0, cols: 0)
        XCTAssertEqual(cell.row, 0); XCTAssertEqual(cell.col, 0)
    }

    // MARK: hot-path budget — scroll math must be effectively free

    func testJogHotPathBudget() {
        var rem: CGFloat = 0
        let start = Date()
        for i in 0..<100_000 {
            _ = TerminalMath.jogLines(offset: CGFloat(i % 181) - 90, travel: 90,
                                      elapsed: 1.0 / 60, remainder: &rem)
        }
        // 100k calls ≪ one frame; generous CI headroom, still catches an
        // accidental allocation or formatter sneaking into the pan tick.
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
