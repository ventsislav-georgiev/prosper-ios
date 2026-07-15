import XCTest
@testable import Prosper

final class TerminalMathTests: XCTestCase {

    // MARK: lineSteps — the scroll feel

    func testWholeCellsProduceSteps() {
        var rem: CGFloat = 0
        XCTAssertEqual(TerminalMath.lineSteps(dy: 30, cell: 10, remainder: &rem), 3)
        XCTAssertEqual(rem, 0)
    }

    func testSubCellDragsAccumulate() {
        var rem: CGFloat = 0
        // Four 3-pt drags over a 10-pt cell: steps land on the 4th drag.
        XCTAssertEqual(TerminalMath.lineSteps(dy: 3, cell: 10, remainder: &rem), 0)
        XCTAssertEqual(TerminalMath.lineSteps(dy: 3, cell: 10, remainder: &rem), 0)
        XCTAssertEqual(TerminalMath.lineSteps(dy: 3, cell: 10, remainder: &rem), 0)
        XCTAssertEqual(TerminalMath.lineSteps(dy: 3, cell: 10, remainder: &rem), 1)
        XCTAssertEqual(rem, 2, accuracy: 0.001)
    }

    func testNegativeDragScrollsOtherWay() {
        var rem: CGFloat = 0
        XCTAssertEqual(TerminalMath.lineSteps(dy: -25, cell: 10, remainder: &rem), -2)
        XCTAssertEqual(rem, -5, accuracy: 0.001)
    }

    func testDirectionFlipMidDrag() {
        var rem: CGFloat = 0
        _ = TerminalMath.lineSteps(dy: 7, cell: 10, remainder: &rem)    // rem 7
        // 7 - 9 = -2 → no step yet, remainder keeps the overshoot.
        XCTAssertEqual(TerminalMath.lineSteps(dy: -9, cell: 10, remainder: &rem), 0)
        XCTAssertEqual(rem, -2, accuracy: 0.001)
    }

    func testDegenerateCellNeverDividesByZero() {
        var rem: CGFloat = 0
        XCTAssertEqual(TerminalMath.lineSteps(dy: 5, cell: 0, remainder: &rem), 5)
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

    func testLineStepsHotPathBudget() {
        var rem: CGFloat = 0
        let start = Date()
        for i in 0..<100_000 {
            _ = TerminalMath.lineSteps(dy: CGFloat(i % 13) - 6, cell: 14, remainder: &rem)
        }
        // 100k calls ≪ one frame; generous CI headroom, still catches an
        // accidental allocation or formatter sneaking into the pan tick.
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
