import XCTest
@testable import Prosper

final class TerminalMathTests: XCTestCase {

    // MARK: jogLines — the scroll wheel feel

    /// The wheel rests centered, so a resting (or barely nudged) thumb must not
    /// scroll at all — otherwise the screen creeps whenever a finger sits on it.
    func testDeadZoneNeverScrolls() {
        var rem: CGFloat = 0
        XCTAssertEqual(TerminalMath.jogLines(offset: 0, travel: 90, elapsed: 1, remainder: &rem), 0)
        XCTAssertEqual(TerminalMath.jogLines(offset: 7, travel: 90, elapsed: 1, remainder: &rem), 0)
        XCTAssertEqual(TerminalMath.jogLines(offset: -7, travel: 90, elapsed: 1, remainder: &rem), 0)
        // Just past it (0.08 of the travel, #736) the wheel already answers.
        XCTAssertGreaterThan(TerminalMath.jogLines(offset: 8, travel: 90, elapsed: 1, remainder: &rem), 0)
    }

    /// Direction: pulled up scrolls up (negative), pulled down scrolls down.
    func testDirectionFollowsTheDeflection() {
        var rem: CGFloat = 0
        XCTAssertLessThan(TerminalMath.jogLines(offset: -90, travel: 90, elapsed: 1, remainder: &rem), 0)
        rem = 0
        XCTAssertGreaterThan(TerminalMath.jogLines(offset: 90, travel: 90, elapsed: 1, remainder: &rem), 0)
    }

    /// Full deflection runs at the stated top speed, and half a pull is much slower
    /// than half of it (the cube law keeps most of the travel slow, #736).
    func testSpeedGrowsFasterThanTheDeflection() {
        var rem: CGFloat = 0
        let full = TerminalMath.jogLines(offset: 90, travel: 90, elapsed: 1, remainder: &rem)
        XCTAssertEqual(CGFloat(full), TerminalMath.jogMaxLinesPerSecond, accuracy: 1)
        rem = 0
        let half = TerminalMath.jogLines(offset: 45, travel: 90, elapsed: 1, remainder: &rem)
        XCTAssertLessThan(CGFloat(half), CGFloat(full) / 3)
        XCTAssertGreaterThan(half, 0, "half a pull still has to scroll")
        XCTAssertTrue((15...30).contains(half), "half a pull runs \(half) lines/s")
    }

    /// The rate never drops as the pull grows, either way (#736).
    func testRateIsMonotonic() {
        var last = 0
        for step in 0...100 {
            var rem: CGFloat = 0
            let down = TerminalMath.jogLines(offset: CGFloat(step), travel: 100, elapsed: 10, remainder: &rem)
            rem = 0
            let up = TerminalMath.jogLines(offset: -CGFloat(step), travel: 100, elapsed: 10, remainder: &rem)
            XCTAssertGreaterThanOrEqual(down, last, "slower at \(step)% than at \(step - 1)%")
            XCTAssertEqual(up, -down, "up and down differ at \(step)%")
            last = down
        }
    }

    /// A display-link tick is ~16 ms, far less than one line at gentle deflections —
    /// without the carry a slow hold would truncate to zero forever.
    func testSlowHoldStillCreepsLineByLine() {
        var rem: CGFloat = 0
        var lines = 0
        // Just past the dead zone: one line at a time, a few a second — slow enough
        // to read each line go by (#736).
        for _ in 0..<60 {
            let tick = TerminalMath.jogLines(offset: 30, travel: 300, elapsed: 1.0 / 60, remainder: &rem)
            XCTAssertLessThanOrEqual(tick, 1, "a gentle hold moves one line at a time")
            lines += tick
        }
        XCTAssertTrue((2...6).contains(lines), "a one-second gentle hold moved \(lines) lines")
    }

