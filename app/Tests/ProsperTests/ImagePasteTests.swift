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
        UserDefaults.standard.removeObject(forKey: Shortcuts.storageKey)
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

    /// #320 QA #126: only a single typed ASCII byte takes the armed ctrl. Multi-byte text
    /// (é was sent as 0x03 = ^C) passes through whole and keeps the arm; a lone Esc goes
    /// out unchanged and disarms.
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
        bar.onKey?(ShortcutKey(id: "ctrl", label: "ctrl", kind: .ctrl))
        XCTAssertTrue(bar.ctrlArmed, "precondition: ctrl re-armed")

        vc.send(source: tv, data: [0x1b][...])
        XCTAssertEqual(spy.sent.last, [0x1b], "a lone Esc must go out unchanged")
        XCTAssertFalse(bar.ctrlArmed, "a lone Esc must disarm ctrl")

        bar.onKey?(ShortcutKey(id: "ctrl", label: "ctrl", kind: .ctrl))
        XCTAssertTrue(bar.ctrlArmed, "precondition: ctrl re-armed")
        vc.send(source: tv, data: [0x61][...])
        XCTAssertEqual(spy.sent.last, [0x01], "ctrl no longer applies to the typed key")
        XCTAssertFalse(bar.ctrlArmed, "the typed key must disarm ctrl")
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
        let holds = all.filter { $0 is UILongPressGestureRecognizer }
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

    /// vim's `~` rows and status line are never blank: on the alternate screen a hold
    /// copies the touched row only, not the whole screen.
    func testLongPressOnTheAlternateScreenCopiesOnlyTheTouchedRow() async throws {
        let (vc, _) = try await makeVC()
        let (_, tv) = try barAndTerminal(vc)
        tv.feed(text: "\u{1b}[?1049h\u{1b}[H\u{1b}[2Jimport Foundation\r\nfunc main() {\r\n~\r\n~\r\n\"main.swift\" 4L")
        XCTAssertTrue(tv.getTerminal().isCurrentBufferAlternate, "precondition: alternate screen")

        vc.copyLine(at: rowPoint(tv, 1))

        XCTAssertEqual(UIPasteboard.general.string, "func main() {")
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
