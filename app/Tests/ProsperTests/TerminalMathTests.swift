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
        // A fifth of the way out, over the dead zone but barely: the near half of the
        // track is where you aim, so a second of it moves a handful of lines.
        for _ in 0..<60 { lines += TerminalMath.jogLines(offset: 60, travel: 300,
                                                        elapsed: 1.0 / 60, remainder: &rem) }
        XCTAssertGreaterThan(lines, 0, "a one-second gentle hold scrolled nothing")
        XCTAssertLessThan(lines, 25, "gentle hold should creep, not race")
    }

    /// Held at the end of the track, SwiftTerm's whole 500-line scrollback goes by in
    /// about a second. That is the reason the wheel reaches so far: pulling to the top
    /// means "take me through all of it", not "scroll a bit faster".
    func testFullPullCrossesAScrollbackInAboutASecond() {
        var rem: CGFloat = 0
        var lines = 0
        for _ in 0..<60 { lines += TerminalMath.jogLines(offset: -300, travel: 300,
                                                        elapsed: 1.0 / 60, remainder: &rem) }
        XCTAssertLessThan(lines, -500, "one second at full pull covered only \(-lines) lines")
    }

    // MARK: tapRaisesKeyboard — where a tap goes under a mouse-mode TUI

    /// The caret row is the input line, and everything under it is the space beneath
    /// the prompt: both mean "let me type". Only content above the caret is a click.
    /// Requiring an exact caret-row hit made the keyboard a one-row target, so tapping
    /// visibly on the cursor often sent a click nowhere instead.
    func testTapOnAndBelowTheCaretRaisesTheKeyboard() {
        XCTAssertTrue(TerminalMath.tapRaisesKeyboard(row: 40, caretRow: 40))
        XCTAssertTrue(TerminalMath.tapRaisesKeyboard(row: 41, caretRow: 40))
        XCTAssertTrue(TerminalMath.tapRaisesKeyboard(row: 57, caretRow: 40))
        XCTAssertFalse(TerminalMath.tapRaisesKeyboard(row: 39, caretRow: 40))
        XCTAssertFalse(TerminalMath.tapRaisesKeyboard(row: 0, caretRow: 40))
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

    // MARK: batchRemoteScroll — one key burst per batch, not one per frame

    /// Ticks inside the window accumulate silently, then leave together: 60 jog ticks a
    /// second must not become 60 full-screen repaints.
    func testTicksCoalesceIntoOneSend() {
        var pending = 0
        for _ in 0..<3 {
            XCTAssertEqual(TerminalMath.batchRemoteScroll(pending: &pending, add: 1,
                                                          sinceLastSend: 0.016, force: false), 0)
        }
        XCTAssertEqual(TerminalMath.batchRemoteScroll(pending: &pending, add: 1,
                                                      sinceLastSend: TerminalMath.remoteScrollBatch,
                                                      force: false), 4,
                       "the whole burst must go out in one send, nothing dropped")
        XCTAssertEqual(pending, 0)
    }

    /// Lifting the finger flushes whatever is held — the last lines of a drag must not
    /// sit in the buffer waiting for a tick that will never come.
    func testEndOfDragFlushes() {
        var pending = 0
        _ = TerminalMath.batchRemoteScroll(pending: &pending, add: -2, sinceLastSend: 0, force: false)
        XCTAssertEqual(pending, -2)
        XCTAssertEqual(TerminalMath.batchRemoteScroll(pending: &pending, add: 0,
                                                      sinceLastSend: 0, force: true), -2)
        XCTAssertEqual(pending, 0)
    }

    /// Nothing pending sends nothing, even on a flush — an idle wheel must stay silent.
    func testEmptyFlushSendsNothing() {
        var pending = 0
        XCTAssertEqual(TerminalMath.batchRemoteScroll(pending: &pending, add: 0,
                                                      sinceLastSend: 10, force: true), 0)
    }

    /// Direction survives batching, and a reversal inside one window cancels instead of
    /// sending both ways.
    func testDirectionAndReversal() {
        var pending = 0
        _ = TerminalMath.batchRemoteScroll(pending: &pending, add: -3, sinceLastSend: 0, force: false)
        XCTAssertEqual(TerminalMath.batchRemoteScroll(pending: &pending, add: 3,
                                                      sinceLastSend: 1, force: true), 0,
                       "net zero scroll is no scroll")
        _ = TerminalMath.batchRemoteScroll(pending: &pending, add: -3, sinceLastSend: 0, force: false)
        XCTAssertEqual(TerminalMath.batchRemoteScroll(pending: &pending, add: -1,
                                                      sinceLastSend: 1, force: true), -4)
    }

    /// At 60 ticks/s a full second of dragging costs ~20 sends, not 60 — that ratio is
    /// the whole point of the batch.
    func testOneSecondOfDraggingSendsAboutTwentyBursts() {
        var pending = 0, sends = 0, lines = 0, since: CFTimeInterval = 0
        for _ in 0..<60 {
            since += 1.0 / 60
            let out = TerminalMath.batchRemoteScroll(pending: &pending, add: 1,
                                                     sinceLastSend: since, force: false)
            if out != 0 { sends += 1; lines += out; since = 0 }
        }
        lines += TerminalMath.batchRemoteScroll(pending: &pending, add: 0, sinceLastSend: since, force: true)
        XCTAssertEqual(lines, 60, "every line must still reach the remote")
        XCTAssertLessThanOrEqual(sends, 22)
        XCTAssertGreaterThanOrEqual(sends, 18)
    }

    /// Response requirement for the batch window: long enough to spare the remote a
    /// repaint per frame, short enough that the finger doesn't feel the delay.
    func testScrollBatchWindowMeetsTheLatencyBudget() {
        XCTAssertLessThanOrEqual(TerminalMath.remoteScrollBatch, 0.05,
                                 "a held scroll must reach the remote within ~3 frames")
        XCTAssertGreaterThanOrEqual(TerminalMath.remoteScrollBatch, 0.025,
                                    "shorter than this and we're back to a repaint per frame")
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

    // MARK: pasteBytes — text goes over as one paste

    /// Pasted text travels as ONE bracketed paste: the marks around it, the text
    /// untouched between them — newlines included, that is the whole point.
    func testPasteIsBracketedAndVerbatim() {
        let b = TerminalMath.pasteBytes("ls\n  -la")
        XCTAssertEqual(Array(b.prefix(6)), Array("\u{1b}[200~".utf8))
        XCTAssertEqual(Array(b.suffix(6)), Array("\u{1b}[201~".utf8))
        XCTAssertEqual(Array(b.dropFirst(6).dropLast(6)), Array("ls\n  -la".utf8))
    }

    /// #262 QA #79 probe b: a closer inside the clipboard text must not end the paste
    /// early. No ESC survives in the body, so the only closer is ours, at the end.
    func testPastedTextCannotCloseThePasteEarly() {
        let b = TerminalMath.pasteBytes("a \u{1b}[201~ rm -rf x\r")
        XCTAssertEqual(b, Array("\u{1b}[200~a [201~ rm -rf x\r\u{1b}[201~".utf8))
        XCTAssertEqual(b.firstRange(of: Array("\u{1b}[201~".utf8))?.lowerBound, b.count - 6,
                       "an injected closer reached the wire: the host runs what follows it")
    }

    /// Every C0 control but TAB, LF and CR goes (^C would signal through the pty's ISIG);
    /// UTF-8 text is untouched.
    func testPastedTextKeepsOnlyFormattingControls() {
        let b = TerminalMath.pasteBytes("a\u{03}\u{1a}\u{1c}\u{07}\u{00}\tb\r\nż→🙂")
        XCTAssertEqual(Array(b.dropFirst(6).dropLast(6)), Array("a\tb\r\nż→🙂".utf8))
    }

    /// #293: every C1 control (U+0080..U+009F, U+0085 included) goes; NBSP and
    /// multibyte letters stay.
    func testPastedTextDropsC1Controls() {
        let b = TerminalMath.pasteBytes("\u{80}a\u{85}\u{9b}:q\u{9f}\u{a0}ż\u{7f}")
        // DEL (0x7F) survives on purpose: vim/readline treat it as backspace (#299).
        XCTAssertEqual(Array(b.dropFirst(6).dropLast(6)), Array("a:q\u{a0}ż\u{7f}".utf8))
    }

    /// Insert & Send: Enter comes after the end marker, never inside the paste.
    func testPasteThenEnterPutsCRAfterTheEndMarker() {
        let b = TerminalMath.pasteBytes("echo hi", thenEnter: true)
        XCTAssertEqual(Array(b.suffix(7)), Array("\u{1b}[201~\r".utf8))
    }

    /// #271: unbracketed (the host never set 2004) the text is still filtered, unmarked.
    func testUnbracketedPasteIsFilteredWithoutMarks() {
        XCTAssertEqual(TerminalMath.pasteBytes("a\u{1b}[201~\u{03}b\n", thenEnter: true, bracketed: false),
                       Array("a[201~b\n\r".utf8))
    }

    // MARK: trimTrailingBlankLines — copy mode's text

    /// The blank rows under the prompt go; interior blank lines, leading text and the
    /// last line's own trailing spaces stay.
    func testTrimTrailingBlankLinesCutsOnlyTheTail() {
        XCTAssertEqual(TerminalMath.trimTrailingBlankLines("a\n\nb $ \n  \n\n"), "a\n\nb $ ")
        XCTAssertEqual(TerminalMath.trimTrailingBlankLines("  a\nb"), "  a\nb")
        XCTAssertEqual(TerminalMath.trimTrailingBlankLines("\n \n"), "")
        XCTAssertEqual(TerminalMath.trimTrailingBlankLines(""), "")
    }

    // MARK: oneLine — copy mode's "One line" toggle (#457)

    func testOneLineWordWrapJoinsWithASpace() {
        XCTAssertEqual(TerminalMath.oneLine("git commit -m\nfix the thing", cols: 20),
                       "git commit -m fix the thing")
    }

    /// A row filled to exactly cols broke mid-token (a URL, a path): glued with "".
    /// A soft-wrapped row SwiftTerm already joined (2*cols wide) reads the same.
    func testOneLineMidTokenWrapAtColsJoinsWithNothing() {
        XCTAssertEqual(TerminalMath.oneLine("curl https://exa\nmple.com/a", cols: 16),
                       "curl https://example.com/a")
        XCTAssertEqual(TerminalMath.oneLine("curl https://exa" + "mple.com/a/b/c/d\ne", cols: 16),
                       "curl https://example.com/a/b/c/de")
    }

    /// Claude Code's continuation indent and the copy indent go; the indent still
    /// counts towards a full row. Lines under "⏺ " leave no double spaces.
    func testOneLineDropsCopyAndContinuationIndents() {
        XCTAssertEqual(TerminalMath.oneLine("  ⏺ npm run\n    build --prod", cols: 40),
                       "⏺ npm run build --prod")
        XCTAssertEqual(TerminalMath.oneLine("⏺ ls -la\n  /usr/local/\n  bin", cols: 80),
                       "⏺ ls -la /usr/local/ bin")
        XCTAssertEqual(TerminalMath.oneLine("  abcdefgh\n  ij", cols: 10), "abcdefghij")
    }

    /// " \" is a shell continuation; a bare trailing "\" (C:\dir\, a regex) is text.
    func testOneLineBackslashContinuation() {
        XCTAssertEqual(TerminalMath.oneLine("docker run \\\n  -it ubuntu", cols: 80),
                       "docker run -it ubuntu")
        XCTAssertEqual(TerminalMath.oneLine("cd C:\\dir\\\nnext", cols: 80), "cd C:\\dir\\ next")
    }

    /// Blank lines (paragraph breaks too) go; the paragraphs join with " ".
    func testOneLineDropsBlankLines() {
        XCTAssertEqual(TerminalMath.oneLine("\n  a b\n\n   \nc d\n\n", cols: 80), "a b c d")
        XCTAssertEqual(TerminalMath.oneLine("\n \n", cols: 80), "")
    }

    func testOneLineSingleLineUnchanged() {
        XCTAssertEqual(TerminalMath.oneLine("echo hello world", cols: 80), "echo hello world")
        XCTAssertEqual(TerminalMath.oneLine("echo hello world", cols: 16), "echo hello world")
    }

    func testOneLineCRLFMatchesLF() {
        XCTAssertEqual(TerminalMath.oneLine("a b\r\n  c\r\nd", cols: 80),
                       TerminalMath.oneLine("a b\n  c\nd", cols: 80))
    }

    /// Pinned ceilings (the ponytail on oneLine): a word that ends exactly at the last
    /// column is glued to the next; a full row whose trailing spaces the copy trimmed
    /// reads as short and joins with " "; wide CJK counts one column per character.
    func testOneLineDocumentedCeilings() {
        XCTAssertEqual(TerminalMath.oneLine("echo hello\nworld", cols: 10), "echo helloworld")
        XCTAssertEqual(TerminalMath.oneLine("abcdefgh  \nij", cols: 10), "abcdefgh ij")
        XCTAssertEqual(TerminalMath.oneLine("中文中文\n中文", cols: 8), "中文中文 中文")
        XCTAssertEqual(TerminalMath.oneLine("中文中文\n中文", cols: 4), "中文中文中文")
    }

    // MARK: commandBlock — the long-press copy's block (#458)

    private let claude = [
        "",
        "⏺ git commit -m \"fix the",
        "    wrapped thing\"",
        "  ⎿  [main abc123] fix the wrapped thing",
        "",
    ]

    /// A wrapped command under a ⏺ head: the head's marker is blanked, the ⎿ result row
    /// below is the next block and stays out.
    func testCommandBlockTakesTheWrappedCommandUnderItsHead() {
        let block = TerminalMath.commandBlock(claude, at: 2)
        XCTAssertEqual(block, ["  git commit -m \"fix the", "    wrapped thing\""])
        XCTAssertEqual(TerminalMath.oneLine(block.joined(separator: "\n"), cols: 80),
                       "git commit -m \"fix the wrapped thing\"")
    }

    /// Claude Code draws its bullet as ● off macOS (a Linux session host).
    func testCommandBlockTakesTheLinuxBulletAsAHead() {
        let rows = ["● Bash(npm run", "  build)", "  ⎿  done"]
        XCTAssertEqual(TerminalMath.commandBlock(rows, at: 1), ["  Bash(npm run", "  build)"])
    }

    func testCommandBlockFromTheHeadRowItself() {
        XCTAssertEqual(TerminalMath.commandBlock(claude, at: 1),
                       ["  git commit -m \"fix the", "    wrapped thing\""])
    }

    /// The ⎿ row is a head of its own: held there, it copies just itself.
    func testCommandBlockResultRowIsItsOwnBlock() {
        XCTAssertEqual(TerminalMath.commandBlock(claude, at: 3), ["     [main abc123] fix the wrapped thing"])
    }

    /// No marker anywhere: the paragraph between the blank rows, whole.
    func testCommandBlockCodeParagraphBetweenBlankRows() {
        let rows = ["  Run:", "", "  docker run --rm \\", "    -it ubuntu bash", "   ", "  Then exit."]
        XCTAssertEqual(TerminalMath.commandBlock(rows, at: 3), ["  docker run --rm \\", "    -it ubuntu bash"])
        XCTAssertEqual(TerminalMath.commandBlock(rows, at: 0), ["  Run:"])
        XCTAssertEqual(TerminalMath.commandBlock(rows, at: 5), ["  Then exit."])
    }

    /// A marker row going up ends the block even with no blank row in between; ╭/╰
    /// end it too but keep their glyph.
    func testCommandBlockStopsAtTheNearestHeadAbove() {
        let rows = ["⏺ first", "  one", "⏺ second", "  two", "╭───", "│ boxed"]
        XCTAssertEqual(TerminalMath.commandBlock(rows, at: 3), ["  second", "  two"])
        XCTAssertEqual(TerminalMath.commandBlock(rows, at: 1), ["  first", "  one"])
        XCTAssertEqual(TerminalMath.commandBlock(rows, at: 4), ["╭───"])
        XCTAssertEqual(TerminalMath.commandBlock(rows, at: 5), ["  boxed"])
    }

    func testCommandBlockOnABlankOrMissingRowIsEmpty() {
        XCTAssertEqual(TerminalMath.commandBlock(claude, at: 0), [])
        XCTAssertEqual(TerminalMath.commandBlock(["a", "   ", "b"], at: 1), [])
        XCTAssertEqual(TerminalMath.commandBlock(claude, at: 99), [])
        XCTAssertEqual(TerminalMath.commandBlock(claude, at: -1), [])
        XCTAssertEqual(TerminalMath.commandBlock([], at: 0), [])
    }

    // MARK: modified — the shortcut bar's sticky modifiers

    private typealias M = TerminalMath.Modifiers
    private func mod(_ b: [UInt8], _ m: M, bar: Bool = false) -> [UInt8]? {
        TerminalMath.modified(b, by: m, fromBar: bar)
    }

    /// A single typed ASCII byte: ctrl → control char, alt → ESC prefix, shift → upper
    /// case / back-tab / meta-enter newline; combos stack.
    func testSingleByteTakesEveryModifier() {
        XCTAssertEqual(mod([0x6b], .ctrl), [0x0b])                          // ^K
        XCTAssertEqual(mod([0x44], .ctrl), [0x04])                          // ctrl+D (upper)
        XCTAssertEqual(mod([0x7e], .ctrl), [0x1e])                          // ctrl+~
        XCTAssertEqual(mod([0x1b], .ctrl), [0x1b], "a lone Esc with ctrl goes out unchanged")
        XCTAssertEqual(mod([0x62], .alt), [0x1b, 0x62])                     // meta-b
        XCTAssertEqual(mod([0x61], .shift), [0x41])
        XCTAssertEqual(mod([0x7a], .shift), [0x5a])
        XCTAssertEqual(mod([0x09], .shift), [0x1b, 0x5b, 0x5a], "shift+tab is back-tab")
        XCTAssertEqual(mod([0x0d], .shift), TerminalKeyboard.newlineBytes, "shift+enter is the newline")
        XCTAssertEqual(mod([0x31], .shift), [0x31], "shift leaves a non-letter alone")
        XCTAssertEqual(mod([0x41], .shift), [0x41])
        XCTAssertEqual(mod([0x62], [.alt, .ctrl]), [0x1b, 0x02], "alt+ctrl = ESC + control char")
        XCTAssertEqual(mod([0x61], [.shift, .ctrl]), [0x01], "shift+ctrl on a letter = control char")
        XCTAssertEqual(mod([0x61], [.shift, .alt]), [0x1b, 0x41])
    }

    /// The bar's single-byte keys follow the typed-byte rule.
    func testSingleByteBarKeyFollowsTheTypedRule() {
        XCTAssertEqual(mod([0x09], .shift, bar: true), [0x1b, 0x5b, 0x5a])
        XCTAssertEqual(mod([0x0d], .shift, bar: true), [0x1b, 0x0d])
        XCTAssertEqual(mod([0x2f], .ctrl, bar: true), [0x0f])
        XCTAssertEqual(mod([0x1b], .alt, bar: true), [0x1b, 0x1b])
        XCTAssertEqual(mod([0x03], .shift, bar: true), [0x03])
    }

    /// Nothing lit, an ESC-led frame, multi-byte text or a lone DEL: nil, so the caller
    /// sends it whole and spends nothing (#315, #320, #326).
    func testFramesThatDontTakeModifiersAreNil() {
        let all: M = [.shift, .alt, .ctrl]
        XCTAssertNil(mod([0x61], []), "no modifier lit is not a chord")
        XCTAssertNil(mod([0x1b, 0x5b, 0x41], all), "a typed arrow passes through")
        XCTAssertNil(mod(TerminalKeyboard.newlineBytes, all), "the keyboard's ESC CR passes through")
        XCTAssertNil(mod(Array("\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{1b}\\".utf8), all), "a terminal reply passes through")
        XCTAssertNil(mod(Array("é".utf8), all))
        XCTAssertNil(mod(Array("hi".utf8), all))
        XCTAssertNil(mod([0x7f], all), "a lone DEL is not a chord")
        XCTAssertNil(mod([0x1b, 0x5b, 0x5a], all, bar: true), "the back-tab key passes unchanged")
        XCTAssertNil(mod([0x1b, 0x0d], all, bar: true), "the newline key passes unchanged")
        XCTAssertNil(mod([0x1b, 0x5b, 0x33, 0x7e], .ctrl, bar: true), "only 5~ and 6~ take a parameter")
        XCTAssertNil(mod([0x1b, 0x5b, 0x41], [], bar: true))
    }

    /// A bar CSI key takes xterm's parameter m = 1 + shift 1 + alt 2 + ctrl 4.
    func testBarCursorKeysTakeTheXtermParameter() {
        func csi(_ s: String) -> [UInt8] { Array("\u{1b}[\(s)".utf8) }
        XCTAssertEqual(mod(csi("D"), .ctrl, bar: true), csi("1;5D"))
        XCTAssertEqual(mod(csi("A"), .shift, bar: true), csi("1;2A"))
        XCTAssertEqual(mod(csi("B"), .alt, bar: true), csi("1;3B"))
        XCTAssertEqual(mod(csi("C"), [.shift, .ctrl], bar: true), csi("1;6C"))
        XCTAssertEqual(mod(csi("H"), [.alt, .ctrl], bar: true), csi("1;7H"))
        XCTAssertEqual(mod(csi("F"), [.shift, .alt, .ctrl], bar: true), csi("1;8F"))
        XCTAssertEqual(mod(csi("5~"), .ctrl, bar: true), csi("5;5~"))
        XCTAssertEqual(mod(csi("6~"), .shift, bar: true), csi("6;2~"))
    }

    func testControlByte() {
        XCTAssertEqual(TerminalMath.controlByte(0x61), 0x01)
        XCTAssertEqual(TerminalMath.controlByte(0x5a), 0x1a)
        XCTAssertEqual(TerminalMath.controlByte(0x40), 0x00)
    }
}
