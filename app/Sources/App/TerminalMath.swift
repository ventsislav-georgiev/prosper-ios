import CoreGraphics

/// Pure geometry for the terminal gestures — kept side-effect free so the unit
/// tests can pin the scroll/selection feel without UIKit.
enum TerminalMath {
    /// Ignore deflections this small a share of the travel — a resting thumb and a
    /// fingertip wobble must not scroll.
    static let jogDeadZone: CGFloat = 0.12
    /// Scroll rate at full deflection. Sized so pulling the pill to the very top
    /// crosses a full scrollback in a couple of seconds instead of grinding through
    /// it — the whole point of holding the wheel at its end.
    static let jogMaxLinesPerSecond: CGFloat = 600

    /// Where a tap goes while a mouse-reporting TUI is running: the keyboard, or a
    /// click forwarded to the app.
    ///
    /// The caret row IS the input line, and the rows under it are the empty space
    /// beneath the prompt — a tap there means "let me type", never "click that". Only
    /// content above the caret is worth a click. Matching the caret row exactly made
    /// the keyboard a one-row target (~14 pt), so tapping visibly ON the cursor often
    /// sent a click into the void instead of raising the keyboard.
    static func tapRaisesKeyboard(row: Int, caretRow: Int) -> Bool { row >= caretRow }

    /// Copy mode's text without the blank rows under the prompt. SwiftTerm's getText
    /// drops trailing rows that are truly empty, but a row holding erased spaces or a
    /// background colour counts as content and still comes back as an empty line —
    /// a wall of them at the bottom of the view. Cuts at the first newline after the
    /// last visible character; everything before it is left as is.
    static func trimTrailingBlankLines(_ s: String) -> String {
        guard let last = s.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        let tail = s[s.index(after: last)...]
        return tail.firstIndex(where: \.isNewline).map { String(s[..<$0]) } ?? s
    }

    /// Copy mode's "One line": terminal-wrapped lines joined back into the one
    /// command they were. Claude Code hard-wraps at the width with a continuation
    /// indent, so a copied command keeps newlines and does not run. Blank lines go,
    /// each line is trimmed both sides (the copy indent, the continuation indent), and
    /// lines join with " ", a word-wrap break. Only a line that filled the row AND whose
    /// last token plus the next line's first one would not fit the wrap box joins with
    /// "": Ink word-wraps, and splits a token only when it is longer than the line —
    /// a URL, a path. A trailing " \" (shell continuation) drops the backslash and
    /// joins with " ".
    static func oneLine(_ text: String, cols: Int) -> String {
        var out = ""
        var glue = ""
        // The previous line filled its row: its last token's length and the wrap box
        // (cols less its indent). The glue is decided once the next line's head is seen.
        var full: (tail: Int, box: Int)?
        for raw in text.split(whereSeparator: \.isNewline) {
            // Display width counts the indent: the row is full, indent and all.
            let right = String(raw.reversed().drop(while: \.isWhitespace).reversed())
            guard !right.isEmpty else { continue }
            let line = right.drop(while: \.isWhitespace)
            if let f = full {
                let head = line.prefix(while: { !$0.isWhitespace }).count
                glue = f.tail + head > f.box ? "" : " "
            }
            out += glue + line
            full = nil
            glue = " "
            if right.hasSuffix(" \\") {
                out.removeLast()
                while out.last?.isWhitespace == true { out.removeLast() }
                continue
            }
            // ponytail: "full" is width % cols == 0 — SwiftTerm's getText already joins
            // soft-wrapped rows (k*cols wide), and a hard wrap at cols is one row. Two
            // separate tokens, the first ending exactly at the last column, whose combined
            // length exceeds the box get glued — rare, it takes a token nearly a row long.
            // Wide CJK/emoji count as one column (SwiftTerm's UnicodeUtil.columnWidth is
            // internal); use cell widths if that bites.
            if cols > 0, right.count % cols == 0 {
                let tail = right.reversed().prefix(while: { !$0.isWhitespace }).count
                full = (tail, cols - (right.count - line.count))
            }
        }
        return out
    }

    /// The rows a long-press copies (#458): the maximal run of non-blank rows around
    /// `row`, empty when `row` itself is blank. A Claude Code marker row (⏺, or ● off
    /// macOS; ⎿ │ ╭ ╰ first) above is the block's head and ends it; one below starts the
    /// next block and stays out. The head's ⏺/●/⎿/│ and its space turn into spaces rather
    /// than vanish: `oneLine` trims them anyway, and the row keeps its width, so a full
    /// head row still counts as full there.
    static func commandBlock(_ rows: [String], at row: Int) -> [String] {
        func blank(_ i: Int) -> Bool { rows[i].allSatisfy(\.isWhitespace) }
        func marker(_ i: Int) -> Bool { rows[i].first { !$0.isWhitespace }.map { "⏺●⎿│╭╰".contains($0) } ?? false }
        guard rows.indices.contains(row), !blank(row) else { return [] }
        var top = row, bottom = row
        while !marker(top), top > 0, !blank(top - 1) { top -= 1 }
        while bottom + 1 < rows.count, !blank(bottom + 1), !marker(bottom + 1) { bottom += 1 }
        var block = Array(rows[top...bottom])
        let head = block[0]
        if let i = head.firstIndex(where: { !$0.isWhitespace }), "⏺●⎿│".contains(head[i]) {
            let next = head.index(after: i)
            let end = next < head.endIndex && head[next] == " " ? head.index(after: next) : next
            block[0].replaceSubrange(i..<end, with: String(repeating: " ", count: head.distance(from: i, to: end)))
        }
        return block
    }

