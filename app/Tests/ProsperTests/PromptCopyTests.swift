import XCTest
import UIKit
import SwiftTerm
@testable import Prosper

/// #976: copy line on a zsh prompt took the left prompt and the right prompt (RPROMPT) with
/// the command. Only the command goes now.
@MainActor
final class PromptCopyTests: XCTestCase {

    private func makeVC() async throws -> (TerminalHostVC, TerminalView, UIPasteboard) {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport, session: DchSession(name: "t", alias: nil))
        let vc = TerminalHostVC(conn: conn, handle: TermHandle())
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        vc.view.layoutIfNeeded()
        vc.startIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        transport.stream.emit("\r\n")   // the first output opens the session to input
        try await Task.sleep(nanoseconds: 50_000_000)
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        vc.pasteboard = pb
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        return (vc, tv, pb)
    }

    /// A zsh prompt: the left prompt, the right prompt at the row's edge less one column
    /// (ZLE_RPROMPT_INDENT), the caret back after the left prompt.
    private func prompt(_ tv: TerminalView) {
        let cols = tv.getTerminal().cols
        tv.feed(text: "\ruser@host ~ % \u{1b}7\u{1b}[\(cols - 8)G12:30:01\u{1b}8")
    }

    func testRightPromptAndKnownLeftPromptStayOut() {
        XCTAssertEqual(TerminalMath.promptCommand("u@h ~ % ls  -la          12:30", prompt: "u@h ~ % ", atEdge: true), "ls  -la")
        XCTAssertEqual(TerminalMath.promptCommand("u@h ~ % ls          12:30", prompt: nil, atEdge: true), "u@h ~ % ls")
        XCTAssertEqual(TerminalMath.promptCommand("out  put", prompt: nil, atEdge: false), "out  put", "not at the edge: no right prompt")
        XCTAssertEqual(TerminalMath.promptCommand("$ ls", prompt: "u@h ~ % ", atEdge: false), "$ ls", "another prompt stays")
        XCTAssertEqual(TerminalMath.promptCommand("u@h ~ %           12:30", prompt: "u@h ~ % ", atEdge: true), "")
    }

    /// The first typed key on a fresh prompt row learns the left prompt; copy line then takes
    /// the command alone, without the right prompt either.
    func testCopyLineOnAZshPromptTakesTheCommandOnly() async throws {
        let (vc, tv, pb) = try await makeVC()
        prompt(tv)
        try await Task.sleep(nanoseconds: 100_000_000)   // the caret moves on SwiftTerm's display pass
        vc.send(source: tv, data: [0x6c])   // the typed `l`, the host echoes it
        XCTAssertEqual(vc.shellPrompt, "user@host ~ % ")
        tv.feed(text: "ls -la")
        try await Task.sleep(nanoseconds: 100_000_000)

        vc.copyCaretLine()
        XCTAssertEqual(pb.string, "ls -la")

        tv.feed(text: "\r\nout  put\r\n")   // the next prompt: same left prompt, nothing typed
        prompt(tv)
        try await Task.sleep(nanoseconds: 100_000_000)
        pb.string = "kept"
        vc.copyCaretLine()
        XCTAssertEqual(pb.string, "kept", "a prompt with nothing typed is an empty line")
    }

    /// A command that wraps fills its first row to the edge, but zsh shows no right prompt on
    /// it: its double space and tail stay.
    func testAWrappedCommandKeepsItsTail() async throws {
        let (vc, tv, pb) = try await makeVC()
        prompt(tv)
        try await Task.sleep(nanoseconds: 100_000_000)
        vc.send(source: tv, data: [0x65])
        let command = "echo a  b " + String(repeating: "x", count: tv.getTerminal().cols)
        tv.feed(text: "\u{1b}[K" + command)
        try await Task.sleep(nanoseconds: 100_000_000)

        vc.copyCaretLine()
        XCTAssertEqual(pb.string, command)
    }

    /// A key that goes out with text right of the caret (mid-line, a TUI) learns no prompt.
    func testAKeyMidLineLearnsNoPrompt() async throws {
        let (vc, tv, _) = try await makeVC()
        tv.feed(text: "> some text\u{1b}[5D")
        try await Task.sleep(nanoseconds: 100_000_000)
        vc.send(source: tv, data: [0x6c])
        XCTAssertNil(vc.shellPrompt)
    }

    /// The screen row `r` shows, one cell in.
    private func rowPoint(_ tv: TerminalView, _ r: Int) -> CGPoint {
        CGPoint(x: 1.5 * tv.caretFrame.width, y: tv.contentOffset.y + (CGFloat(r) + 0.5) * tv.caretFrame.height)
    }

    /// The screen row whose text starts with `prefix`.
    private func row(_ tv: TerminalView, _ prefix: String) throws -> Int {
        let term = tv.getTerminal()
        return try XCTUnwrap((0..<term.rows).first { term.getLine(row: $0)?.translateToString(trimRight: true).hasPrefix(prefix) == true }, prefix)
    }

    /// #977: a hold on a zsh prompt row took the whole non-blank run: the command, its output and
    /// the next prompt, one line. Now the command alone, its soft wrap glued, the prompts out;
    /// output and the prompt rows next to it each copy on their own.
    func testLongPressOnAPromptRowCopiesItsCommandOnly() async throws {
        let (vc, tv, pb) = try await makeVC()
        let cols = tv.getTerminal().cols
        prompt(tv)
        try await Task.sleep(nanoseconds: 100_000_000)
        vc.send(source: tv, data: [0x63])   // learns the left prompt
        tv.feed(text: "\u{1b}[Kcd /tmp\r\n")   // no output: the next prompt is right under it
        prompt(tv)
        // soft-wraps mid-word: "…xxlo" | "ng-tail"
        let long = "echo " + String(repeating: "x", count: cols - 21) + "long-tail"
        tv.feed(text: "\u{1b}[K" + long + "\r\nfile-one  file-two\r\nfile-three\r\n")
        prompt(tv)
        tv.feed(text: "\u{1b}[Kls")
        try await Task.sleep(nanoseconds: 100_000_000)
        let echo = try row(tv, "user@host ~ % echo")
        XCTAssertEqual(tv.getTerminal().getLine(row: echo + 1)?.isWrapped, true, "precondition: the command soft-wraps")

        for (r, want) in [(echo, long), (echo + 1, long), (try row(tv, "user@host ~ % cd"), "cd /tmp"),
                          (try row(tv, "user@host ~ % ls"), "ls"), (echo + 2, "file-one  file-two file-three"),
                          (echo + 3, "file-one  file-two file-three")] {
            pb.string = "none"
            vc.copyLine(at: rowPoint(tv, r))
            XCTAssertEqual(pb.string, want, "hold on row \(r)")
        }
    }

    /// A learned prompt can be a TUI's (Claude Code's "> "): a row indented under it is that TUI's
    /// wrapped message, and the hold still joins it, as before #977.
    func testALearnedPromptWithAnIndentedRowUnderItStaysJoined() async throws {
        let (vc, tv, pb) = try await makeVC()
        tv.feed(text: "> ")
        try await Task.sleep(nanoseconds: 100_000_000)
        vc.send(source: tv, data: [0x61])
        XCTAssertEqual(vc.shellPrompt, "> ")
        tv.feed(text: "\r\n\r\n> fix the wrapped\r\n  message please\r\n\r\n> one row\r\nout\r\n")
        try await Task.sleep(nanoseconds: 100_000_000)
        for (r, want) in [(try row(tv, "> fix"), "> fix the wrapped message please"), (try row(tv, "> one"), "one row")] {
            pb.string = "none"
            vc.copyLine(at: rowPoint(tv, r))
            XCTAssertEqual(pb.string, want, "hold on row \(r)")
        }
    }

    /// The same with OSC 133 marks and no learned prompt.
    func testLongPressOnAnOSC133PromptRowCopiesItsCommandOnly() async throws {
        let (vc, tv, pb) = try await makeVC()
        let p = "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}"
        tv.feed(text: p + "make\r\n\u{1b}]133;C\u{7}built\r\n" + p + "true\r\n" + p)
        try await Task.sleep(nanoseconds: 100_000_000)
        let make = try row(tv, "$ make")
        for (r, want) in [(make, "make"), (make + 1, "built"), (make + 2, "true")] {
            pb.string = "none"
            vc.copyLine(at: rowPoint(tv, r))
            XCTAssertEqual(pb.string, want, "hold on row \(r)")
        }
    }

    /// A shell that marks its prompts (OSC 133 A, B) gets them dropped by both copies, the
    /// long press on the prompt row too.
    func testOSC133PromptCellsStayOutOfBothCopies() async throws {
        let (vc, tv, pb) = try await makeVC()
        tv.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}echo hi")
        try await Task.sleep(nanoseconds: 100_000_000)
        vc.copyCaretLine()
        XCTAssertEqual(pb.string, "echo hi", "copy line")
        pb.string = ""
        let cell = tv.caretFrame.size
        vc.copyLine(at: CGPoint(x: 4.5 * cell.width, y: tv.caretFrame.midY))
        XCTAssertEqual(pb.string, "echo hi", "the long press")
    }
}