    /// The wheel is for fine scrolling: even held at the end of the track it reads
    /// as a brisk scroll, not a blur — at most 120 lines a second, either way (#736).
    func testFullPullIsCappedAndSymmetric() {
        var up = 0, down = 0
        var rem: CGFloat = 0
        for _ in 0..<60 { up += TerminalMath.jogLines(offset: -300, travel: 300,
                                                     elapsed: 1.0 / 60, remainder: &rem) }
        rem = 0
        for _ in 0..<60 { down += TerminalMath.jogLines(offset: 300, travel: 300,
                                                       elapsed: 1.0 / 60, remainder: &rem) }
        XCTAssertLessThanOrEqual(down, 120, "one second at full pull covered \(down) lines")
        XCTAssertGreaterThan(down, 60, "the far end must still be distinctly fast")
        XCTAssertEqual(up, -down)
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

    /// #459: a full row joins with "" only when its last token and the next line's first
    /// could not have shared the wrap box (cols less the indent) — Ink split a token.
    func testOneLineFullRowGluesOnlyATokenTooLongForTheBox() {
        XCTAssertEqual(TerminalMath.oneLine("  https://www.exampl\n  e.com/a/very/long/\n  path/x", cols: 20),
                       "https://www.example.com/a/very/long/path/x")
        XCTAssertEqual(TerminalMath.oneLine("  echo one two three\n  four", cols: 20),
                       "echo one two three four")
    }

    /// Pinned ceilings (the ponytail on oneLine): two tokens, the first ending exactly at
    /// the last column, too long together for the box are glued; a full row whose
    /// trailing spaces the copy trimmed reads as short and joins with " "; wide CJK
    /// counts one column per character.
    func testOneLineDocumentedCeilings() {
        XCTAssertEqual(TerminalMath.oneLine("echo hello\nworld", cols: 10), "echo hello world")
        XCTAssertEqual(TerminalMath.oneLine("a hellohello\nworld", cols: 12), "a hellohelloworld")
        XCTAssertEqual(TerminalMath.oneLine("abcdefgh  \nij", cols: 10), "abcdefgh ij")
        XCTAssertEqual(TerminalMath.oneLine("中文中文\n中文", cols: 8), "中文中文 中文")
        XCTAssertEqual(TerminalMath.oneLine("中文中文\n中文", cols: 4), "中文中文中文")
        // #1016: rows drawn at 92 that all fit an earlier 48, the first filling it exactly,
        // read as drawn at 48: two long tokens glue. And a width the terminal never had
        // (Claude Code's opt-in maxProseWidth, 60 here) is unknown: its split gets a space.
        XCTAssertEqual(TerminalMath.oneLine("⏺ scp build/out/release-2026-11-13/app-arm64.tgz\n"
                                            + "  ci-runner-europe-west1-b-primary-7781:/srv/rel", cols: 92, widths: [48, 92]),
                       "⏺ scp build/out/release-2026-11-13/app-arm64.tgzci-runner-europe-west1-b-primary-7781:/srv/rel")
        XCTAssertEqual(TerminalMath.oneLine("  - Open https://github.com/example/prosper-ios/actions/runs\n"
                                            + "    /39821438259/job/1234567 to see the failing run, then\n    rerun it.",
                                            cols: 92, widths: [48, 92]),
                       "- Open https://github.com/example/prosper-ios/actions/runs /39821438259/job/1234567 to see the failing run, then rerun it.")
    }

    /// #1023: a selection starting mid-row measures its first row whole (`lead`, the row's
    /// unselected start), so a token split at that row's end glues; from column 0, or from
    /// the row's newline, nothing changes.
    func testOneLineMeasuresAMidRowSelectionsFirstRowWhole() {
        let rows = "  curl -o out https://example.com/abcdef\n  ghijklmnop/q.tgz && ls"
        let at = { (col: Int) in String(rows.dropFirst(col)) }
        let lead = { (col: Int) in String(rows.prefix(col)) }
        XCTAssertEqual(TerminalMath.oneLine(at(10), cols: 40, lead: lead(10)),
                       "out https://example.com/abcdefghijklmnop/q.tgz && ls")
        XCTAssertEqual(TerminalMath.oneLine(at(22), cols: 40, lead: lead(22)),
                       "example.com/abcdefghijklmnop/q.tgz && ls")
        XCTAssertEqual(TerminalMath.oneLine(rows, cols: 40, lead: ""), TerminalMath.oneLine(rows, cols: 40))
        XCTAssertEqual(TerminalMath.oneLine(rows, cols: 40), "curl -o out https://example.com/abcdefghijklmnop/q.tgz && ls")
        XCTAssertEqual(TerminalMath.oneLine(at(40), cols: 40, lead: lead(40)), "ghijklmnop/q.tgz && ls")
        // The box is the row's own (40 less its 2-column indent), not shrunk by the lead:
        // two short words at the row break keep their space.
        XCTAssertEqual(TerminalMath.oneLine("abc defghi\n  jklmn && ls", cols: 40, lead: "  echo one two three four fiv "),
                       "abc defghi jklmn && ls")
    }

    /// #1016: Claude Code (Ink) output as wrapped at one width and copied at another
    /// (rotation): the rows keep the width they were drawn at. Ink rows are hard newlines,
    /// so SwiftTerm's reflow leaves narrower rows alone and soft-wraps wider ones, which
    /// getText joins back. Fixtures from a port of wrap-ansi (hard, trim: false).
    private let cmd48 = [
        "⏺ Bash(curl -fsS https://console.cloud.example.c",
        "  om/kubernetes/deployment/europe-west1-b/ci-pri",
        "  mary/web/overview?project=example-ci -o",
        "  /tmp/overview.html)",
    ]
    private let cmd92 = [
        "⏺ Bash(curl -fsS https://console.cloud.example.com/kubernetes/deployment/europe-west1-b/ci-p",
        "  rimary/web/overview?project=example-ci -o /tmp/overview.html)",
    ]
    private let cmd = "⏺ Bash(curl -fsS https://console.cloud.example.com/kubernetes/deployment/europe-west1-b/ci-primary/web/overview?project=example-ci -o /tmp/overview.html)"
    private let item48 = [
        "  - Open https://github.com/example/prosper-ios/",
        "    actions/runs/39821438259/job/1234567 to see",
        "    the failing run, then rerun it.",
    ]
    private let item = "- Open https://github.com/example/prosper-ios/actions/runs/39821438259/job/1234567 to see the failing run, then rerun it."

    /// Drawn in portrait (48), copied in landscape (92) and the reverse: a token split at
    /// the earlier width glues once that width is passed; at its own width it always did.
    func testOneLineGluesATokenSplitAtAnEarlierWidth() {
        let joined = { (rows: [String], cols: Int) in
            TerminalMath.oneLine(rows.joined(separator: "\n"), cols: cols, widths: [48, 92])
        }
        XCTAssertEqual(joined(cmd48, 92), cmd)
        XCTAssertEqual(joined(item48, 92), item)
        XCTAssertEqual(joined(cmd92, 48), cmd)
        XCTAssertEqual(TerminalMath.oneLine(cmd48.joined(separator: "\n"), cols: 48), cmd)
        XCTAssertEqual(TerminalMath.oneLine(cmd92.joined(separator: "\n"), cols: 92), cmd)
    }

    /// An earlier width a row exceeds is not the one these rows were drawn at: drawn at 92
    /// and copied there, the 48-wide first row keeps its word break though the terminal
    /// was 48 once and its two long tokens are too long for a 48 box.
    func testOneLineIgnoresAnEarlierWidthARowExceeds() {
        let cmd92 = [
            "⏺ scp build/out/release-2026-11-13/app-arm64.tgz",
            "  ci-runner-europe-west1-b-primary-7781:/srv/rel && ssh",
            "  ci-runner-europe-west1-b-primary-7781 systemctl restart app",
        ]
        XCTAssertEqual(TerminalMath.oneLine(cmd92.joined(separator: "\n"), cols: 92, widths: [48, 92]),
                       "⏺ scp build/out/release-2026-11-13/app-arm64.tgz ci-runner-europe-west1-b-primary-7781:/srv/rel && ssh ci-runner-europe-west1-b-primary-7781 systemctl restart app")
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

    /// #459: the "!" command Claude printed with no backslashes, as wrapped at 68 cols
    /// under its ● head, held on a middle row: one line, every break a space — the
    /// "… --context" row is exactly 68 wide yet ended on a word.
    func testCommandBlockJoinsTheUnescapedBangCommand() {
        let rows = [
            "● The paste wrapped the line again:",
            "",
            "  ! for c in gke_example-ci_europe-west4-b_ci-primary",
            "  gke_example-system_europe-west1-b_ci-primary; do kubectl --context",
            "  $c -n web-frontend-controller rollout restart",
            "  deploy/web-frontend-controller; done",
            "",
        ]
        let block = TerminalMath.commandBlock(rows, at: 4)
        XCTAssertEqual(block, Array(rows[2...5]))
        XCTAssertEqual(TerminalMath.oneLine(block.joined(separator: "\n"), cols: 68),
                       "! for c in gke_example-ci_europe-west4-b_ci-primary gke_example-system_europe-west1-b_ci-primary; do kubectl --context $c -n web-frontend-controller rollout restart deploy/web-frontend-controller; done")
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

    /// #952 (QA #277): alt+shift chords as xterm sends them, alt the ESC prefix. Shift+enter is
    /// already meta-enter (ESC CR), so alt adds no second ESC: ESC ESC CR reads as Esc pressed first.
    func testAltShiftChords() {
        let altShift: M = [.alt, .shift]
        XCTAssertEqual(mod([0x0d], altShift), TerminalKeyboard.newlineBytes, "alt+shift+enter is ESC CR, not ESC ESC CR")
        XCTAssertEqual(mod([0x0d], [.alt, .shift, .ctrl]), TerminalKeyboard.newlineBytes)
        XCTAssertEqual(mod([0x0d], altShift, bar: true), TerminalKeyboard.newlineBytes)
        XCTAssertEqual(mod([0x0d], .alt), [0x1b, 0x0d], "alt+enter is meta-enter too")
        XCTAssertEqual(mod([0x09], altShift), [0x1b, 0x1b, 0x5b, 0x5a], "meta back-tab: ESC then CSI Z")
        XCTAssertEqual(mod([0x7a], altShift), [0x1b, 0x5a], "meta Z")
        XCTAssertEqual(mod([0x31], altShift), [0x1b, 0x31], "shift leaves a digit alone; alt still prefixes")
        XCTAssertEqual(mod([0x61], [.alt, .shift, .ctrl]), [0x1b, 0x01], "ESC ^A")
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

    /// #321 QA #126: under kitty flag 8 every key is ESC[<key>;<mods>u, so the lit modifiers go
    /// in its modifier field (bits as xterm's), keeping the alternates, the text only without ctrl/alt.
    func testKittyKeyReportTakesTheModifiersInItsField() {
        func k(_ s: String) -> [UInt8] { Array("\u{1b}[\(s)u".utf8) }
        XCTAssertEqual(mod(k("97"), .ctrl), k("97;5"), "plain a + ctrl is ctrl+a")
        XCTAssertEqual(mod(k("97;2"), .ctrl), k("97;6"), "shift+a keeps its shift")
        XCTAssertEqual(mod(k("97;5"), .ctrl), k("97;5"), "a key already holding ctrl is unchanged")
        XCTAssertEqual(mod(k("97"), .alt), k("97;3"))
        XCTAssertEqual(mod(k("97"), [.shift, .alt, .ctrl]), k("97;8"))
        XCTAssertEqual(mod(k("13"), .ctrl), k("13;5"), "enter under flag 8")
        XCTAssertEqual(mod(k("27"), .ctrl), k("27;5"), "Esc under flag 1")
        XCTAssertEqual(mod(k("97:65"), .ctrl), k("97:65;5"), "alternates (flag 4) are kept")
        XCTAssertEqual(mod(k("97;;97"), .ctrl), k("97;5"), "ctrl drops the text (flag 16)")
        XCTAssertEqual(mod(k("97;;97"), .shift), k("97;2;65"), "shift upper-cases the text")
        XCTAssertEqual(mod(k("0;;99"), .ctrl), k("99;5"), "SwiftTerm's software-keyboard text becomes the key")
        XCTAssertEqual(mod(k("0;;67"), .ctrl), k("99;5"), "lowercased, as SwiftTerm's own ctrl does")
        XCTAssertEqual(mod(k("0;;97"), .shift), k("97;2;65"))
        XCTAssertEqual(mod(k("0"), .ctrl), k("0;5"), "flag 8 alone loses the text; the key still spends the arm")
        XCTAssertEqual(mod(k("97;1:1"), .ctrl), k("97;5"), "an explicit press takes them")
        XCTAssertEqual(mod(k("97"), .ctrl, bar: true), k("97;5"), "a bar key that is a kitty report too")
    }

    /// Releases, repeats and a modifier key's own report (a hardware shift under flag 8) are not
    /// the chord's key: nil, so they go out whole and the arm stays lit. So is a non-kitty frame.
    func testKittyFramesThatDontTakeModifiersAreNil() {
        func k(_ s: String) -> [UInt8] { Array("\u{1b}[\(s)u".utf8) }
        XCTAssertNil(mod(k("97;1:3"), .ctrl), "a release")
        XCTAssertNil(mod(k("97;1:2"), .ctrl), "a repeat")
        XCTAssertNil(mod(k("57441;2"), .ctrl), "left shift's own press")
        XCTAssertNil(mod(k("57454"), .ctrl), "ISO level 5 shift")
        XCTAssertNil(mod(Array("\u{1b}[?1u".utf8), .ctrl), "the flags query reply")
        XCTAssertNil(mod(Array("\u{1b}[1;5A".utf8), .ctrl), "a modified arrow")
        XCTAssertNil(mod(k("97"), []), "nothing lit")
    }

    func testControlByte() {
        XCTAssertEqual(TerminalMath.controlByte(0x61), 0x01)
        XCTAssertEqual(TerminalMath.controlByte(0x5a), 0x1a)
        XCTAssertEqual(TerminalMath.controlByte(0x40), 0x00)
    }
}
