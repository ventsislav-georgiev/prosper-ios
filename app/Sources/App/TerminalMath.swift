import CoreGraphics

/// Pure geometry for the terminal gestures — kept side-effect free so the unit
/// tests can pin the scroll/selection feel without UIKit.
enum TerminalMath {
    /// Ignore deflections this small a share of the travel — a resting thumb and a
    /// fingertip wobble must not scroll.
    static let jogDeadZone: CGFloat = 0.12
    /// Scroll rate at full deflection.
    static let jogMaxLinesPerSecond: CGFloat = 45

    /// Jog-wheel scrolling: how many whole lines to scroll during `elapsed` seconds
    /// with the pill held `offset` points off center (`travel` = points available in
    /// each direction). Negative = up. The fractional part carries in `remainder`, so
    /// a gentle hold still creeps line by line instead of truncating to nothing.
    ///
    /// Rate grows with the SQUARE of the deflection: precise near the middle, fast at
    /// the ends, which is what makes one small handle able to cover both.
    static func jogLines(offset: CGFloat, travel: CGFloat, elapsed: CGFloat,
                         remainder: inout CGFloat) -> Int {
        guard travel > 0, elapsed > 0 else { return 0 }
        let deflection = min(max(offset / travel, -1), 1)
        let magnitude = abs(deflection)
        guard magnitude > jogDeadZone else { remainder = 0; return 0 }
        let past = (magnitude - jogDeadZone) / (1 - jogDeadZone)
        let lines = past * past * jogMaxLinesPerSecond * elapsed * (deflection < 0 ? -1 : 1)
        let total = lines + remainder
        let whole = Int(total)          // truncates toward zero — right in both directions
        remainder = total - CGFloat(whole)
        return whole
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
