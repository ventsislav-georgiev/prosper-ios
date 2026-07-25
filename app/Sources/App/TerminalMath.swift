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

    /// Bytes that paint dch's mirror over the current screen: home, erase, then the
    /// mirror's lines (its bare LFs each need a CR to land in column 0). `[0m` before
    /// the erase keeps ED2 from clearing in whatever color happened to be current.
    ///
    /// The caret is the subtle part. The mirror is cell contents only, so painting it
    /// raw parked the caret at the bottom and drew the input row in the wrong place.
    /// When the server knows where the caret is (dch ≥ 1.5 `--read --cursor`) it ends
    /// the payload with a CUP — that IS the caret, so let it stand. Otherwise fall
    /// back to save (DECSC) / restore (DECRC) around the paint: the live byte stream
    /// already put the cursor where the remote program wanted it.
    static func snapshotPaint(_ screen: ArraySlice<UInt8>) -> [UInt8] {
        let carriesCursor = endsWithCUP(screen)
        var out = Array(((carriesCursor ? "" : "\u{1b}7") + "\u{1b}[0m\u{1b}[H\u{1b}[2J").utf8)
        out.reserveCapacity(out.count + screen.count + 8)
        for b in screen {
            if b == 0x0a { out.append(0x0d) }
            out.append(b)
        }
        if !carriesCursor { out.append(contentsOf: Array("\u{1b}8".utf8)) }
        return out
    }

    /// True when `bytes` ends with `CSI row;col H` — the caret position dch's mirror
    /// reports, appended by the server. Scans backwards, so it costs a handful of
    /// bytes on a screen-sized payload.
    static func endsWithCUP(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.last == 0x48 else { return false }          // 'H'
        var i = bytes.index(before: bytes.endIndex)
        var digits = 0, semis = 0
        while i > bytes.startIndex {
            i = bytes.index(before: i)
            switch bytes[i] {
            case 0x30...0x39: digits += 1
            case 0x3b: semis += 1                               // ';'
            case 0x5b:                                          // '['
                guard i > bytes.startIndex,
                      bytes[bytes.index(before: i)] == 0x1b else { return false }
                return digits > 0 && semis == 1
            default: return false
            }
        }
        return false
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