    /// C1 control scalars, U+0080..U+009F: 8-bit forms of ESC sequences (U+009B is CSI).
    static let c1Controls: ClosedRange<UInt32> = 0x80...0x9F

    /// Text for the pty as ONE bracketed paste (ESC[200~ … ESC[201~) — what `dch --send`
    /// does on the Mac: readline, Claude Code and vim insert it verbatim instead of
    /// running each line at its newline. Wrapped only when `bracketed` (the host turned
    /// DECSET 2004 on): a host that never did (bash 3.2) shows the marks as `00~…01~`.
    /// The mode is trustworthy after a reconnect: dch re-arms every set DEC mode,
    /// 2004 included, ahead of the screen replay on each attach (dch master.c:2017).
    /// `thenEnter` puts CR after the end marker, so the TUI submits the whole text
    /// instead of seeing a newline inside the paste.
    ///
    /// Every paste goes through here (shortcut bar, Insert & Send, and SwiftTerm's
    /// `paste:` via `DchTerminalView.onPaste`), and the clipboard is untrusted: text
    /// copied from a web page or a chat can carry ESC[201~, end the paste early and have
    /// the host RUN whatever follows (#262). So the text keeps only TAB, LF, CR and
    /// non-control bytes: every ESC goes (no closer, no other escape sequence can be
    /// spelled), and so does every other C0 control (^C/^Z/^\ would signal through the
    /// pty's ISIG even inside a paste) — xterm's default for pastes (allowPasteControls
    /// off). C1 controls go too: nvim takes U+009B (CSI) and U+0080 like ESC and runs
    /// what follows as commands (#293). DEL (0x7F) is kept: inside a bracketed paste the
    /// host takes it as a literal byte, not as an erase key.
    static func pasteBytes(_ s: String, thenEnter: Bool = false, bracketed: Bool = true) -> [UInt8] {
        let kept = s.unicodeScalars.filter {
            ($0.value >= 0x20 && !c1Controls.contains($0.value)) || $0 == "\t" || $0 == "\n" || $0 == "\r"
        }
        let text = Array(String(String.UnicodeScalarView(kept)).utf8)
        guard bracketed else { return text + (thenEnter ? [0x0d] : []) }
        return Array("\u{1b}[200~".utf8) + text + Array("\u{1b}[201~".utf8) + (thenEnter ? [0x0d] : [])
    }

    /// The shortcut bar's sticky modifiers that are lit (once or locked). The raw value is
    /// xterm's modifier bits, so a CSI key's parameter is `1 + rawValue`.
    struct Modifiers: OptionSet {
        let rawValue: UInt8
        static let shift = Modifiers(rawValue: 1)
        static let alt   = Modifiers(rawValue: 2)
        static let ctrl  = Modifiers(rawValue: 4)
    }

    /// Map a byte to its control-char form (a–z/A–Z → ^A–^Z, others via `& 0x1f`).
    static func controlByte(_ b: UInt8) -> UInt8 {
        let upper = (b >= 0x61 && b <= 0x7a) ? b - 0x20 : b
        return upper & 0x1f
    }

    /// `bytes` with the lit modifiers applied, or nil when the frame doesn't take them —
    /// the caller then sends it as it is and every modifier stays lit.
    ///
    /// Only a single ASCII byte below DEL takes modifiers, typed or from the bar: ESC-led
    /// frames (terminal replies, arrows, the keyboard's ESC CR), multi-byte text and a
    /// lone DEL are not chords (#315, #320, #326). shift uppercases a letter, turns TAB
    /// into back-tab and CR into the meta-enter newline; ctrl is `controlByte`; alt puts
    /// ESC in front (meta). A bar key (`fromBar`) also takes them on a CSI cursor/edit key,
    /// xterm style: ESC [ A → ESC [ 1 ; m A, ESC [ 5 ~ → ESC [ 5 ; m ~. Any other
    /// multi-byte bar key (back-tab, the newline key) goes out unchanged.
    static func modified(_ bytes: [UInt8], by mods: Modifiers, fromBar: Bool = false) -> [UInt8]? {
        guard !mods.isEmpty else { return nil }
        if bytes.count == 1, let b = bytes.first, b < 0x7f {
            var out: [UInt8]
            switch b {
            case 0x09 where mods.contains(.shift): out = [0x1b, 0x5b, 0x5a]
            case 0x0d where mods.contains(.shift): out = TerminalKeyboard.newlineBytes
            default:
                var c = mods.contains(.shift) && b >= 0x61 && b <= 0x7a ? b - 0x20 : b
                if mods.contains(.ctrl) { c = controlByte(c) }
                out = [c]
            }
            return mods.contains(.alt) ? [0x1b] + out : out
        }
        guard fromBar, bytes.count >= 3, bytes[0] == 0x1b, bytes[1] == 0x5b else { return nil }
        let m = Array(String(1 + Int(mods.rawValue)).utf8)
        switch Array(bytes[2...]) {
        case [0x41], [0x42], [0x43], [0x44], [0x48], [0x46]:     // A B C D H F
            return [0x1b, 0x5b, 0x31, 0x3b] + m + [bytes[2]]
        case [0x35, 0x7e], [0x36, 0x7e]:                         // 5~ 6~
            return [0x1b, 0x5b, bytes[2], 0x3b] + m + [0x7e]
        default:
            return nil
        }
    }

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

