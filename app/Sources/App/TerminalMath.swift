import CoreGraphics

/// Pure geometry for the terminal gestures — kept side-effect free so the unit
/// tests can pin the scroll/selection feel without UIKit.
enum TerminalMath {
    /// Whole-line steps for a drag delta, carrying the sub-cell remainder so
    /// slow drags still accumulate into steps instead of being truncated away.
    static func lineSteps(dy: CGFloat, cell: CGFloat, remainder: inout CGFloat) -> Int {
        let cell = max(1, cell)
        let total = dy + remainder
        let steps = Int(total / cell)
        remainder = total - CGFloat(steps) * cell
        return steps
    }

    /// Absolute-scrollbar pill mapping: scroll fraction [0,1] → pill-center offset
    /// from the track center (constraint constant), for a `pill`-tall pill in a
    /// `track`-tall strip.
    static func pillOffset(fraction: CGFloat, track: CGFloat, pill: CGFloat) -> CGFloat {
        (min(max(fraction, 0), 1) - 0.5) * max(0, track - pill)
    }

    /// Inverse of `pillOffset`: pill-center offset → scroll fraction, clamped so a
    /// drag past the track ends pins to 0/1. Degenerate track (pill fills it) → 0.
    static func pillFraction(offset: CGFloat, track: CGFloat, pill: CGFloat) -> CGFloat {
        let travel = max(0, track - pill)
        guard travel > 0 else { return 0 }
        return min(max(offset / travel + 0.5, 0), 1)
    }

    /// Grid cell under a point, clamped to the grid — off-view touches select
    /// the nearest edge cell instead of crashing or vanishing.
    static func gridCell(point: CGPoint, size: CGSize, rows: Int, cols: Int) -> (row: Int, col: Int) {
        let cellH = max(1, size.height / CGFloat(max(rows, 1)))
        let cellW = max(1, size.width / CGFloat(max(cols, 1)))
        return (min(max(0, Int(point.y / cellH)), max(rows - 1, 0)),
                min(max(0, Int(point.x / cellW)), max(cols - 1, 0)))
    }
}
