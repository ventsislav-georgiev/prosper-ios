import XCTest
import UIKit
import UniformTypeIdentifiers
import SwiftTerm
@testable import Prosper

/// The image button only ever sent ctrl-V, which makes Claude Code read the clipboard
/// of the MACHINE IT RUNS ON. The phone's copied image gets there only if Universal
/// Clipboard happens to sync it — so the button did nothing most of the time. Now the
/// bytes travel with the request.
@MainActor
final class ImagePasteTests: XCTestCase {

    /// 1×1 transparent PNG.
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// On Mac Catalyst `UIPasteboard.general` IS the system pasteboard, so these tests
    /// would otherwise wipe whatever the developer had copied. Borrow it and give it
    /// back. Only there: on iOS reading another app's pasteboard raises the paste
    /// permission alert, which hangs an unattended simulator run (#271), and the
    /// simulator's clipboard holds nothing to keep.
    private var borrowedClipboard: [[String: Any]] = []

    override func setUp() {
        super.setUp()
        #if targetEnvironment(macCatalyst)
        borrowedClipboard = UIPasteboard.general.items
        #endif
    }

    override func tearDown() {
        #if targetEnvironment(macCatalyst)
        UIPasteboard.general.items = borrowedClipboard
        #endif
        clearSavedShortcuts()
        super.tearDown()
    }

    private func makeVC(live: Bool = true) async throws -> (TerminalHostVC, SpyStream) {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport,
                                     session: DchSession(name: "t", alias: nil))
        let vc = TerminalHostVC(conn: conn, handle: TermHandle())
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        vc.view.layoutIfNeeded()
        vc.startIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        // The session's first output is what opens it to input (SessionConnection.goLive).
        if live {
            transport.stream.emit("$ ")
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return (vc, transport.stream)
    }

    func testImagePasteShipsTheImageAndTheKeystroke() async throws {
        let (vc, spy) = try await makeVC()
        UIPasteboard.general.setData(png, forPasteboardType: "public.png")

        vc.pasteImage(then: [0x16])

        XCTAssertEqual(spy.clipboards, [png], "the copied image never reached the remote clipboard")
        XCTAssertEqual(spy.sent, [[0x16]], "ctrl-V must follow, or nothing pastes")
    }

    /// Photos hands over HEIC/JPEG as readily as PNG, and the far end reads the
    /// clipboard as PNG — so anything else has to be converted before it ships.
    func testNonPNGImageIsConvertedBeforeSending() async throws {
        let (vc, spy) = try await makeVC()
        let jpeg = UIImage(data: png)!.jpegData(compressionQuality: 0.9)!
        UIPasteboard.general.setData(jpeg, forPasteboardType: UTType.jpeg.identifier)

        vc.pasteImage(then: [0x16])

        XCTAssertEqual(spy.clipboards.count, 1, "a JPEG on the pasteboard shipped nothing")
        XCTAssertEqual(spy.clipboards.first?.prefix(4).map { $0 }, [0x89, 0x50, 0x4e, 0x47],
            "shipped bytes must be PNG — Claude Code asks the clipboard for «class PNGf»")
    }

    /// Text on the clipboard must not be read or shipped (and must not trigger iOS's
    /// paste prompt).
    func testTextOnTheClipboardShipsNoImage() async throws {
        let (vc, spy) = try await makeVC()
        UIPasteboard.general.string = "not an image"

        vc.pasteImage(then: [0x16])

        XCTAssertEqual(spy.clipboards, [])
        XCTAssertEqual(spy.sent, [[0x16]])
    }

    /// Nothing image-shaped on the pasteboard: still send the keystroke — the remote
    /// clipboard may already hold the image.
    func testKeystrokeGoesOutEvenWithNoImageCopied() async throws {
        let (vc, spy) = try await makeVC()
        UIPasteboard.general.items = []

        vc.pasteImage(then: [0x16])

        XCTAssertEqual(spy.clipboards, [])
        XCTAssertEqual(spy.sent, [[0x16]])
    }

