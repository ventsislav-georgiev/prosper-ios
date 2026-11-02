import XCTest
import UIKit
@testable import Prosper

/// Clean Up Dictation (#612): at Done the model tidies exactly what the dictation typed, the
/// field proven unchanged before the model and at the write; anything between or after the
/// phrases, a changed field, ✕, the keyboard going or a failed model keeps it as spoken. The
/// model is `RewriteTests.FakeModel` on the bar's seam; the app's side is the store's files,
/// as `DictationTests` writes them.
@MainActor
final class DictationCleanupTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy
    typealias Model = RewriteTests.FakeModel

    private var store: Dictation.Store!
    private let clock = Date(timeIntervalSince1970: 1_000_000)
    private var pb: UIPasteboard!
    private var suite = ""
    /// Each rig's keyboard, field and view: the bar holds the keyboard, and it the field, weakly.
    private var kept: [AnyObject] = []

    override func setUp() {
        super.setUp()
        store = Dictation.Store(dir: FileManager.default.temporaryDirectory.appendingPathComponent("DictationCleanupTests-\(UUID())"))
        pb = UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true)
        suite = "DictationCleanupTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.dir)
        UIPasteboard.remove(withName: pb.name)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        kept = []
        super.tearDown()
    }

    private struct Rig {
        let kb: TerminalKeyboard
        let bar: SuggestionBar
        let doc: Proxy
        let view: UIView
        let client: DictationClient
        let id: UUID
    }

    /// A field, the bar with the fake model and Clean Up Dictation on, and a dictation started
    /// warm, listening.
    private func rig(_ text: String, after: String = "", model: Model, cleans: Bool = true, fullAccess: Bool = true,
                     availability: Rewrite.Availability = .available) throws -> Rig {
        let doc = Proxy()
        doc.text = text
        doc.after = after
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: UserDefaults(suiteName: suite)!)))
        let c = DictationClient(store: store)
        c.polls = false
        c.now = { [clock] in clock }
        c.ping = { _ in }
        bar.dictation = c
        bar.rewrite = { try await model.run($0, $1) }
        bar.rewriteAvailability = { availability }
        bar.suggestions.settings.cleansDictation = cleans
        let pb = self.pb
        if fullAccess { bar.suggestions.pasteboard = { pb } }
        let view = Host(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        bar.attach(kb)
        bar.host(kb, in: view)
        kept += [kb, doc, view]
        app(nil, .ready)
        c.appear()
        c.tap()
        let id = try XCTUnwrap(store.request?.id)
        app(id, .listening)
        c.sync()
        return Rig(kb: kb, bar: bar, doc: doc, view: view, client: c, id: id)
    }

    private func app(_ id: UUID?, _ phase: Dictation.State.Phase, _ phrases: [String] = [], tail: String = "") {
        store.state = Dictation.State(id: id, phase: phase, heartbeat: clock, phrases: phrases, tail: tail)
    }

    /// The app finished `phrases` so far.
    private func say(_ r: Rig, _ phrases: [String]) {
        app(r.id, .listening, phrases)
        r.client.sync()
    }

    /// Done, then the app's last phrase and its end: the cleanup under way, if any.
    private func done(_ r: Rig, _ phrases: [String]) -> Task<Void, Never>? {
        r.client.done()
        app(r.id, .ready, phrases)
        r.client.sync()
        return r.client.cleaning
    }

    /// The hints shown over the keys (`SuggestionBar.hint`): a plain bubble holding a label.
    /// Each as it goes up (`Host`), so a run stalled past its fade still reads it (#711).
    private static func hints(_ v: UIView) -> [String] {
        (v as? Host)?.shown ?? []
    }

    /// The rig's view: keeps each hint put over the keys, which fades off it after 1.5 s.
    private final class Host: UIView {
        var shown: [String] = []
        override func didAddSubview(_ v: UIView) {
            super.didAddSubview(v)
            if type(of: v) == UIView.self, let text = (v.subviews.first as? UILabel)?.text { shown.append(text) }
        }
    }

    // MARK: - (a) The replace

    /// Exactly the dictated text goes, Character for Character, emoji and combining marks
    /// too; the text before and after it stays; the model got it all, with the dictation's
    /// instructions. The strip says so meanwhile, ✕ keeping it as spoken.
    func testDoneReplacesExactlyTheDictatedText() async throws {
        let phrases = ["um so the 👨‍👩‍👧 famly 🇧🇬", "cafe\u{301} is na\u{308}ive uh"]
        let model = Model()
        model.reply = " So the 👨‍👩‍👧 family 🇧🇬. Café is naïve.\n"
        model.holds = true
        let r = try rig("Dear Sam,\nNote:", after: "\nBest", model: model)
        say(r, [phrases[0]])
        let typed = " um so the 👨‍👩‍👧 famly 🇧🇬 cafe\u{301} is na\u{308}ive uh"
        let task = try XCTUnwrap(done(r, phrases))
        XCTAssertEqual(r.doc.text, "Dear Sam,\nNote:" + typed, "as spoken till the answer")
        XCTAssertEqual(r.client.strip, .cleaning)
        let strip = r.bar.dictationStrip
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(strip.label.text, "Cleaning up…")
        XCTAssertTrue(strip.spinner.isAnimating)
        XCTAssertTrue(strip.doneButton.isHidden)
        XCTAssertFalse(strip.cancelButton.isHidden)
        XCTAssertEqual(strip.cancelButton.accessibilityLabel, "Keep as spoken")
        while model.pending == nil { await Task.yield() }
        XCTAssertEqual(model.calls.map(\.0), [.dictation])
        XCTAssertEqual(model.calls.map(\.1), [typed])
        let before = r.doc.calls.count
        model.pending?.resume(returning: model.reply)
        await task.value
        XCTAssertEqual(r.doc.calls[before...].filter { $0 == "⌫" }.count, typed.count, "its Characters, no more")
        XCTAssertEqual(r.doc.text, "Dear Sam,\nNote: So the 👨‍👩‍👧 family 🇧🇬. Café is naïve.")
        XCTAssertEqual(r.doc.after, "\nBest", "the text after untouched")
        XCTAssertEqual(r.client.strip, .idle)
        XCTAssertTrue(strip.isHidden)
        XCTAssertNil(r.bar.spoken, "over")
        XCTAssertEqual(Self.hints(r.view), [])
        XCTAssertFalse(Rewrite.Command.allCases.contains(.dictation), "never a panel row")
    }

    /// A host shows an insert a turn or more later: Done's last phrase isn't in the context when
    /// the cleanup starts, and it waits for it rather than give up.
    func testALaggingHostIsWaitedFor() async throws {
        let model = Model()
        model.reply = "Hello there. How are you?"
        let r = try rig("", model: model)
        r.doc.lagsEdits = true
        say(r, ["hello there"])
        r.doc.catchUp()
        let task = try XCTUnwrap(done(r, ["hello there", "how are you"]))
        XCTAssertEqual(r.doc.documentContextBeforeInput, "hello there", "the last phrase not shown yet")
        try await Task.sleep(nanoseconds: 50_000_000)
        r.doc.catchUp()
        await task.value
        r.doc.catchUp()
        XCTAssertEqual(r.doc.text, "Hello there. How are you?")
        XCTAssertEqual(model.calls.map(\.1), ["hello there how are you"])
    }

    // MARK: - (b) Anything between or after the phrases

    /// A key between the phrases, even one undone, or a caret move: kept as spoken, no model
    /// call, a hint.
    func testAKeyOrACaretMoveBetweenPhrasesKeepsItAsSpoken() throws {
        for way in ["key", "caret"] {
            let model = Model()
            let r = try rig("Note:", model: model)
            say(r, ["um one"])
            if way == "key" {
                r.kb.press(.char("x"))
                r.kb.press(.backspace)
                XCTAssertEqual(r.doc.text, "Note: um one", "undone: the text as typed")
            } else {
                r.kb.caret(-1)
            }
            XCTAssertNil(done(r, ["um one", "uh two"]), way)
            XCTAssertTrue(model.calls.isEmpty, way)
            XCTAssertEqual(r.doc.calls.filter { $0 == "⌫" }.count, way == "key" ? 1 : 0, way)
            XCTAssertTrue((r.doc.text + (r.doc.after ?? "")).contains("uh two"), way)
            XCTAssertEqual(r.client.strip, .idle, way)
            XCTAssertEqual(Self.hints(r.view), [SuggestionBar.keptAsSpoken], way)
        }
    }

    /// A key while the model works, even one undone: its answer writes nothing.
    func testAKeyDuringCleanupKeepsItAsSpoken() async throws {
        let model = Model()
        model.holds = true
        let r = try rig("Note:", model: model)
        say(r, ["um one"])
        let task = try XCTUnwrap(done(r, ["um one", "uh two"]))
        while model.pending == nil { await Task.yield() }
        r.kb.press(.char("x"))
        r.kb.press(.backspace)
        let before = r.doc.calls.count
        model.pending?.resume(returning: "One. Two.")
        await task.value
        XCTAssertEqual(r.doc.calls.count, before, "nothing written")
        XCTAssertEqual(r.doc.text, "Note: um one uh two")
        XCTAssertEqual(r.client.strip, .idle)
        XCTAssertEqual(Self.hints(r.view), [SuggestionBar.keptAsSpoken])
    }

    // MARK: - (c) The field read at the write

    /// The text after the caret changed, a selection, the text before changed, or another
    /// field at the write: refused, nothing written.
    func testAChangedFieldAtTheWriteIsRefused() async throws {
        let changes: [(String, (Proxy) -> Void)] = [
            ("after", { $0.after = " then\nBest" }),
            ("selection", { $0.selectedText = "two" }),
            ("before", { $0.text = "Note: um one uh tw" }),
            ("field", { $0.identifier = UUID() }),
        ]
        for (way, change) in changes {
            let model = Model()
            model.holds = true
            let r = try rig("Note:", after: "\nBest", model: model)
            say(r, ["um one"])
            let task = try XCTUnwrap(done(r, ["um one", "uh two"]))
            while model.pending == nil { await Task.yield() }
            change(r.doc)
            let before = r.doc.calls.count
            model.pending?.resume(returning: "One. Two.")
            await task.value
            XCTAssertEqual(r.doc.calls.count, before, way)
            XCTAssertFalse(r.doc.text.contains("One."), way)
            XCTAssertEqual(Self.hints(r.view), [SuggestionBar.keptAsSpoken], way)
        }
    }

    /// A host's window shorter than the dictation, still its end: not a change, but not proven
    /// either, so kept as spoken with its own hint; the window and a changed after-context is
    /// a change.
    func testAWindowTooShortToProveItSaysSo() async throws {
        for way in ["window", "window and after"] {
            let model = Model()
            let r = try rig("Note:", after: "\nBest", model: model)
            r.doc.window = 10
            say(r, ["um one"])
            say(r, ["um one", "uh two"])
            let task = try XCTUnwrap(done(r, ["um one", "uh two", "three"]), way)
            XCTAssertEqual(r.doc.documentContextBeforeInput, " two three", "the window: the dictation's end only")
            if way == "window and after" { r.doc.after = "\nRegards" }
            await task.value
            XCTAssertTrue(model.calls.isEmpty, way)
            XCTAssertEqual(r.doc.text, "Note: um one uh two three", way)
            XCTAssertEqual(Self.hints(r.view), [way == "window" ? SuggestionBar.tooLongToCheck : SuggestionBar.keptAsSpoken], way)
        }
        XCTAssertEqual(SuggestionBar.tooLongToCheck, "Kept as spoken: too long to check here")
    }

    /// The text after the caret changed between phrases: the chain is broken, no model call.
    func testAChangedFieldBetweenPhrasesKeepsItAsSpoken() throws {
        let model = Model()
        let r = try rig("Note:", after: "\nBest", model: model)
        say(r, ["um one"])
        r.doc.after = "\nRegards"
        XCTAssertNil(done(r, ["um one", "uh two"]))
        XCTAssertTrue(model.calls.isEmpty)
        XCTAssertEqual(r.doc.text, "Note: um one uh two")
    }

    // MARK: - (d) ✕ and leaving

    /// ✕ or the keyboard going while the model works: the late answer writes nothing. ✕ while
    /// listening is as before: no cleanup at all.
    func testCancelOrLeavingDuringCleanupWritesNothing() async throws {
        for way in ["✕", "disappear"] {
            let model = Model()
            model.holds = true
            let r = try rig("Note:", model: model)
            say(r, ["um one"])
            let task = try XCTUnwrap(done(r, ["um one", "uh two"]))
            while model.pending == nil { await Task.yield() }
            if way == "✕" { r.bar.dictationStrip.cancelButton.sendActions(for: .touchUpInside) } else { r.client.disappear() }
            XCTAssertEqual(r.client.strip, .idle, way)
            XCTAssertNil(r.client.cleaning, way)
            let before = r.doc.calls.count
            model.pending?.resume(returning: "One. Two.")
            await task.value
            XCTAssertEqual(r.doc.calls.count, before, way)
            XCTAssertEqual(r.doc.text, "Note: um one uh two", way)
            XCTAssertEqual(Self.hints(r.view), [], way)
        }

        let model = Model()
        let r = try rig("Note:", model: model)
        say(r, ["um one"])
        r.client.cancel()
        XCTAssertNil(r.client.cleaning)
        XCTAssertTrue(model.calls.isEmpty, "✕ while listening")
        XCTAssertEqual(r.doc.text, "Note: um one")
    }

    // MARK: - (e) Gating

    /// The setting off, Bulgarian, no Full Access, no model, Apple Intelligence off or still
    /// downloading, or over the cap: no model call, the text as spoken, the strip gone at once.
    /// Off or downloading says why, once; the rest are silent.
    func testNoModelCallWhereItsOffOrOutOfReach() throws {
        let ways = ["off", "bulgarian", "no full access", "no model", "not enabled", "downloading", "over the cap"]
        for way in ways {
            let model = Model()
            let availability: Rewrite.Availability = way == "not enabled" ? .appleIntelligenceNotEnabled
                : way == "downloading" ? .modelNotReady : .available
            let r = try rig("Note:", model: model, cleans: way != "off", fullAccess: way != "no full access",
                            availability: availability)
            if way == "bulgarian" { r.kb.layout = .bulgarian }
            if way == "no model" { r.bar.rewrite = nil }
            let long = String(repeating: "a ", count: Rewrite.cap / 2 + 1)
            say(r, [way == "over the cap" ? long : "um one"])
            XCTAssertNil(done(r, [way == "over the cap" ? long : "um one", "uh two"]), way)
            XCTAssertTrue(model.calls.isEmpty, way)
            XCTAssertEqual(r.client.strip, .idle, way)
            XCTAssertFalse(r.doc.calls.contains("⌫"), way)
            XCTAssertEqual(Self.hints(r.view), availability.reason.map { [$0] } ?? [], way)
        }
        XCTAssertEqual(Rewrite.Availability.modelNotReady.reason, "The model is still downloading — try again soon")
        XCTAssertFalse(KeyboardSettings().cleansDictation, "off by default")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: KeyboardSettings.Key.cleansDictation)
        XCTAssertTrue(KeyboardSettings(defaults).cleansDictation)
        XCTAssertFalse(KeyboardSettings(nil).cleansDictation, "no Full Access: the defaults")
    }

    // MARK: - (f) The model failing

    /// An error or a blank answer: kept as spoken, nothing written.
    func testAModelErrorOrBlankAnswerKeepsItAsSpoken() async throws {
        struct Failed: Error {}
        for way in ["error", "blank"] {
            let model = Model()
            model.reply = " \n"
            let r = try rig("Note:", model: model)
            if way == "error" { r.bar.rewrite = { _, _ in throw Failed() } }
            say(r, ["um one"])
            let task = try XCTUnwrap(done(r, ["um one", "uh two"]))
            let before = r.doc.calls.count
            await task.value
            XCTAssertEqual(r.doc.calls.count, before, way)
            XCTAssertEqual(r.doc.text, "Note: um one uh two", way)
            XCTAssertEqual(r.client.strip, .idle, way)
            XCTAssertEqual(Self.hints(r.view), ["Kept as spoken"], way)
        }
    }
}