    /// How long scroll meant for the REMOTE (a full-screen TUI, or a mouse-reporting
    /// app) is allowed to accumulate before it goes out.
    ///
    /// Local scrollback scrolls itself, but on the alternate screen every line is an
    /// arrow key the remote answers with a WHOLE repainted screen. One key per display
    /// frame is ~60 repaints a second: more than the link and the parser can absorb, so
    /// they queue, arrive late and get drawn half-applied — the hiccups and tearing.
    /// Three lines in one key burst costs ONE repaint, and 20 coherent repaints a second
    /// look smoother than 60 torn ones.
    static let remoteScrollBatch: CFTimeInterval = 0.05

    /// Accumulate scroll for the remote and report how much to send NOW (0 = keep
    /// holding). `force` flushes whatever is pending — the drag ended, and the last few
    /// lines must not sit in the buffer.
    static func batchRemoteScroll(pending: inout Int, add: Int,
                                  sinceLastSend: CFTimeInterval, force: Bool) -> Int {
        pending += add
        guard pending != 0 else { return 0 }
        guard force || sinceLastSend >= remoteScrollBatch else { return 0 }
        let out = pending
        pending = 0
        return out
    }

    /// Bytes that paint dch's mirror over the current screen: home, erase, then the
    /// mirror's lines (its bare LFs each need a CR to land in column 0). `[0m` before
    /// the erase keeps ED2 from clearing in whatever color happened to be current.
    ///
    /// The caret is the subtle part, in two ways.
    ///
    /// The mirror is a full screen of lines and ends with a newline. Written out as-is,
    /// that last newline on the last row SCROLLS the screen: the content shifts up a
    /// row while the caret's absolute position doesn't, which is why the caret drew one
    /// row below the input box. So the trailing newlines go.
    ///
    /// The mirror also carries no caret of its own. When the server knows where it is
    /// (dch ≥ 1.5 `--read --cursor`) it appends a CUP — that IS the caret, so let it
    /// stand. Otherwise save (DECSC) / restore (DECRC) around the paint: the live byte
    /// stream already put the cursor where the remote program wanted it.
    static func snapshotPaint(_ screen: ArraySlice<UInt8>) -> [UInt8] {
        let cup = cupTail(screen)
        var content = screen[screen.startIndex..<(cup ?? screen.endIndex)]
        while let last = content.last, last == 0x0a || last == 0x0d {
            content = content.dropLast()
        }
        var out = Array(((cup == nil ? "\u{1b}7" : "") + "\u{1b}[0m\u{1b}[H\u{1b}[2J").utf8)
        out.reserveCapacity(out.count + screen.count + 8)
        for b in content {
            if b == 0x0a { out.append(0x0d) }   // the mirror's bare LFs need a CR
            out.append(b)
        }
        if let cup {
            out.append(contentsOf: screen[cup...])
        } else {
            out.append(contentsOf: Array("\u{1b}8".utf8))
        }
        return out
    }

    /// True when `bytes` ends with `CSI row;col H` — the caret position dch's mirror
    /// reports, appended by the server.
    static func endsWithCUP(_ bytes: ArraySlice<UInt8>) -> Bool { cupTail(bytes) != nil }

    /// Index of the ESC starting a trailing `CSI row;col H`, if there is one. Scans
    /// backwards, so it costs a handful of bytes on a screen-sized payload.
    static func cupTail(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8>.Index? {
        guard bytes.last == 0x48 else { return nil }            // 'H'
        var i = bytes.index(before: bytes.endIndex)
        var digits = 0, semis = 0
        while i > bytes.startIndex {
            i = bytes.index(before: i)
            switch bytes[i] {
            case 0x30...0x39: digits += 1
            case 0x3b: semis += 1                               // ';'
            case 0x5b:                                          // '['
                guard i > bytes.startIndex else { return nil }
                let esc = bytes.index(before: i)
                guard bytes[esc] == 0x1b, digits > 0, semis == 1 else { return nil }
                return esc
            default: return nil
            }
        }
        return nil
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