    /// #262 QA #79: SwiftTerm's paste (Cmd-V, edit menu) with ctrl armed sent one control
    /// byte of the opener, then the text unbracketed — every line ran — and it carried an
    /// injected closer. It now leaves as ONE sanitized bracketed frame and leaves ctrl
    /// armed for the next typed key.
    func testCtrlArmedPasteGoesOutWholeBracketedAndSanitized() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")   // the shell turned bracketed paste on, as zsh does
        try await Task.sleep(nanoseconds: 50_000_000)
        let bar = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? ShortcutBar }.first)
        bar.onKey?(ShortcutKey(id: "ctrl", label: "ctrl", kind: .ctrl))
        XCTAssertTrue(bar.ctrlArmed, "precondition: ctrl armed")
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        UIPasteboard.general.string = "a \u{1b}[201~ rm -rf x\r"

        tv.paste(nil)

        XCTAssertEqual(spy.sent, [Array("\u{1b}[200~a [201~ rm -rf x\r\u{1b}[201~".utf8)],
                       "the paste was cut by the armed ctrl or kept the injected closer")
        XCTAssertTrue(bar.ctrlArmed, "a paste consumed the modifier meant for a typed key")
        vc.send(source: tv, data: [0x63][...])
        XCTAssertEqual(spy.sent.last, [0x03], "ctrl no longer applies to the next key")
    }

    /// #315 QA #122: an armed ctrl hit the first byte of ANY outbound frame, so a
    /// terminal reply (nvim's OSC 11 colour reply at startup) or an arrow key went out
    /// as one garbage control byte. ESC-led frames now pass through whole and keep the
    /// arm for the next typed key.
    func testCtrlArmedLeavesEscLedFramesWholeAndStaysArmed() async throws {
        let (vc, spy) = try await makeVC()
        let bar = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? ShortcutBar }.first)
        bar.onKey?(ShortcutKey(id: "ctrl", label: "ctrl", kind: .ctrl))
        XCTAssertTrue(bar.ctrlArmed, "precondition: ctrl armed")
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)

        let reply = Array("\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{1b}\\".utf8)
        vc.send(source: tv, data: reply[...])
        XCTAssertEqual(spy.sent.last, reply, "the OSC reply was mangled by the armed ctrl")
        XCTAssertTrue(bar.ctrlArmed, "a terminal reply consumed the arm")

        let up: [UInt8] = [0x1b, 0x5b, 0x41]
        vc.send(source: tv, data: up[...])
        XCTAssertEqual(spy.sent.last, up, "an arrow key was mangled by the armed ctrl")
        XCTAssertTrue(bar.ctrlArmed, "an arrow key consumed the arm")

        vc.send(source: tv, data: [0x61][...])
        XCTAssertEqual(spy.sent.last, [0x01], "ctrl no longer applies to the typed key")
        XCTAssertFalse(bar.ctrlArmed, "the typed key must disarm ctrl")
    }

    /// The compact keyboard's return is a newline like Slack's: ESC CR on the wire, whole
    /// through the host's send (submitting is the bar's enter).
    func testCompactKeyboardReturnSendsMetaEnter() async throws {
        let saved = TerminalKeyboard.hardwareKeyboardConnected
        TerminalKeyboard.hardwareKeyboardConnected = { false }
        defer { TerminalKeyboard.hardwareKeyboardConnected = saved }
        try XCTSkipUnless(TerminalKeyboard.appliesHere, "iPhone only")
        let (vc, spy) = try await makeVC()
        let kb = try XCTUnwrap(vc.keyboardInputView as? TerminalKeyboard)
        let before = spy.sent.count
        kb.press(.ret)
        XCTAssertEqual(Array(spy.sent[before...]), [[0x1b, 0x0d]])
    }

    /// The compact keyboard's space-bar trackpad: each step is a left or right arrow, in
    /// the cursor-key mode the program set, never up or down (a line move sends nothing:
    /// a shell's up and down are history); the word ends there.
    func testCompactKeyboardTrackpadSendsLeftAndRightArrows() async throws {
        let saved = TerminalKeyboard.hardwareKeyboardConnected
        TerminalKeyboard.hardwareKeyboardConnected = { false }
        defer { TerminalKeyboard.hardwareKeyboardConnected = saved }
        try XCTSkipUnless(TerminalKeyboard.appliesHere, "iPhone only")
        let (vc, spy) = try await makeVC()
        let kb = try XCTUnwrap(vc.keyboardInputView as? TerminalKeyboard)
        kb.press(.char("g"))
        XCTAssertEqual(kb.word, "g")
        var before = spy.sent.count
        kb.caret(-2)
        kb.caret(1)
        XCTAssertEqual(Array(spy.sent[before...]), [[0x1b, 0x5b, 0x44, 0x1b, 0x5b, 0x44], [0x1b, 0x5b, 0x43]])
        XCTAssertEqual(kb.word, "", "a caret move ends the word, as an arrow does")
        before = spy.sent.count
        kb.line(-2)
        kb.line(3)
        XCTAssertEqual(spy.sent.count, before, "no up or down arrows")

        spy.emit("\u{1b}[?1h")   // DECCKM: application cursor keys (vim, less)
        try await Task.sleep(nanoseconds: 50_000_000)
        before = spy.sent.count
        kb.caret(-1)
        kb.caret(1)
        XCTAssertEqual(Array(spy.sent[before...]), [[0x1b, 0x4f, 0x44], [0x1b, 0x4f, 0x43]])
    }

    /// #320 QA #126: only a single typed ASCII byte takes the armed ctrl. Multi-byte text
    /// (é was sent as 0x03 = ^C) passes through whole and keeps the arm.
    func testCtrlArmedAppliesOnlyToSingleAsciiByte() async throws {
        let (vc, spy) = try await makeVC()
        let bar = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? ShortcutBar }.first)
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        bar.onKey?(ShortcutKey(id: "ctrl", label: "ctrl", kind: .ctrl))
        XCTAssertTrue(bar.ctrlArmed, "precondition: ctrl armed")

        for text in ["é", "😀"] {
            let bytes = Array(text.utf8)
            vc.send(source: tv, data: bytes[...])
            XCTAssertEqual(spy.sent.last, bytes, "\(text) was mangled by the armed ctrl")
            XCTAssertTrue(bar.ctrlArmed, "\(text) consumed the arm")
        }

        vc.send(source: tv, data: Array("hi".utf8)[...])
        XCTAssertEqual(spy.sent.last, [0x68, 0x69], "two ASCII bytes in one frame must go out whole")
        XCTAssertTrue(bar.ctrlArmed, "a two-byte frame consumed the arm")

        vc.send(source: tv, data: [0x7f][...])
        XCTAssertEqual(spy.sent.last, [0x7f], "a lone DEL must go out unchanged, not as ^_")
        XCTAssertTrue(bar.ctrlArmed, "a lone DEL consumed the arm")
        vc.send(source: tv, data: [0x61][...])
        XCTAssertEqual(spy.sent.last, [0x01], "ctrl must still apply after a DEL")
        XCTAssertFalse(bar.ctrlArmed, "the typed key must disarm ctrl")
        bar.onKey?(ShortcutKey(id: "ctrl", label: "ctrl", kind: .ctrl))
        XCTAssertTrue(bar.ctrlArmed, "precondition: ctrl re-armed")
        vc.send(source: tv, data: [0x7e][...])
        XCTAssertEqual(spy.sent.last, [0x1e], "ctrl+~ (0x7e, top of the chord range) must send 0x1e")
        XCTAssertFalse(bar.ctrlArmed, "ctrl+~ must disarm ctrl")
        // #1009: the lone-Esc row is in testCtrlArmedRowsSpendTheArm, on a shared arm.

        bar.onKey?(ShortcutKey(id: "ctrl", label: "ctrl", kind: .ctrl))
        XCTAssertTrue(bar.ctrlArmed, "precondition: ctrl re-armed")
        vc.send(source: tv, data: [0x61][...])
        XCTAssertEqual(spy.sent.last, [0x01], "ctrl no longer applies to the typed key")
        XCTAssertFalse(bar.ctrlArmed, "the typed key must disarm ctrl")
    }

    /// #321 QA #126: under kitty flag 8 a typed key is ESC[97u, so the armed ctrl never applied and
    /// the bar button stayed lit. It now goes in the modifier field and disarms; a release keeps it.
    func testCtrlArmedAppliesToKittyKeyReportAndDisarms() async throws {
        let (vc, spy) = try await makeVC()
        let (bar, tv) = try barAndTerminal(vc)
        bar.onKey?(try catalogKey("ctrl"))
        XCTAssertTrue(bar.ctrlArmed, "precondition: ctrl armed")

        let release = Array("\u{1b}[97;1:3u".utf8)
        vc.send(source: tv, data: release[...])
        XCTAssertEqual(spy.sent.last, release, "a key release was modified")
        XCTAssertTrue(bar.ctrlArmed, "a key release consumed the arm")

        vc.send(source: tv, data: Array("\u{1b}[97u".utf8)[...])
        XCTAssertEqual(spy.sent.last, Array("\u{1b}[97;5u".utf8), "ctrl never reached the kitty key")
        XCTAssertFalse(bar.ctrlArmed, "the kitty key must disarm ctrl")
        vc.send(source: tv, data: Array("\u{1b}[98u".utf8)[...])
        XCTAssertEqual(spy.sent.last, Array("\u{1b}[98u".utf8), "a spent ctrl still applied")

        bar.onKey?(try catalogKey("alt"))
        vc.send(source: tv, data: Array("\u{1b}[98;2u".utf8)[...])
        XCTAssertEqual(spy.sent.last, Array("\u{1b}[98;4u".utf8), "alt+shift+b")
        XCTAssertEqual(bar.modes[.alt], .off, "the kitty key must spend a once alt")
    }

    /// #1009 (QA #138): every armed-ctrl row, typed or a bar key, as the code sends it today.
    /// An Esc, enter or tab sent unarmed looks the same on the wire, so each row arms through
    /// the one `arm` that also checks it: dropping the arm fails every row, not just one.
    func testCtrlArmedRowsSpendTheArm() async throws {
        let (vc, spy) = try await makeVC()
        let (bar, tv) = try barAndTerminal(vc)
        let ctrl = try catalogKey("ctrl")
        func arm(_ row: String) {
            bar.onKey?(ctrl)
            XCTAssertEqual(bar.modes[.ctrl], .once, "precondition for \(row): ctrl armed once")
        }
        let typed: [(UInt8, [UInt8], String)] = [
            (0x20, [0x00], "ctrl+space is NUL"),
            (0x32, [0x00], "#1047: ctrl+2 is NUL"),
            (0x33, [0x1b], "#1047: ctrl+3 is ESC"),
            (0x34, [0x1c], "#1047: ctrl+4 is FS"),
            (0x35, [0x1d], "#1047: ctrl+5 is GS"),
            (0x36, [0x1e], "#1047: ctrl+6 is RS"),
            (0x37, [0x1f], "#1047: ctrl+7 is US"),
            (0x38, [0x7f], "#1047: ctrl+8 is DEL"),
            (0x3f, [0x7f], "#1047: ctrl+? is DEL"),
            (0x0d, [0x0d], "ctrl+enter is CR"),
            (0x09, [0x09], "ctrl+tab is TAB"),
            (0x1b, [0x1b], "a lone Esc goes out unchanged"),
        ]
        for (key, out, row) in typed {
            arm(row)
            vc.send(source: tv, data: [key][...])
            XCTAssertEqual(spy.sent.last, out, row)
            XCTAssertEqual(bar.modes[.ctrl], .off, "\(row): the key must spend the arm")
        }
        // Single-byte bar keys take ctrl like a typed byte and spend it.
        for (id, out) in [("esc", [0x1b]), ("enter", [0x0d]), ("tab", [0x09]), ("ctlc", [0x03])] as [(String, [UInt8])] {
            arm("bar \(id)")
            bar.onKey?(try catalogKey(id))
            XCTAssertEqual(spy.sent.last, out, "bar \(id)")
            XCTAssertEqual(bar.modes[.ctrl], .off, "bar \(id) must spend the arm")
        }
        // Multi-byte bar keys that aren't a CSI cursor key bypass ctrl: unchanged, arm kept.
        arm("the bar bypass")
        for id in ["wordBack", "stab", "snl", "delLine"] {
            let key = try XCTUnwrap((Shortcuts.catalog + Shortcuts.hostOnly).first { $0.id == id }, id)
            bar.onKey?(key)
            XCTAssertEqual(spy.sent.last, key.bytes, "bar \(id) must go out unchanged")
            XCTAssertEqual(bar.modes[.ctrl], .once, "bar \(id) spent the arm")
        }
        vc.send(source: tv, data: [0x61][...])
        XCTAssertEqual(spy.sent.last, [0x01], "ctrl no longer applies after the bypassed bar keys")
    }

    // MARK: sticky ctrl / alt / shift (#450)

    private func barAndTerminal(_ vc: TerminalHostVC) throws -> (ShortcutBar, TerminalView) {
        (try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? ShortcutBar }.first),
         try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first))
    }
    private func catalogKey(_ id: String) throws -> ShortcutKey {
        try XCTUnwrap(Shortcuts.catalog.first { $0.id == id })
    }

    /// A double tap locks ctrl: ctrl+k then ctrl+d without re-arming, and it stays lit
    /// until a third tap turns it off.
    func testDoubleTappedCtrlStaysLockedAcrossKeys() async throws {
        let (vc, spy) = try await makeVC()
        let (bar, tv) = try barAndTerminal(vc)
        let ctrl = try catalogKey("ctrl")
        bar.onKey?(ctrl)
        XCTAssertEqual(bar.modes[.ctrl], .once)
        bar.onKey?(ctrl)
        XCTAssertEqual(bar.modes[.ctrl], .locked, "a quick second tap must lock ctrl")

        vc.send(source: tv, data: [0x6b][...])
        XCTAssertEqual(spy.sent.last, [0x0b])
        vc.send(source: tv, data: [0x64][...])
        XCTAssertEqual(spy.sent.last, [0x04], "a locked ctrl must apply to the second key too")
        XCTAssertEqual(bar.modes[.ctrl], .locked, "a key spent a locked ctrl")

        bar.onKey?(ctrl)
        XCTAssertEqual(bar.modes[.ctrl], .off, "a tap on a locked ctrl turns it off")
        vc.send(source: tv, data: [0x6b][...])
        XCTAssertEqual(spy.sent.last, [0x6b])
    }

    /// Once modifiers apply to the bar's own keys and are spent by them: ctrl+← is xterm's
    /// ESC[1;5D, shift+tab back-tab, shift+enter the newline; alt+typed b is meta-b.
    func testOnceModifiersApplyToBarKeysAndTypedKeys() async throws {
        let (vc, spy) = try await makeVC()
        let (bar, tv) = try barAndTerminal(vc)

        bar.onKey?(try catalogKey("left"))
        XCTAssertEqual(spy.sent.last, Array("\u{1b}[D".utf8), "an unmodified bar key goes out as is")

        bar.onKey?(try catalogKey("ctrl"))
        bar.onKey?(try catalogKey("left"))
        XCTAssertEqual(spy.sent.last, Array("\u{1b}[1;5D".utf8))
        XCTAssertFalse(bar.ctrlArmed, "the bar key must spend a once ctrl")

        bar.onKey?(try catalogKey("shift"))
        XCTAssertEqual(bar.modes[.shift], .once)
        bar.onKey?(try catalogKey("tab"))
        XCTAssertEqual(spy.sent.last, [0x1b, 0x5b, 0x5a], "shift+tab must be back-tab")
        XCTAssertEqual(bar.modes[.shift], .off)

        bar.onKey?(try catalogKey("shift"))
        bar.onKey?(try catalogKey("enter"))
        XCTAssertEqual(spy.sent.last, TerminalKeyboard.newlineBytes, "shift+enter must be the newline")
        XCTAssertEqual(bar.modes[.shift], .off)

        bar.onKey?(try catalogKey("alt"))
        XCTAssertEqual(bar.modes[.alt], .once)
        vc.send(source: tv, data: [0x62][...])
        XCTAssertEqual(spy.sent.last, [0x1b, 0x62], "alt+b must be meta-b")
        XCTAssertEqual(bar.modes[.alt], .off)
    }

    /// QA #277: a once ctrl/alt with the keyboard down raises it only after the double-tap
    /// window — the bar rides the rising keyboard, so a second tap landed on its bottom row
    /// and typed a chord instead of locking. A lock raises at once; a modifier spent before
    /// the window ends raises nothing. shift never raises, once or locked.
    func testOnceModifierRaisesKeyboardOnlyAfterDoubleTapWindow() async throws {
        let (vc, _) = try await makeVC()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let (bar, tv) = try barAndTerminal(vc)
        let ctrl = try catalogKey("ctrl"), alt = try catalogKey("alt")
        let settle = UInt64((ShiftState.doubleTapWindow + 0.2) * 1_000_000_000)

        let shift = try catalogKey("shift")
        bar.onKey?(shift)
        XCTAssertEqual(bar.modes[.shift], .once)
        XCTAssertFalse(tv.isFirstResponder, "a once shift raised the keyboard")
        try await Task.sleep(nanoseconds: settle)
        XCTAssertFalse(tv.isFirstResponder, "a once shift raised the keyboard after the window")
        bar.onKey?(shift)   // past the window: turns it off
        bar.onKey?(shift)
        bar.onKey?(shift)
        XCTAssertEqual(bar.modes[.shift], .locked, "precondition: a quick double tap locks shift")
        XCTAssertFalse(tv.isFirstResponder, "a locked shift raised the keyboard")
        try await Task.sleep(nanoseconds: settle)
        XCTAssertFalse(tv.isFirstResponder, "a locked shift raised the keyboard after the window")
        bar.onKey?(shift)

        bar.onKey?(ctrl)
        XCTAssertFalse(tv.isFirstResponder, "a once ctrl raised the keyboard under the next tap")
        bar.onKey?(ctrl)
        XCTAssertEqual(bar.modes[.ctrl], .locked, "a quick second tap must lock ctrl")
        XCTAssertTrue(tv.isFirstResponder, "a locked ctrl must raise the keyboard at once")
        bar.onKey?(ctrl)
        _ = tv.resignFirstResponder()

        bar.onKey?(alt)
        bar.onKey?(try catalogKey("left"))   // spends alt inside the window
        try await Task.sleep(nanoseconds: settle)
        XCTAssertFalse(tv.isFirstResponder, "a spent alt still raised the keyboard")

        bar.onKey?(alt)
        XCTAssertFalse(tv.isFirstResponder)
        try await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(bar.modes[.alt], .once)
        XCTAssertTrue(tv.isFirstResponder, "a once alt must raise the keyboard after the window")
        _ = tv.resignFirstResponder()
    }

    /// The readline edits on the terminal bar go out as their keystrokes, one send each.
    func testBarEditKeysSendTheirKeystrokes() async throws {
        let (vc, spy) = try await makeVC()
        let (bar, _) = try barAndTerminal(vc)
        for id in ["wordNext", "wordBack", "delWord", "delHome", "delEnd", "delLine", "wordEnd", "delAll"] {
            let k = try XCTUnwrap(Shortcuts.Bar.terminal.catalog.first { $0.id == id }, id)
            let before = spy.sent.count
            bar.onKey?(k)
            XCTAssertEqual(Array(spy.sent[before...]), [k.bytes], id)
        }
        XCTAssertEqual(spy.sent.suffix(8), [[0x1b, 0x66], [0x1b, 0x62], [0x17], [0x15], [0x0b], [0x05, 0x15],
                                            [0x1b, 0x66], [0x05, 0x15]])
    }

    /// Copy line (#603) puts the caret's line off the screen, soft wraps joined and trailing
    /// blanks trimmed, on the pasteboard and in the history with a note, and sends nothing;
    /// cut line copies it so, then sends delete line's ^E ^U. An empty line copies nothing.
    func testBarCopyAndCutLineTakeTheCaretsLine() async throws {
        let (vc, spy) = try await makeVC()
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePasteTests-\(UUID())")
        defer { UIPasteboard.remove(withName: pb.name); try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(dir: dir)
        vc.pasteboard = pb
        vc.history = h
        let (bar, tv) = try barAndTerminal(vc)
        let long = String(repeating: "x", count: tv.getTerminal().cols)
        tv.feed(text: "out\r\n$ echo " + long + " yz   ")
        try await Task.sleep(nanoseconds: 100_000_000)   // the caret moves on SwiftTerm's display pass
        let copy = try XCTUnwrap(Shortcuts.Bar.terminal.catalog.first { $0.id == "copyLine" })
        let cut = try XCTUnwrap(Shortcuts.Bar.terminal.catalog.first { $0.id == "cutLine" })
        let line = "$ echo " + long + " yz"

        bar.onKey?(copy)
        XCTAssertEqual(pb.string, line)
        XCTAssertEqual(h.clips.map(\.text), [line])
        XCTAssertEqual(spy.sent, [], "copy sends nothing")
        let note = vc.view.subviews.flatMap(\.subviews).compactMap { ($0 as? UILabel)?.text }.first { $0.hasPrefix("Copied line") }
        XCTAssertEqual(note, "Copied line\n" + line.prefix(60) + "…")

        pb.string = "elsewhere"
        bar.onKey?(cut)
        XCTAssertEqual(pb.string, line)
        XCTAssertEqual(spy.sent, [[0x05, 0x15]])
        XCTAssertEqual(h.clips.map(\.text), [line], "the same line once")
        let cutNote = vc.view.subviews.flatMap(\.subviews).compactMap { ($0 as? UILabel)?.text }.first { $0.hasPrefix("Cut line") }
        XCTAssertEqual(cutNote, "Cut line\n" + line.prefix(60) + "…", "a cut says so (#654)")

        tv.feed(text: "\r\n")
        try await Task.sleep(nanoseconds: 100_000_000)
        pb.string = "kept"
        bar.onKey?(copy)
        bar.onKey?(cut)
        XCTAssertEqual(pb.string, "kept", "an empty line leaves the clip be")
        XCTAssertEqual(spy.sent, [[0x05, 0x15], [0x05, 0x15]])
    }

    /// Cells a TUI skips with cursor moves (Claude Code's input box) are never written and
    /// read as NULs: both copies take them as blanks (#603 QA: "word8\0word9" came out glued).
    /// The key's copy trims the row's indent too, the long press's `oneLine` always did.
    func testCopiesTakeCursorMoveGapsAsBlanks() async throws {
        let (vc, _) = try await makeVC()
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePasteTests-\(UUID())")
        defer { UIPasteboard.remove(withName: pb.name); try? FileManager.default.removeItem(at: dir) }
        vc.pasteboard = pb
        vc.history = ClipboardHistory(dir: dir)
        let (bar, tv) = try barAndTerminal(vc)
        tv.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[2Cword1\u{1b}[2Cword2\u{1b}[1Cend")
        try await Task.sleep(nanoseconds: 100_000_000)   // the caret moves on SwiftTerm's display pass

        bar.onKey?(try XCTUnwrap(Shortcuts.Bar.terminal.catalog.first { $0.id == "copyLine" }))
        XCTAssertEqual(pb.string, "word1  word2 end", "the key's copy line")
        pb.string = ""
        vc.copyLine(at: rowPoint(tv, 0))
        XCTAssertEqual(pb.string, "word1  word2 end", "the long press")
    }

    /// The panel keeps two rows at least: with less room than that between the safe area's top
    /// and the bar (landscape, keyboard up) the keyboard goes as it opens, and comes back as it
    /// closes, by the key, its keyboard button or a pick; only a keyboard the panel lowered.
    func testClipsPanelLowersAKeyboardThatLeavesItNoRoomAndRaisesItBack() async throws {
        let (vc, _) = try await makeVC()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePasteTests-\(UUID())")
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        defer { UIPasteboard.remove(withName: pb.name); try? FileManager.default.removeItem(at: dir) }
        vc.pasteboard = pb
        vc.history = ClipboardHistory(dir: dir)
        pb.string = "echo hi"
        vc.history?.record("echo hi", from: pb)
        let (bar, tv) = try barAndTerminal(vc)
        let key = try XCTUnwrap(Shortcuts.Bar.terminal.catalog.first { $0.id == Shortcuts.clipboard.id })
        var room: CGFloat = 81   // QA's landscape: a 39 pt list under the 42 pt header
        vc.clipsRoom = { room }

        XCTAssertTrue(tv.becomeFirstResponder())
        bar.onKey?(key)
        XCTAssertNotNil(vc.clipsPanel)
        XCTAssertFalse(tv.isFirstResponder, "no room: the keyboard goes")
        bar.onKey?(key)
        XCTAssertTrue(tv.isFirstResponder, "the key again: the keyboard back")

        bar.onKey?(key)
        XCTAssertFalse(tv.isFirstResponder)
        try XCTUnwrap(vc.clipsPanel).onClose?()
        XCTAssertTrue(tv.isFirstResponder, "its keyboard button: the keyboard back")

        bar.onKey?(key)
        let panel = try XCTUnwrap(vc.clipsPanel)
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertTrue(tv.isFirstResponder, "a pick: the keyboard back")

        room = 260   // portrait, or the keyboard down
        bar.onKey?(key)
        XCTAssertTrue(tv.isFirstResponder, "room enough: the keyboard stays")
        bar.onKey?(key)
        XCTAssertTrue(tv.isFirstResponder)

        _ = tv.resignFirstResponder()
        room = 81
        bar.onKey?(key)
        bar.onKey?(key)
        XCTAssertFalse(tv.isFirstResponder, "a keyboard the panel didn't lower isn't raised")
    }

    /// The clipboard key (#603) opens the history's panel over the terminal; a text pick goes
    /// out as the paste key's bracketed paste and is copied, an image pick is only copied. Each
    /// pick closes the panel. A named pasteboard and a throwaway store.
    func testBarClipboardKeySendsAPickedTextClipAndCopiesAnImage() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")   // the shell turned bracketed paste on
        try await Task.sleep(nanoseconds: 50_000_000)
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePasteTests-\(UUID())")
        defer { UIPasteboard.remove(withName: pb.name); try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(dir: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("source.png")
        try png.write(to: source)
        let image = ClipboardHistory.Clip(image: try XCTUnwrap(h.storeImage(at: source)), date: Date())
        pb.string = "echo hi"
        h.record("echo hi", from: pb)
        vc.pasteboard = pb
        vc.history = h
        let (bar, _) = try barAndTerminal(vc)
        let key = try XCTUnwrap(Shortcuts.Bar.terminal.catalog.first { $0.id == Shortcuts.clipboard.id })

        bar.onKey?(key)
        var panel = try XCTUnwrap(vc.clipsPanel)
        XCTAssertTrue(panel.superview === vc.view)
        XCTAssertEqual(panel.clips.first?.text, "echo hi")
        XCTAssertEqual(spy.sent, [], "opening the panel sends nothing")
        pb.items = []
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(spy.sent, [Array("\u{1b}[200~echo hi\u{1b}[201~".utf8)], "the paste key's route")
        XCTAssertEqual(pb.string, "echo hi")
        XCTAssertNil(vc.clipsPanel, "a pick closes the panel")

        bar.onKey?(key)
        panel = try XCTUnwrap(vc.clipsPanel)
        panel.onPick?(image)   // the image's row
        XCTAssertEqual(spy.sent.count, 1, "an image is never sent")
        XCTAssertTrue(pb.hasImages)
        XCTAssertFalse(pb.hasStrings)
        XCTAssertNil(vc.clipsPanel)

        bar.onKey?(key)
        XCTAssertNotNil(vc.clipsPanel)
        bar.onKey?(key)
        XCTAssertNil(vc.clipsPanel, "the key again: the terminal back")
    }

    /// The snippets key (#609) opens their panel over the terminal; a pick goes out resolved as
    /// one bracketed paste, `{clipboard}` from the pasteboard given, then ← back to `{cursor}`:
    /// never a CR or LF, so nothing runs. A throwaway store and a named pasteboard.
    func testBarSnippetsKeySendsAPickAsOnePasteAndArrowsBackToTheCursor() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")   // the shell turned bracketed paste on
        try await Task.sleep(nanoseconds: 50_000_000)
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePasteTests-\(UUID())")
        defer { UIPasteboard.remove(withName: pb.name); try? FileManager.default.removeItem(at: dir) }
        let store = SnippetStore(url: dir.appendingPathComponent("snippets.json"))
        store.put(.init(name: "Commit", text: "git commit -m \"{cursor}\" # {clipboard}"), replacing: nil)
        pb.string = "wip"
        vc.pasteboard = pb
        vc.snippets = store
        let (bar, _) = try barAndTerminal(vc)
        let key = try XCTUnwrap(Shortcuts.Bar.terminal.catalog.first { $0.id == Shortcuts.snippets.id })

        bar.onKey?(key)
        let panel = try XCTUnwrap(vc.snippetsPanel)
        XCTAssertTrue(panel.superview === vc.view)
        XCTAssertEqual(spy.sent, [], "opening the panel sends nothing")
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 0, section: 0))
        let left: [UInt8] = [0x1b, 0x5b, 0x44]
        XCTAssertEqual(spy.sent, [Array("\u{1b}[200~git commit -m \"\" # wip\u{1b}[201~".utf8),
                                  Array([left, left, left, left, left, left, left].joined())])
        XCTAssertFalse(spy.sent.joined().contains { $0 == 0x0d || $0 == 0x0a }, "never a return")
        XCTAssertNil(vc.snippetsPanel, "a pick closes the panel")

        bar.onKey?(key)
        XCTAssertNotNil(vc.snippetsPanel)
        bar.onKey?(key)
        XCTAssertNil(vc.snippetsPanel, "the key again: the terminal back")
    }

    /// The terminal's keyboard takes every Keyboard setting the extension's does (#692), read as
    /// it rises: the look, Caps Lock, Preview, Keys Beside Space, Key Size, Numbers: Key (a row
    /// shorter) and the Languages, the language key typing Cyrillic into the pty. Never a globe,
    /// and the bar keeps its rows whatever Toolbar Rows says. A throwaway App Group.
    func testTheTerminalsKeyboardSharesTheKeyboardSettings() async throws {
        let saved = (TerminalKeyboard.hardwareKeyboardConnected, KeyboardSettings.store)
        TerminalKeyboard.hardwareKeyboardConnected = { false }
        let suite = "ImagePasteTests.shared.\(UUID())", group = try XCTUnwrap(UserDefaults(suiteName: suite))
        KeyboardSettings.store = { group }
        defer {
            (TerminalKeyboard.hardwareKeyboardConnected, KeyboardSettings.store) = saved
            group.removePersistentDomain(forName: suite)
        }
        try XCTSkipUnless(TerminalKeyboard.appliesHere, "iPhone only")
        let (vc, spy) = try await makeVC()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let (bar, tv) = try barAndTerminal(vc)
        let rows = bar.intrinsicContentSize.height
        typealias K = KeyboardSettings.Key
        for (key, value) in [(K.theme, "light"), (K.toolbarTheme, "neon"), (K.accent, "blue"), (K.keySize, "large"),
                             (K.numbers, "key"), (K.toolbarRows, "one"), (K.bottomHidden, "/?"),
                             (K.languages, "bulgarian,english")] { group.set(value, forKey: key) }
        group.set(false, forKey: K.capsLock)
        group.set(false, forKey: K.characterPreview)

        XCTAssertTrue(tv.becomeFirstResponder())
        let kb = try XCTUnwrap(vc.keyboardInputView as? TerminalKeyboard)
        XCTAssertEqual(kb.settings, KeyboardSettings(group), "every setting, as the extension reads them")
        XCTAssertEqual(kb.settings.keySize, .large)
        XCTAssertEqual(TerminalKeyboard.Style.palette, TerminalKeyboard.Style.Palette(kb.settings))
        XCTAssertEqual(kb.languages, [.english, .bulgarian])
        XCTAssertEqual(kb.layout, .english, "English first while it's on")
        XCTAssertTrue(kb.numbersKey)
        XCTAssertEqual(kb.shownKeys.count, 4, "no digit row")
        XCTAssertEqual(kb.shownKeys.last, [.numbers, .language, .char("."), .char(","), .space, .emoji, .ret],
                       "123, the language key, Keys Beside Space; no globe")
        XCTAssertFalse(kb.showsGlobe)
        XCTAssertEqual(bar.intrinsicContentSize.height, rows, "the bar's rows, whatever Toolbar Rows says")

        kb.press(.language)
        XCTAssertEqual(kb.layout, .bulgarian)
        let before = spy.sent.count
        kb.press(.char("я"))
        XCTAssertEqual(Array(spy.sent[before...]), [Array("я".utf8)], "typed, not pasted")
        _ = tv.resignFirstResponder()
        XCTAssertTrue(tv.becomeFirstResponder())
        XCTAssertEqual(kb.layout, .bulgarian, "kept while it's on")
        group.set("english", forKey: K.languages)
        group.set("row", forKey: K.numbers)
        _ = tv.resignFirstResponder()
        XCTAssertTrue(tv.becomeFirstResponder())
        XCTAssertEqual(kb.layout, .english, "back to one that's on")
        XCTAssertNil(kb.nextLanguage)
        XCTAssertEqual(kb.shownKeys.first, TerminalKeyboard.rows[0], "Row: the digits back")
        XCTAssertFalse(kb.shownKeys.joined().contains(.language))
    }

    /// Hide Toolbar on the Numpad in the terminal (#692), as in the extension: the bar hides while
    /// the numpad shows and lends the keys its height, then comes back with the letters, or as the
    /// keyboard goes down. Off, the bar stays.
    func testHideToolbarOnTheNumpadHidesTheTerminalsBar() async throws {
        let saved = (TerminalKeyboard.hardwareKeyboardConnected, KeyboardSettings.store)
        TerminalKeyboard.hardwareKeyboardConnected = { false }
        let suite = "ImagePasteTests.numpad.\(UUID())", group = try XCTUnwrap(UserDefaults(suiteName: suite))
        KeyboardSettings.store = { group }
        defer {
            (TerminalKeyboard.hardwareKeyboardConnected, KeyboardSettings.store) = saved
            group.removePersistentDomain(forName: suite)
        }
        try XCTSkipUnless(TerminalKeyboard.appliesHere, "iPhone only")
        let (vc, _) = try await makeVC()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let (bar, tv) = try barAndTerminal(vc)
        group.set(true, forKey: KeyboardSettings.Key.numpadHidesToolbar)
        XCTAssertTrue(tv.becomeFirstResponder())
        let kb = try XCTUnwrap(vc.keyboardInputView as? TerminalKeyboard)
        vc.view.layoutIfNeeded()
        XCTAssertGreaterThan(bar.bounds.height, 0)
        // The keyboard's frame as iOS posts it, its height the keys' and what they were lent;
        // where the bar's place starts (its top, hidden or not) and the terminal's size and lift.
        let keys: CGFloat = 300
        func frame(line: UInt = #line) -> (top: CGFloat, size: CGSize, lift: CGFloat) {
            let h = keys + kb.lentHeight
            kb.frame.size.height = h   // kbChange takes a keyboard in a window at its own height
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: window.bounds.maxY - h, width: window.bounds.width, height: h))])
            vc.view.layoutIfNeeded()
            return (bar.frame.minY, tv.bounds.size, tv.transform.ty)
        }
        tv.feed(text: String(repeating: "$ ls\r\n", count: 60))   // content to the bottom: a full lift
        let letters = frame()

        kb.showNumpad(true, animated: false)   // the menu's Numbers, with Row
        XCTAssertTrue(kb.showsNumpad)
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(kb.lentHeight, bar.bounds.height)
        let numpad = frame()
        XCTAssertEqual(numpad.top, letters.top, accuracy: 0.5, "the hidden bar's place: the keyboard's top, as before")
        XCTAssertEqual(numpad.size, letters.size, "the grid keeps its size")
        XCTAssertEqual(numpad.lift, letters.lift, accuracy: 0.5, "the content doesn't jump")
        kb.press(.numbers)   // ABC
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(kb.lentHeight, 0)
        let back = frame()
        XCTAssertEqual(back.top, letters.top, accuracy: 0.5)
        XCTAssertEqual(back.lift, letters.lift, accuracy: 0.5)

        kb.showNumpad(true, animated: false)
        XCTAssertTrue(bar.isHidden)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        XCTAssertFalse(kb.showsNumpad, "the letters the next time up")
        XCTAssertFalse(bar.isHidden, "the bar back at rest")
        XCTAssertEqual(kb.lentHeight, 0)

        group.set(false, forKey: KeyboardSettings.Key.numpadHidesToolbar)
        _ = tv.resignFirstResponder()
        XCTAssertTrue(tv.becomeFirstResponder())
        kb.showNumpad(true, animated: false)
        XCTAssertFalse(bar.isHidden, "off: the bar stays")
        XCTAssertEqual(kb.lentHeight, 0)
    }

    /// The menu key (#691), not in the defaults: the system keyboard toggle's menu over the
    /// terminal, the key again or a tap off closing it. The panels with the keyboard down; up,
    /// Prosper's Emoji, Numbers and Appearance too, Next Keyboard with two system keyboards, never
    /// Rewrite. Each pick does its thing and closes the menu; Next Keyboard puts the system's in
    /// Prosper's place till the keyboard next rises, and from the system's, always offered, puts
    /// Prosper's back. Throwaway stores, a named pasteboard, no mic.
    func testBarMenuKeyOpensTheToggleMenuOverTheTerminal() async throws {
        let saved = (TerminalKeyboard.hardwareKeyboardConnected, TerminalHostVC.systemKeyboards, KeyboardSettings.store)
        TerminalKeyboard.hardwareKeyboardConnected = { false }
        let suite = "ImagePasteTests.menu.\(UUID())", group = try XCTUnwrap(UserDefaults(suiteName: suite))
        KeyboardSettings.store = { group }
        var systemKeyboards = 1
        TerminalHostVC.systemKeyboards = { systemKeyboards }
        defer {
            (TerminalKeyboard.hardwareKeyboardConnected, TerminalHostVC.systemKeyboards, KeyboardSettings.store) = saved
            group.removePersistentDomain(forName: suite)
        }
        try XCTSkipUnless(TerminalKeyboard.appliesHere, "iPhone only")
        let (vc, _) = try await makeVC()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePasteTests-\(UUID())")
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        defer { UIPasteboard.remove(withName: pb.name); try? FileManager.default.removeItem(at: dir) }
        vc.pasteboard = pb
        vc.history = ClipboardHistory(dir: dir)
        vc.snippets = SnippetStore(url: dir.appendingPathComponent("snippets.json"))
        vc.quicklinks = QuicklinkStore(url: dir.appendingPathComponent("Quicklinks/quicklinks.json"))
        vc.dictation = nil
        vc.clipsRoom = { 400 }
        let (bar, tv) = try barAndTerminal(vc)
        let key = try XCTUnwrap(Shortcuts.Bar.terminal.catalog.first { $0.id == Shortcuts.menu.id })
        XCTAssertNotNil(UIImage(systemName: try XCTUnwrap(key.systemImage)))
        XCTAssertFalse(Shortcuts.defaults.contains(key), "added in the editor")
        func titles() throws -> [String] { try XCTUnwrap(vc.menuPanel).items.map(\.title) }
        func pick(_ title: String) throws {
            if vc.menuPanel == nil { bar.onKey?(key) }
            try XCTUnwrap(vc.menuPanel?.tiles.first { $0.accessibilityLabel == title }, title).sendActions(for: .touchUpInside)
            XCTAssertNil(vc.menuPanel, "\(title) closes the menu")
        }

        bar.onKey?(key)
        XCTAssertTrue(vc.menuPanel?.superview === vc.view, "over the terminal")
        XCTAssertEqual(try titles(), ["Clipboard", "Snippets", "Quicklinks"], "the keyboard down")
        XCTAssertNil(vc.menuPanel?.hideButton, "no Hide Keyboard with it down (#734)")
        bar.onKey?(key)
        XCTAssertNil(vc.menuPanel, "the key again: the terminal back")

        XCTAssertTrue(tv.becomeFirstResponder())
        let kb = try XCTUnwrap(vc.keyboardInputView as? TerminalKeyboard)
        kb.settings.numbers = .key
        kb.allowsNumbersKey = true
        XCTAssertTrue(kb.numbersKey)
        bar.onKey?(key)
        XCTAssertEqual(try titles(), ["Clipboard", "Snippets", "Quicklinks", "Emoji", "Numbers", "Appearance"],
                       "Numbers beside a 123 key too; one system keyboard: no Next Keyboard")
        try XCTUnwrap(vc.menuPanel).onClose?()
        XCTAssertNil(vc.menuPanel, "a tap off the tiles")
        systemKeyboards = 2
        bar.onKey?(key)
        XCTAssertEqual(try titles(), ["Clipboard", "Snippets", "Quicklinks", "Emoji", "Numbers", "Appearance", "Next Keyboard"])
        for item in try XCTUnwrap(vc.menuPanel).items { XCTAssertNotNil(UIImage(systemName: item.symbol), item.title) }

        try pick("Clipboard")
        XCTAssertNotNil(vc.clipsPanel)
        try pick("Snippets")
        XCTAssertNotNil(vc.snippetsPanel)
        try pick("Quicklinks")
        XCTAssertNotNil(vc.quicklinksPanel)
        try pick("Emoji")
        XCTAssertNil(vc.quicklinksPanel)
        XCTAssertTrue(kb.showsEmoji)
        try pick("Numbers")
        XCTAssertTrue(kb.showsNumpad)
        try pick("Appearance")
        let look = try XCTUnwrap(vc.appearancePanel)
        try XCTUnwrap(look.keys.first { $0.accessibilityLabel == "Light" }).sendActions(for: .touchUpInside)
        XCTAssertEqual(group.string(forKey: KeyboardSettings.Key.theme), "light", "stored for both keyboards")
        XCTAssertEqual(kb.settings.theme, .light)
        XCTAssertFalse(vc.appearancePanel === look, "drawn again")
        try pick("Next Keyboard")
        XCTAssertTrue(tv.isFirstResponder)
        XCTAssertNil(vc.keyboardInputView, "the system's keyboard")
        XCTAssertTrue(tv.becomeFirstResponder())
        XCTAssertNil(vc.keyboardInputView, "a tap while up keeps it")
        bar.onKey?(key)
        XCTAssertEqual(try titles(), ["Clipboard", "Snippets", "Quicklinks", "Next Keyboard"], "the way back")
        systemKeyboards = 1
        try pick("Next Keyboard")
        XCTAssertTrue(vc.keyboardInputView === kb, "Prosper's back, whatever the system has")
        systemKeyboards = 2
        try pick("Next Keyboard")
        XCTAssertNil(vc.keyboardInputView)
        XCTAssertTrue(tv.resignFirstResponder())
        XCTAssertTrue(tv.becomeFirstResponder())
        XCTAssertTrue(vc.keyboardInputView === kb, "Prosper's again the next time up")
        bar.onKey?(key)
        try XCTUnwrap(vc.menuPanel?.hideButton, "Hide Keyboard with it up (#734)").sendActions(for: .touchUpInside)
        XCTAssertNil(vc.menuPanel, "the terminal back")
        XCTAssertFalse(tv.isFirstResponder, "the keyboard down")
    }

    /// The mic key (#604): cold, the service starts in place (no hop, no sheet) and the strip
    /// covers the bar; finished phrases go out as bracketed pastes, spaced, never a newline;
    /// the key again is Done, its final in. Warm, a ping starts it afresh, never taking up a
    /// keyboard's request; ✕ drops the tail, a refusal's note shows, and leaving cancels.
    /// A throwaway store and fake pings: no mic, no SpeechAnalyzer.
    func testBarMicKeyDictatesIntoThePty() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")
        try await Task.sleep(nanoseconds: 50_000_000)
        let store = Dictation.Store(dir: FileManager.default.temporaryDirectory.appendingPathComponent("ImagePasteTests-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let clock = Date()
        var pings: [Dictation.Ping] = [], opened: [URL] = []
        func app(_ id: UUID?, _ phase: Dictation.State.Phase, _ phrases: [String] = [], tail: String = "", note: String? = nil) {
            store.state = Dictation.State(id: id, phase: phase, heartbeat: clock, phrases: phrases, tail: tail, note: note)
        }
        let c = DictationClient(store: store)
        c.polls = false
        c.now = { clock }
        c.ping = { pings.append($0) }
        c.open = { url, done in opened.append(url); app(Dictation.id(from: url), .preparing); done(true) }   // the service's start
        vc.dictation = c
        let (bar, _) = try barAndTerminal(vc)
        let key = try XCTUnwrap(Shortcuts.Bar.terminal.catalog.first { $0.id == Shortcuts.dictate.id })
        func paste(_ s: String) -> [UInt8] { Array("\u{1b}[200~\(s)\u{1b}[201~".utf8) }

        bar.onKey?(key)
        var id = try XCTUnwrap(store.request?.id)
        XCTAssertEqual(opened, [Dictation.url(id)])
        XCTAssertEqual(pings, [], "cold: started in place")
        let strip = vc.dictationStrip
        vc.view.layoutIfNeeded()
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(strip.frame, bar.frame, "over the bar: no mic cap, edge to edge")
        // A bar with the mic cap (#654): the strip stops short of it, so its tap still stops.
        let saved = Shortcuts.shared().string(forKey: Shortcuts.storageKey)
        defer {
            if let saved { Shortcuts.shared().set(saved, forKey: Shortcuts.storageKey) }
            else { Shortcuts.shared().removeObject(forKey: Shortcuts.storageKey) }
        }
        Shortcuts.save([try catalogKey("esc"), Shortcuts.dictate])
        bar.reload()
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        let mic = try XCTUnwrap(bar.capByID[Shortcuts.dictate.id])
        let micFrame = mic.convert(mic.bounds, to: vc.view)
        XCTAssertEqual(strip.frame.minX, bar.frame.minX)
        XCTAssertEqual(strip.frame.height, bar.frame.height)
        XCTAssertEqual(strip.frame.maxX, micFrame.minX - 6, accuracy: 0.5, "up to the mic cap, still tappable")
        XCTAssertNil(strip.hitTest(vc.view.convert(CGPoint(x: micFrame.midX, y: micFrame.midY), to: strip), with: nil))
        XCTAssertEqual(strip.label.text, "Starting the mic…", "taken up, not opening Prosper")
        // The mic cap first (#654): the strip takes the wider side, after the cap, not 0 pt.
        Shortcuts.save([Shortcuts.dictate, try catalogKey("esc"), try catalogKey("tab")])
        bar.reload()
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        let lead = try XCTUnwrap(bar.capByID[Shortcuts.dictate.id])
        let leadFrame = lead.convert(lead.bounds, to: vc.view)
        XCTAssertLessThan(leadFrame.midX, bar.frame.midX, "the cap leads")
        XCTAssertEqual(strip.frame.minX, leadFrame.maxX + 6, accuracy: 0.5, "after the mic cap")
        XCTAssertEqual(strip.frame.maxX, bar.frame.maxX, accuracy: 0.5)
        XCTAssertGreaterThan(strip.frame.width, strip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width,
                             "wide enough for its controls")
        XCTAssertNil(strip.hitTest(vc.view.convert(CGPoint(x: leadFrame.midX, y: leadFrame.midY), to: strip), with: nil))
        XCTAssertEqual(strip.label.text, "Starting the mic…")
        // #971: a long bar scrolled so the mic cap is cut by the bar's trailing edge. What
        // shows of it stays clear of the strip, and its tap below is Done.
        let rest = Shortcuts.Bar.terminal.catalog.filter { $0.id != Shortcuts.dictate.id }
        Shortcuts.save(Array(rest.prefix(rest.count / 2)) + [Shortcuts.dictate] + rest.dropFirst(rest.count / 2))
        bar.reload()
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        let cut = try XCTUnwrap(bar.capByID[Shortcuts.dictate.id] as? UIControl)
        let scroll = try XCTUnwrap(cut.superview?.superview?.superview as? UIScrollView)
        scroll.contentOffset.x = cut.convert(cut.bounds, to: scroll).midX - scroll.bounds.width + 1
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        let cutFrame = cut.convert(cut.bounds, to: vc.view)
        let shown = cutFrame.intersection(bar.frame)
        XCTAssertLessThan(bar.frame.maxX, cutFrame.maxX, "the cap runs past the bar's end")
        XCTAssertGreaterThan(shown.width, 10, "half of it shows")
        XCTAssertEqual(strip.frame.maxX, cutFrame.minX - 6, accuracy: 0.5, "up to the cut cap, still tappable")
        XCTAssertNil(strip.hitTest(vc.view.convert(CGPoint(x: shown.midX, y: shown.midY), to: strip), with: nil))
        app(id, .listening, ["Hello there."], tail: "how")
        c.sync()
        XCTAssertEqual(strip.label.text, "how")
        app(id, .listening, ["Hello there.", "How are you?\nls", "Fine."], tail: "bye")
        c.sync()
        XCTAssertEqual(spy.sent, [paste("Hello there."), paste(" How are you? ls Fine.")])
        cut.sendActions(for: .touchUpInside)   // #971: the cut cap's own tap
        XCTAssertEqual(pings, [.stop], "the key again: Done")
        XCTAssertEqual(strip.label.text, "bye…")
        app(id, .ready, ["Hello there.", "How are you?\nls", "Fine.", "Bye."])
        c.sync()
        XCTAssertEqual(spy.sent.last, paste(" Bye."), "Done: the final goes in")
        XCTAssertTrue(strip.isHidden)

        let keyboards = Dictation.Request(date: clock)
        store.request = keyboards
        app(keyboards.id, .listening)
        bar.onKey?(key)
        id = try XCTUnwrap(store.request?.id)
        XCTAssertNotEqual(id, keyboards.id, "never takes up a keyboard's")
        XCTAssertEqual(pings, [.stop, .start], "warm: a ping")
        XCTAssertEqual(opened.count, 1)
        app(id, .listening, ["One."], tail: "scrap this")
        c.sync()
        strip.cancelButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(pings.last, .cancel)
        XCTAssertEqual(spy.sent.last, paste("One."), "a fresh dictation's first: unspaced")
        XCTAssertTrue(strip.isHidden, "✕: the tail dropped")

        app(nil, .off)
        bar.onKey?(key)
        id = try XCTUnwrap(store.request?.id)
        app(id, .off, note: "Microphone access is off — allow it in Settings › Apps › Prosper")
        c.sync()
        XCTAssertTrue(strip.isHidden)
        let note = vc.view.subviews.flatMap(\.subviews).compactMap { ($0 as? UILabel)?.text }.first { $0.hasPrefix("Microphone") }
        XCTAssertNotNil(note, "the service's note")

        app(nil, .ready)
        bar.onKey?(key)
        app(try XCTUnwrap(store.request?.id), .listening, tail: "x")
        c.sync()
        let sent = spy.sent.count
        vc.viewWillDisappear(false)
        XCTAssertEqual(pings.last, .cancel, "leaving: ✕")
        XCTAssertTrue(strip.isHidden)
        XCTAssertNil(store.request)
        XCTAssertEqual(spy.sent.count, sent)
        XCTAssertFalse(spy.sent.joined().contains(0x0d) || spy.sent.joined().contains(0x0a), "never a return")
    }

    /// paste and paste img never take the modifiers and never spend them.
    func testPasteKeysDontSpendModifiers() async throws {
        let (vc, spy) = try await makeVC()
        let (bar, tv) = try barAndTerminal(vc)
        bar.onKey?(try catalogKey("ctrl"))
        bar.onKey?(try catalogKey("alt"))

        UIPasteboard.general.string = "x"
        bar.onKey?(try catalogKey("paste"))
        XCTAssertEqual(spy.sent.last, [0x78], "the paste was modified")
        UIPasteboard.general.items = []
        bar.onKey?(try catalogKey("pasteImg"))
        XCTAssertEqual(spy.sent.last, [0x16], "the image paste keystroke was modified")
        XCTAssertEqual(bar.modes[.ctrl], .once, "a paste key spent ctrl")
        XCTAssertEqual(bar.modes[.alt], .once, "a paste key spent alt")

        vc.send(source: tv, data: [0x63][...])
        XCTAssertEqual(spy.sent.last, [0x1b, 0x03], "alt+ctrl must still apply to the next key")
    }

    /// #270 QA #81: a clipboard keyboard, dictation or predictive text inserts through
    /// `insertText`, which SwiftTerm sent raw — an embedded ESC sequence coloured the
    /// line and the CR ran it. Text carrying a control byte now leaves as a sanitized
    /// bracketed paste; one typed key and a plain word still go out as typed.
    func testInsertedTextWithControlBytesGoesOutBracketedAndSanitized() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")   // the shell turned bracketed paste on
        try await Task.sleep(nanoseconds: 50_000_000)
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)

        tv.insertText("a")
        XCTAssertEqual(spy.sent.last, [0x61], "a typed letter must stay one raw byte")
        tv.insertText("hi")
        XCTAssertEqual(spy.sent.last, Array("hi".utf8), "a predicted word must stay typed")
        tv.insertText("\n")
        XCTAssertEqual(spy.sent.last, [0x0d], "Return must still send CR")
        tv.insertText(" ")
        XCTAssertEqual(spy.sent.last, [0x20], "a space must go out as typed")
        tv.insertText("hi there")
        XCTAssertEqual(spy.sent.last, Array("hi there".utf8), "words with a space must go out as typed")
        tv.insertText("\t")
        XCTAssertEqual(spy.sent.last, [0x09], "a lone Tab must go out as typed")
        tv.insertText("\r")
        XCTAssertEqual(spy.sent.last, [0x0d], "a lone CR must go out as typed")
        // #281: one control key from a third-party keyboard is a key, not an empty paste
        tv.insertText("\u{03}")
        XCTAssertEqual(spy.sent.last, [0x03], "a lone ^C was lost to an empty paste")
        // QA #94 (M3): no text is no key and no paste — not an empty bracketed frame
        let before = spy.sent.count
        tv.insertText("")
        XCTAssertEqual(spy.sent.count, before, "empty inserted text sent something")

        tv.insertText("a\u{1b}[31mb\r")
        XCTAssertEqual(spy.sent.last, Array("\u{1b}[200~a[31mb\r\u{1b}[201~".utf8),
                       "inserted text reached the host unsanitized or unbracketed")
    }

    /// #281 QA #87: predictive text, text replacement and dictation updates go through
    /// `replace(_:withText:)`, which SwiftTerm sent raw — a dictated newline ran the line.
    /// UIKit calls it by selector; text with a control byte now leaves as a paste.
    func testReplacedTextWithNewlineGoesOutBracketedAndSanitized() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        let range = try XCTUnwrap(tv.textRange(from: tv.endOfDocument, to: tv.endOfDocument))

        _ = (tv as NSObject).perform(#selector(UITextInput.replace(_:withText:)), with: range, with: "a\u{1b}\nb")

        XCTAssertEqual(spy.sent.last, Array("\u{1b}[200~a\nb\u{1b}[201~".utf8),
                       "replaced text reached the host raw or unbracketed")
    }

    /// QA #94: replace text is never a key, so a lone dictated "\n" is a paste, not Return.
    func testReplacedLoneNewlineGoesOutBracketed() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        let range = try XCTUnwrap(tv.textRange(from: tv.endOfDocument, to: tv.endOfDocument))

        _ = (tv as NSObject).perform(#selector(UITextInput.replace(_:withText:)), with: range, with: "\n")

        XCTAssertEqual(spy.sent.last, Array("\u{1b}[200~\n\u{1b}[201~".utf8),
                       "a lone newline through replace ran the line")
    }

    /// QA #94: predictive text replacing a typed word deletes it first, then sends the new
    /// word typed when it is plain, or as a paste when it carries a control byte.
    func testReplaceOverTypedWordDeletesItFirst() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        let replace = #selector(UITextInput.replace(_:withText:))
        func lastWord() throws -> UITextRange {
            let start = try XCTUnwrap(tv.position(from: tv.endOfDocument, offset: -4))
            return try XCTUnwrap(tv.textRange(from: start, to: tv.endOfDocument))
        }
        let del = [UInt8](repeating: 0x7f, count: 4)

        tv.insertText("helo")
        var mark = spy.sent.count
        _ = (tv as NSObject).perform(replace, with: try lastWord(), with: "hello ")
        XCTAssertEqual(Array(spy.sent[mark...].joined()), del + Array("hello ".utf8),
                       "plain replaced text must go out typed, after deleting the old word")

        tv.insertText("helo")
        mark = spy.sent.count
        _ = (tv as NSObject).perform(replace, with: try lastWord(), with: "hello\n")
        XCTAssertEqual(Array(spy.sent[mark...].joined()), del + Array("\u{1b}[200~hello\n\u{1b}[201~".utf8),
                       "the replaced word was not deleted before the paste")
    }

    /// #1008 QA #87 finding 7: pasted text never reached SwiftTerm's input buffer, so a later
    /// replace over it (the next dictation hypothesis, predictive text) deleted nothing and
    /// sent the text again. The buffer now holds what went out, sanitized, and the replace
    /// deletes it first.
    func testReplaceOverPastedTextDeletesItInsteadOfSendingItTwice() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        let replace = #selector(UITextInput.replace(_:withText:))
        func last(_ n: Int) throws -> UITextRange {
            let start = try XCTUnwrap(tv.position(from: tv.endOfDocument, offset: -n))
            return try XCTUnwrap(tv.textRange(from: start, to: tv.endOfDocument))
        }
        func paste(_ s: String) -> [UInt8] { Array("\u{1b}[200~\(s)\u{1b}[201~".utf8) }

        _ = (tv as NSObject).perform(replace, with: try last(0), with: "a\u{1b}\nb")
        var mark = spy.sent.count
        _ = (tv as NSObject).perform(replace, with: try last(3), with: "a\nbc")
        XCTAssertEqual(Array(spy.sent[mark...].joined()), [UInt8](repeating: 0x7f, count: 3) + paste("a\nbc"),
                       "a replace over pasted text sent it again instead of deleting it")

        tv.insertText("d\u{9b}\ne")   // through insertText too; the C1 never reached the host
        XCTAssertEqual(tv.text(in: try last(3)), "d\ne", "the buffer holds more than the host got")
        mark = spy.sent.count
        _ = (tv as NSObject).perform(replace, with: try last(3), with: "d\nef")
        XCTAssertEqual(Array(spy.sent[mark...].joined()), [UInt8](repeating: 0x7f, count: 3) + paste("d\nef"),
                       "a replace over an inserted paste sent it again instead of deleting it")

        // A replace short of the caret: SwiftTerm leaves the caret past the gap, the paste
        // still takes the replaced range's place.
        tv.insertText("\n")   // Return: a fresh, empty buffer
        tv.insertText("abcdef")
        let b = try XCTUnwrap(tv.position(from: tv.beginningOfDocument, offset: 1))
        let c = try XCTUnwrap(tv.position(from: tv.beginningOfDocument, offset: 3))
        _ = (tv as NSObject).perform(replace, with: try XCTUnwrap(tv.textRange(from: b, to: c)), with: "X\nY")
        let all = try XCTUnwrap(tv.textRange(from: tv.beginningOfDocument, to: tv.endOfDocument))
        XCTAssertEqual(tv.text(in: all), "aX\nYdef", "the paste landed off the replaced range")
    }

    /// #1008: a host without bracketed paste ran every line of a paste, as it does a typed
    /// Return, so the buffer keeps only the unrun tail and a later replace can't delete
    /// into the next prompt.
    func testUnbracketedPasteKeepsOnlyItsUnrunTailInTheBuffer() async throws {
        let (vc, spy) = try await makeVC()   // fed host bytes, never 2004h
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        let replace = #selector(UITextInput.replace(_:withText:))
        tv.insertText("x")
        _ = (tv as NSObject).perform(replace, with: try XCTUnwrap(tv.textRange(from: tv.endOfDocument, to: tv.endOfDocument)),
                                     with: "ls\nec")
        XCTAssertEqual(spy.sent.last, Array("ls\nec".utf8), "precondition: an unbracketed paste")

        let mark = spy.sent.count
        let all = try XCTUnwrap(tv.textRange(from: tv.beginningOfDocument, to: tv.endOfDocument))
        _ = (tv as NSObject).perform(replace, with: all, with: "echo")
        XCTAssertEqual(Array(spy.sent[mark...].joined()), [0x7f, 0x7f] + Array("echo".utf8),
                       "a replace deleted into the next prompt, past the paste's last line")
    }

    /// #293 QA #99: nvim takes a C1 control (U+009B CSI, U+0080) like ESC and runs what
    /// follows — " \u{9b}ggdGZZ" wiped the buffer and wrote the file. Through insertText
    /// and through replace it goes out as a paste with the C1 stripped, never raw.
    func testC1ControlsGoOutBracketedAndStripped() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        let attack = " \u{9b}ggdGZZ"
        let safe = Array("\u{1b}[200~ ggdGZZ\u{1b}[201~".utf8)

        tv.insertText(attack)
        XCTAssertEqual(spy.sent.last, safe, "C1 through insertText reached the host raw")

        let range = try XCTUnwrap(tv.textRange(from: tv.endOfDocument, to: tv.endOfDocument))
        _ = (tv as NSObject).perform(#selector(UITextInput.replace(_:withText:)), with: range, with: attack)
        XCTAssertEqual(spy.sent.last, safe, "C1 through replace reached the host raw")

        tv.insertText("\u{80}x\u{85}\u{9f}y")
        XCTAssertEqual(spy.sent.last, Array("\u{1b}[200~xy\u{1b}[201~".utf8), "a C1 control survived the paste")
        XCTAssertFalse(spy.sent.contains { $0.contains(0x9b) }, "a raw CSI byte reached the host")

        // #299: U+001F (^_) is the top C0 control; it must route as a paste, not go raw.
        tv.insertText("a\u{1f}b")
        XCTAssertEqual(spy.sent.last, Array("\u{1b}[200~ab\u{1b}[201~".utf8), "^_ through insertText went raw")
    }

    /// QA #99: a pending mark (multistage input) is dropped when inserted text goes out as
    /// a paste, as the typed path drops it, so it can't commit later on top of the paste.
    func testPastedInsertClearsAPendingMark() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit("\u{1b}[?2004h")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        tv.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(tv.markedTextRange)

        tv.insertText("a\nb")
        XCTAssertNil(tv.markedTextRange, "the mark outlived a pasted insert")
        XCTAssertEqual(spy.sent.last, Array("\u{1b}[200~a\nb\u{1b}[201~".utf8))

        // #299 M1: a C1-only insert over a mark also drops the mark and pastes exactly once.
        tv.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(tv.markedTextRange)
        let before = spy.sent.count
        tv.insertText("x\u{9b}y")
        XCTAssertNil(tv.markedTextRange, "the mark outlived a C1 pasted insert")
        XCTAssertEqual(spy.sent.count, before + 1, "onPaste did not fire exactly once")
        XCTAssertEqual(spy.sent.last, Array("\u{1b}[200~xy\u{1b}[201~".utf8))

        // #303: a replace over a pending mark takes SwiftTerm's own path, not the paste route.
        tv.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        let r = try XCTUnwrap(tv.markedTextRange)
        let n = spy.sent.count
        _ = (tv as NSObject).perform(#selector(UITextInput.replace(_:withText:)), with: r, with: "a\nb")
        XCTAssertFalse(spy.sent[n...].contains { $0.starts(with: Array("\u{1b}[200~".utf8)) },
                       "a replace over a pending mark went out as a paste")
    }

    /// #271 QA #81: a host that never turned bracketed paste on (bash 3.2) printed the
    /// marks as `00~…01~`. Cmd-V there sends the text sanitized, with no marks.
    func testPasteToAHostWithoutBracketedPasteSendsNoMarks() async throws {
        let (vc, spy) = try await makeVC()
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        UIPasteboard.general.string = "a \u{1b}[201~ b"

        tv.paste(nil)

        XCTAssertEqual(spy.sent, [Array("a [201~ b".utf8)], "marks sent to a host that never asked for them")
    }

    /// A paste composed before a fresh view fed any host byte can't know 2004 yet (dch
    /// re-arms it in the attach replay), so it goes bracketed; once host bytes have
    /// been fed without 2004h, no marks (#280).
    func testPasteBeforeFirstHostByteGoesBracketed() async throws {
        let (vc, spy) = try await makeVC(live: false)
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        UIPasteboard.general.string = "a \u{1b}[201~ b"
        // A redraw and a mirror are not host bytes (M7b, M8, #396). The mirror crosses a Task hop in
        // SessionConnection (:426) before applyScreen runs, so the 50 ms sleep must stay before the paste.
        vc.forceRedraw()
        spy.onScreen?(ArraySlice(Array("$ ".utf8)))
        try await Task.sleep(nanoseconds: 50_000_000)

        tv.paste(nil)
        spy.emit("$ ")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(spy.sent, [Array("\u{1b}[200~a [201~ b\u{1b}[201~".utf8)],
                       "a paste before the re-arm landed went out unbracketed")

        tv.paste(nil)

        XCTAssertEqual(spy.sent.last, Array("a [201~ b".utf8), "marks sent after the host showed no 2004")
    }

    /// A bar saved by an older build pinned `pasteImg` to plain ctrl-V forever, so the
    /// fix would never reach anyone who had touched their shortcuts.
    func testSavedBarPicksUpNewKeyDefinitions() {
        let stale = ShortcutKey(id: "pasteImg", label: "paste img", kind: .bytes,
                                bytes: [0x16], systemImage: "photo")
        Shortcuts.save([stale, ShortcutKey(id: "esc", label: "esc", kind: .bytes, bytes: [0x1b])])

        let loaded = Shortcuts.load()

        XCTAssertEqual(loaded.map(\.id), ["pasteImg", "esc", "enter"],
                       "the user's set and order must survive, the send key added at the end")
        XCTAssertEqual(loaded.first?.kind, .pasteImage, "stale kind kept the image paste broken")
    }

    // MARK: long-press copies the block under the finger as one line (#458)

    /// Where a hold `dy` points into screen row `row` lands in `tv` (mid-row by default),
    /// in content space as a gesture's `location(in:)` reports it. The oracle is
    /// SwiftTerm's own layout — buffer line i is drawn at content y = i × cellH — not the
    /// app's mapping, so a wrong mapping can't agree with itself (#284).
    private func rowPoint(_ tv: TerminalView, _ row: Int, _ dy: CGFloat? = nil, col: Int = 2) -> CGPoint {
        let cell = tv.caretFrame.size
        XCTAssertGreaterThan(cell.height, 0, "precondition: the caret gives the cell size")
        return CGPoint(x: (CGFloat(col) + 0.5) * cell.width,
                       y: CGFloat(tv.getTerminal().buffer.yDisp + row) * cell.height + (dy ?? cell.height / 2))
    }

    /// Scrollback, then at the live bottom two one-row blocks stacked: `⏺ alpha` with
    /// `⏺ beta` right under it. Returns alpha's screen row once the layout is the one
    /// that broke #458: the offset pinned to contentSize − bounds with a real strip.
    private func liveBottomWithScrollback(_ tv: TerminalView) throws -> Int {
        let term = tv.getTerminal()
        tv.feed(text: (0..<120).map { "line \($0)\r\n\r\n" }.joined() + "⏺ alpha\r\n⏺ beta\r\n")
        tv.layoutIfNeeded()
        let cellH = tv.caretFrame.height
        XCTAssertGreaterThan(term.buffer.yDisp, 0, "precondition: there is scrollback")
        XCTAssertGreaterThan(tv.bounds.height - CGFloat(term.rows) * cellH, 1,
                             "precondition: a sub-row strip, or no mapping can be told apart")
        XCTAssertLessThan(tv.contentOffset.y, CGFloat(term.buffer.yDisp) * cellH - 1,
                          "precondition: the live bottom pins the offset short of yDisp × cellH")
        return try XCTUnwrap((0..<term.rows).first {
            term.getLine(row: $0)?.translateToString(trimRight: true) == "⏺ alpha"
        })
    }

    private let claudeScreen = "\u{1b}[2J\u{1b}[H\r\n"
        + "⏺ git commit -m \"fix the\r\n"
        + "    wrapped thing\"\r\n"
        + "  ⎿  [main abc123] fix\r\n"

    func testLongPressCopiesTheWrappedCommandAsOneLine() async throws {
        let (vc, _) = try await makeVC()
        let (_, tv) = try barAndTerminal(vc)
        tv.feed(text: claudeScreen)

        vc.copyLine(at: rowPoint(tv, 2))

        XCTAssertEqual(UIPasteboard.general.string, "git commit -m \"fix the wrapped thing\"",
                       "the ⏺ head and its continuation must land as one runnable line, ⎿ left out")
        let toast = vc.view.subviews.flatMap(\.subviews).compactMap { ($0 as? UILabel)?.text }
            .first { $0.hasPrefix("Copied as one line") }
        XCTAssertEqual(toast, "Copied as one line\ngit commit -m \"fix the wrapped thing\"")
    }

    /// #1016: a URL split where the row ended at one width, held after rotating to the
    /// other, portrait to landscape and back. A TUI's rows are hard newlines that keep the
    /// width they were drawn at (reflow only re-wraps them narrower), so the hold must
    /// know the widths the terminal had: the URL comes out whole.
    func testLongPressAfterRotatingGluesATokenSplitAtTheOldWidth() async throws {
        let portrait = CGSize(width: 390, height: 700), landscape = CGSize(width: 700, height: 390)
        for (drawn, held) in [(portrait, landscape), (landscape, portrait)] {
            let (vc, _) = try await makeVC()
            let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
            defer { UIPasteboard.remove(withName: pb.name) }
            vc.pasteboard = pb
            vc.view.frame = CGRect(origin: .zero, size: drawn)
            vc.view.layoutIfNeeded()
            let (_, tv) = try barAndTerminal(vc)
            let term = tv.getTerminal()
            let cols = term.cols
            // Ink splits a token longer than its box (cols - 2) where the row ends.
            let lead = "  curl -o /tmp/o.html https://example.com/"
            let url = (0..<(cols - lead.count + 30)).map { String(UnicodeScalar(UInt8(97 + $0 % 26))) }.joined()
            let first = lead + url.prefix(cols - lead.count)
            tv.feed(text: "\u{1b}[2J\u{1b}[H\r\n" + first + "\r\n  " + url.dropFirst(cols - lead.count) + "\r\n")

            vc.view.frame = CGRect(origin: .zero, size: held)
            vc.view.layoutIfNeeded()
            XCTAssertNotEqual(term.cols, cols, "precondition: the rotation changed the width")
            let row = try XCTUnwrap((0..<term.rows).first {
                term.getLine(row: $0)?.translateToString(trimRight: true).hasPrefix("  curl") == true
            })
            vc.copyLine(at: rowPoint(tv, row))
            XCTAssertEqual(pb.string, "curl -o /tmp/o.html https://example.com/" + url, "drawn at \(cols), held at \(term.cols)")
        }
    }

    /// …but a full-screen app (Claude Code fullscreen, vim) redraws at the new width, so
    /// on the alternate screen only the current width counts: two long tokens, the first
    /// ending exactly at the portrait width, keep their space when held in landscape.
    func testLongPressOnTheAlternateScreenIgnoresEarlierWidths() async throws {
        let (vc, _) = try await makeVC()
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        defer { UIPasteboard.remove(withName: pb.name) }
        vc.pasteboard = pb
        let (_, tv) = try barAndTerminal(vc)
        let term = tv.getTerminal()
        let portrait = term.cols
        vc.view.frame = CGRect(x: 0, y: 0, width: 700, height: 390)
        vc.view.layoutIfNeeded()
        XCTAssertGreaterThan(term.cols, portrait, "precondition: landscape is wider")
        let a = String(repeating: "a", count: portrait - 5), b = String(repeating: "b", count: portrait - 2)
        tv.feed(text: "\u{1b}[?1049h\u{1b}[2J\u{1b}[H\r\n  cp \(a)\r\n  \(b)\r\n")

        vc.copyLine(at: rowPoint(tv, 1))
        XCTAssertEqual(pb.string, "cp \(a) \(b)")
    }

    /// A blank row copies nothing: the clipboard keeps what it had, no toast.
    func testLongPressOnABlankRowLeavesTheClipboardAlone() async throws {
        let (vc, _) = try await makeVC()
        let (_, tv) = try barAndTerminal(vc)
        tv.feed(text: claudeScreen)
        UIPasteboard.general.string = "kept"

        vc.copyLine(at: rowPoint(tv, 0))
        vc.copyLine(at: rowPoint(tv, 6))

        XCTAssertEqual(UIPasteboard.general.string, "kept")
        XCTAssertFalse(vc.view.subviews.flatMap(\.subviews).contains {
            ($0 as? UILabel)?.text?.hasPrefix("Copied") == true
        }, "a blank hold must not toast")
    }

    /// Scrolled back, the row under the finger is a scrollback row: visible row + yDisp.
    func testLongPressInScrollbackCopiesTheRowOnScreen() async throws {
        let (vc, _) = try await makeVC()
        let (_, tv) = try barAndTerminal(vc)
        let term = tv.getTerminal()
        tv.feed(text: (0..<120).map { "line \($0)\r\n\r\n" }.joined())
        tv.scrollUp(lines: 30)
        let row = (0..<term.rows).first {
            term.getLine(row: $0)?.translateToString(trimRight: true).hasPrefix("line ") == true
        }
        let r = try XCTUnwrap(row)
        let shown = term.getLine(row: r)!.translateToString(trimRight: true)
        XCTAssertGreaterThan(term.buffer.yDisp, 0, "precondition: scrolled into the scrollback")
        XCTAssertNotEqual(shown, "line 0", "precondition: the top of the buffer is off screen")

        vc.copyLine(at: rowPoint(tv, r))

        XCTAssertEqual(UIPasteboard.general.string, shown)
    }

    /// The hold must not also fire the tap (keyboard) or the pan (copy mode): both wait
    /// for the long-press to fail, and still recognize alongside each other.
    func testTapAndPanWaitForTheLongPress() async throws {
        let (vc, _) = try await makeVC()
        let (_, tv) = try barAndTerminal(vc)
        let all = tv.gestureRecognizers ?? []
        let holds = all.filter { $0 is UILongPressGestureRecognizer && $0 !== vc.handlePress }   // the handle grab is ours
        XCTAssertEqual(holds.count, 1, "SwiftTerm's own long-press must stay stripped")
        let hold = try XCTUnwrap(holds.first)
        let tap = try XCTUnwrap(all.first { $0 is UITapGestureRecognizer && $0.delegate === vc })
        let pan = try XCTUnwrap(all.first { $0 is UIPanGestureRecognizer && $0.delegate === vc })

        XCTAssertTrue(vc.gestureRecognizer(tap, shouldRequireFailureOf: hold))
        XCTAssertTrue(vc.gestureRecognizer(pan, shouldRequireFailureOf: hold))
        XCTAssertFalse(vc.gestureRecognizer(tap, shouldRequireFailureOf: pan))
        XCTAssertFalse(vc.gestureRecognizer(pan, shouldRequireFailureOf: tap))
        XCTAssertTrue(vc.gestureRecognizer(tap, shouldRecognizeSimultaneouslyWith: pan))
    }

    /// The normal state — Claude running with history above, the view at the bottom. A
    /// hold anywhere on alpha's row copies alpha, never the beta block under it.
    func testLongPressAtTheLiveBottomTakesTheRowUnderTheFinger() async throws {
        let (vc, _) = try await makeVC()
        let (_, tv) = try barAndTerminal(vc)
        let r = try liveBottomWithScrollback(tv)
        let cellH = tv.caretFrame.height

        for dy in [0.5, cellH / 2, cellH - 0.5] {
            UIPasteboard.general.string = "none"
            vc.copyLine(at: rowPoint(tv, r, dy))
            XCTAssertEqual(UIPasteboard.general.string, "alpha", "hold \(dy) pt into the row")
        }
    }

    /// At the live bottom the strip above screen row 0 shows most of line yDisp − 1; a
    /// hold there copies that line, not row 0 (QA #285).
    func testLongPressInTheTopStripTakesTheLineShownThere() async throws {
        let (vc, _) = try await makeVC()
        let (_, tv) = try barAndTerminal(vc)
        let term = tv.getTerminal()
        let lineAbove = { term.getScrollInvariantLine(row: term.buffer.yDisp - 1)?.translateToString(trimRight: true) ?? "" }
        tv.feed(text: (0..<120).map { "line \($0)\r\n\r\n" }.joined())
        if lineAbove().isEmpty { tv.feed(text: "\r\n") }     // blank rows alternate: one more puts text there
        tv.layoutIfNeeded()
        let strip = tv.bounds.height - CGFloat(term.rows) * tv.caretFrame.height
        XCTAssertGreaterThan(strip, 1, "precondition: a sub-row strip")
        let above = lineAbove()
        XCTAssertTrue(above.hasPrefix("line "), "precondition: line yDisp − 1 has text")
        XCTAssertNotEqual(above, term.getLine(row: 0)?.translateToString(trimRight: true),
                          "precondition: the strip and row 0 show different lines")
        UIPasteboard.general.string = "none"

        vc.copyLine(at: CGPoint(x: 2.5 * tv.caretFrame.width, y: tv.contentOffset.y + strip / 2))

        XCTAssertEqual(UIPasteboard.general.string, above)
    }

    /// The tap's cell (mouse click, `tapRaisesKeyboard`) at the live bottom: top, middle
    /// and bottom pixel of the first, a middle and the last row all map to that row.
    func testGridPosAtTheLiveBottomIsTheCellUnderTheFinger() async throws {
        let (vc, _) = try await makeVC()
        let (_, tv) = try barAndTerminal(vc)
        _ = try liveBottomWithScrollback(tv)
        let term = tv.getTerminal()
        let cellH = tv.caretFrame.height

        for row in [0, term.rows / 2, term.rows - 1] {
            for dy in [0.5, cellH / 2, cellH - 0.5] {
                let cell = vc.gridPos(rowPoint(tv, row, dy, col: 3), term)
                XCTAssertEqual(cell.row, row, "row \(row), \(dy) pt in")
                XCTAssertEqual(cell.col, 3)
            }
        }
    }

    /// #459: Claude Code's fullscreen mode runs on the alternate screen, and a hold there
    /// copies the whole wrapped "!" command as one line, " \\" continuations dropped.
    func testLongPressOnTheAlternateScreenCopiesTheWrappedCommand() async throws {
        let (vc, _) = try await makeVC()
        vc.view.frame.size.width = 800   // the device's rows are 68 wide: no soft wrap here
        vc.view.layoutIfNeeded()
        let (_, tv) = try barAndTerminal(vc)
        XCTAssertGreaterThanOrEqual(tv.getTerminal().cols, 70, "precondition: rows fit unwrapped")
        let rows = [
            "● The paste wrapped the line again. This version ends each line with",
            "  \\, so wrapped lines join back up:",
            "",
            "  ! for c in gke_example-ci_europe-west4-b_ci-primary \\",
            "    gke_example-system_europe-west1-b_ci-primary; do \\",
            "    kubectl --context $c -n web-frontend-controller rollout restart \\",
            "    deploy/web-frontend-controller; done",
            "",
            "* Churned for 2s · done 7:40 PM",
        ]
        tv.feed(text: "\u{1b}[?1049h\u{1b}[H\u{1b}[2J" + rows.joined(separator: "\r\n"))
        XCTAssertTrue(tv.getTerminal().isCurrentBufferAlternate, "precondition: alternate screen")
        UIPasteboard.general.string = "none"

        vc.copyLine(at: rowPoint(tv, 5))

        XCTAssertEqual(UIPasteboard.general.string,
                       "! for c in gke_example-ci_europe-west4-b_ci-primary gke_example-system_europe-west1-b_ci-primary; do kubectl --context $c -n web-frontend-controller rollout restart deploy/web-frontend-controller; done")
    }

    /// SwiftTerm's own soft wrap (a shell line typed past the right edge, `isWrapped`)
    /// splits at any column, mid-word too: a hold on either row gives back exactly what
    /// was typed — no space inside "hello" or the URL, the one space kept when the wrap
    /// falls right after it, none for the cell a wide char left empty (QA #287 F1).
    func testLongPressOnASoftWrappedShellLineCopiesItExactly() async throws {
        let (vc, _) = try await makeVC()
        let (_, tv) = try barAndTerminal(vc)
        let term = tv.getTerminal()
        let cols = term.cols
        XCTAssertGreaterThanOrEqual(cols, 40, "precondition: room for the lines below")
        // "$ echo xx…x hell" | "o world"
        let midWord = "$ echo " + String(repeating: "x", count: cols - 12) + " hello world"
        // a 40-char URL split 20 | 20, shorter than the row, so the word-wrap rule spaces it
        let url = "$ curl -fsSL " + String(repeating: "y", count: cols - 34) + " https://example.com/"
            + String(repeating: "a", count: 20)
        // "$ printf zz…z " | "tail": row 0's last cell is the space
        let afterSpace = "$ printf " + String(repeating: "z", count: cols - 10) + " tail"
        // wide chars that leave the last cell empty: the next one wraps, no space between
        let head = cols.isMultiple(of: 2) ? "$ echo " : "$ echo a"
        let wide = head + String(repeating: "漢", count: (cols - head.count) / 2 + 2)
        tv.feed(text: "\u{1b}[H\u{1b}[2J" + [midWord, url, afterSpace, wide].joined(separator: "\r\n\r\n"))

        for (want, row) in [(midWord, 0), (url, 3), (afterSpace, 6), (wide, 9)] {
            XCTAssertEqual(term.getLine(row: row + 1)?.isWrapped, true, "precondition: row \(row) soft-wraps")
            for hold in [row, row + 1] {
                UIPasteboard.general.string = "none"
                vc.copyLine(at: rowPoint(tv, hold))
                XCTAssertEqual(UIPasteboard.general.string, want, "hold on row \(hold)")
            }
        }
    }

    /// Quick holds replace the toast instead of stacking pills.
    func testASecondHoldReplacesTheToast() async throws {
        let (vc, _) = try await makeVC()
        let (_, tv) = try barAndTerminal(vc)
        tv.feed(text: claudeScreen)

        vc.copyLine(at: rowPoint(tv, 2))
        vc.copyLine(at: rowPoint(tv, 3))

        let toasts = vc.view.subviews.flatMap(\.subviews).compactMap { ($0 as? UILabel)?.text }
            .filter { $0.hasPrefix("Copied as one line") }
        XCTAssertEqual(toasts, ["Copied as one line\n[main abc123] fix"])
    }
}
