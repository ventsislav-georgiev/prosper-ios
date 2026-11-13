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
