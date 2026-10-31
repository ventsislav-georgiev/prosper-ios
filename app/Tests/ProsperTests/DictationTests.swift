import XCTest
import UIKit
@testable import Prosper

/// The keyboards' speech-to-text (#598): the App Group files and link, the heartbeat rule, the
/// ready period, spacing, and the keyboard's client: each phrase typed once (a reload too),
/// the hop, Done and ✕, leaving. A throwaway directory, a fixed clock and recorded pings
/// throughout: no mic, no permission, no URL opened.
@MainActor
final class DictationTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy

    private var store: Dictation.Store!
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var pings: [Dictation.Ping] = []
    private var opened: [URL] = []
    private var opens = true
    private var typed: [String] = []
    private var hints: [String] = []

    override func setUp() {
        super.setUp()
        store = Dictation.Store(dir: FileManager.default.temporaryDirectory.appendingPathComponent("DictationTests-\(UUID())"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.dir)
        super.tearDown()
    }

    private func client() -> DictationClient {
        let c = DictationClient(store: store)
        c.polls = false
        c.now = { [unowned self] in self.clock }
        c.ping = { [unowned self] in self.pings.append($0) }
        c.open = { [unowned self] url, done in self.opened.append(url); done(self.opens) }
        c.insert = { [unowned self] in self.typed.append($0) }
        c.hint = { [unowned self] in self.hints.append($0) }
        return c
    }

    /// The app, as `DictationService` writes it: `id`'s phase, phrases and tail, beating now.
    private func app(_ id: UUID?, _ phase: Dictation.State.Phase, _ phrases: [String] = [], tail: String = "",
                     note: String? = nil) {
        store.state = Dictation.State(id: id, phase: phase, heartbeat: clock, phrases: phrases, tail: tail, note: note)
    }

    func testFilesAndLinkRoundTrip() throws {
        XCTAssertNil(store.request)
        let r = Dictation.Request(date: clock, applied: 2)
        store.request = r
        XCTAssertEqual(Dictation.Store(dir: store.dir).request, r, "on disk: the other keyboard reads it")
        store.request = nil
        XCTAssertNil(store.request)
        app(r.id, .listening, ["One."], tail: "two")
        XCTAssertEqual(store.state?.phrases, ["One."])
        XCTAssertEqual(store.state?.tail, "two")

        XCTAssertEqual(Dictation.id(from: Dictation.url(r.id)), r.id)
        XCTAssertNil(Dictation.id(from: try XCTUnwrap(URL(string: "prosper://sessions?id=\(r.id)"))))
        XCTAssertNil(Dictation.id(from: try XCTUnwrap(URL(string: "other://dictate?id=\(r.id)"))))
    }

    /// Warm: the app beat within `stale` and its mic is on; `off` never is.
    func testHeartbeatFreshness() {
        let s = Dictation.State(id: nil, phase: .ready, heartbeat: clock)
        XCTAssertTrue(s.warm(at: clock + 2.9))
        XCTAssertFalse(s.warm(at: clock + Dictation.stale), "stale: the app is gone")
        XCTAssertFalse(Dictation.State(id: nil, phase: .off, heartbeat: clock).warm(at: clock))
    }

    /// The ready period counts from the last dictation; Until Stopped never runs out.
    func testReadyPeriodExpiry() {
        XCTAssertEqual(Dictation.ReadyPeriod.allCases.map(\.title), ["2 min", "10 min", "30 min", "Until Stopped"])
        XCTAssertFalse(Dictation.ReadyPeriod.ten.expired(since: clock, now: clock + 599))
        XCTAssertTrue(Dictation.ReadyPeriod.ten.expired(since: clock, now: clock + 600))
        XCTAssertFalse(Dictation.ReadyPeriod.two.expired(since: clock, now: clock + 119))
        XCTAssertTrue(Dictation.ReadyPeriod.two.expired(since: clock, now: clock + 120))
        XCTAssertFalse(Dictation.ReadyPeriod.thirty.expired(since: clock, now: clock + 1799))
        XCTAssertFalse(Dictation.ReadyPeriod.untilStopped.expired(since: clock, now: clock + 86_400))
    }

    func testStoredReadyPeriodDefaultsToTen() throws {
        let suite = "dictation.readyPeriod.test"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(Dictation.ReadyPeriod.stored(in: defaults), .ten)
        defaults.set(0, forKey: Dictation.ReadyPeriod.key)
        XCTAssertEqual(Dictation.ReadyPeriod.stored(in: defaults), .untilStopped)
        defaults.set(2, forKey: Dictation.ReadyPeriod.key)
        XCTAssertEqual(Dictation.ReadyPeriod.stored(in: defaults), .two)
        defaults.set(7, forKey: Dictation.ReadyPeriod.key)
        XCTAssertEqual(Dictation.ReadyPeriod.stored(in: defaults), .ten)
    }

    /// Done or ✕ while the mic is still getting ready wins: over there, ready, never listening.
    /// Once it listens, `finish` halts the transcription first, so nothing changes here.
    func testStopWhilePreparing() {
        var s = Dictation.State(id: UUID(), phase: .preparing, heartbeat: clock)
        XCTAssertTrue(s.stopPreparing())
        XCTAssertEqual(s.phase, .ready)
        for phase in [Dictation.State.Phase.listening, .finishing, .ready, .off] {
            var other = Dictation.State(id: UUID(), phase: phase, heartbeat: clock, tail: "two")
            XCTAssertFalse(other.stopPreparing(), "\(phase)")
            XCTAssertEqual(other.phase, phase)
            XCTAssertEqual(other.tail, "two")
        }
    }

    func testSpacingAndEnglish() {
        XCTAssertEqual(Dictation.spaced(" Hello.", after: ""), "Hello.")
        XCTAssertEqual(Dictation.spaced("Hello.", after: "Say"), " Hello.")
        XCTAssertEqual(Dictation.spaced("Hello.", after: "Say "), "Hello.")
        XCTAssertEqual(Dictation.spaced("Hello.", after: "line\n"), "Hello.")
        XCTAssertEqual(Dictation.spaced("aside", after: "("), "aside")
        XCTAssertEqual(Dictation.spaced(", then", after: "first"), ", then")
        XCTAssertEqual(Dictation.english(["bg-BG", "en-GB", "en-US"]), "en-GB")
        XCTAssertEqual(Dictation.english(["bg-BG"]), "en-US", "English only: no Bulgarian engine")
    }

    /// A warm start goes straight to the app; each finished phrase goes in once, a reloaded
    /// keyboard reading the count back; Done waits for the last phrase.
    func testWarmStartTypesEachPhraseOnceAcrossAReload() throws {
        app(nil, .ready)
        let c = client()
        c.appear()
        c.tap()
        XCTAssertEqual(pings, [.start])
        XCTAssertEqual(c.strip, .starting)
        XCTAssertTrue(opened.isEmpty, "warm: no hop")
        let id = try XCTUnwrap(store.request?.id)

        app(id, .listening, tail: "hello")
        c.sync()
        XCTAssertEqual(c.strip, .listening("hello"))
        XCTAssertEqual(typed, [])
        app(id, .listening, ["Hello there."], tail: "how")
        c.sync()
        c.sync()
        XCTAssertEqual(typed, ["Hello there."], "once")
        XCTAssertEqual(store.request?.applied, 1)

        let reloaded = client()   // the extension relaunched mid-dictation
        app(id, .listening, ["Hello there.", "How are you?", "Fine."])
        reloaded.appear()
        XCTAssertEqual(typed, ["Hello there.", "How are you? Fine."], "only the new ones, in one go")
        XCTAssertEqual(reloaded.strip, .listening(""))

        app(id, .listening, ["Hello there.", "How are you?", "Fine."], tail: "bye")
        reloaded.sync()
        reloaded.tap()   // the mic key again: Done
        XCTAssertEqual(pings, [.start, .stop])
        XCTAssertEqual(reloaded.strip, .finishing("bye"))
        clock += 0.5
        app(id, .ready, ["Hello there.", "How are you?", "Fine.", "Bye."])
        reloaded.sync()
        XCTAssertEqual(typed.last, "Bye.", "Done: the tail, finalized, goes in")
        XCTAssertEqual(reloaded.strip, .idle)
        XCTAssertNil(store.request)
        XCTAssertEqual(hints, [])
    }

    /// Cold: the key opens Prosper with its request; leaving for it isn't ✕, and back from it
    /// the dictation goes on, what was said meanwhile typed.
    func testColdStartHopsAndResumesAfterBack() throws {
        let c = client()
        c.appear()
        c.tap()
        let id = try XCTUnwrap(store.request?.id)
        XCTAssertEqual(opened, [Dictation.url(id)])
        XCTAssertEqual(c.strip, .opening)
        XCTAssertEqual(pings, [])
        c.disappear()
        XCTAssertEqual(pings, [], "the hop isn't leaving")
        XCTAssertNotNil(store.request)

        app(id, .listening, ["Said in Prosper."], tail: "and")
        let back = client()
        back.appear()
        XCTAssertEqual(typed, ["Said in Prosper."])
        XCTAssertEqual(back.strip, .listening("and"))
    }

    /// iOS refused the open: a hint; the request stays for Prosper opened by hand.
    func testFailedOpenHints() {
        opens = false
        let c = client()
        c.appear()
        c.tap()
        XCTAssertEqual(c.strip, .idle)
        XCTAssertEqual(hints, ["Open Prosper to start the mic"])
        XCTAssertNotNil(store.request)
        let later = client()
        later.appear()
        XCTAssertNil(store.request, "never taken up: dropped")
        XCTAssertEqual(later.strip, .idle)
    }

    /// A heartbeat that looked fresh but no answer: the app is gone after all, so it hops.
    func testUnansweredWarmStartHops() {
        app(nil, .ready)
        let c = client()
        c.appear()
        c.tap()
        c.sync()
        XCTAssertTrue(opened.isEmpty)
        clock += Dictation.ackLimit + 0.1
        c.sync()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(c.strip, .opening)
    }

    /// ✕: finished phrases go in, the tail doesn't; Done with no answer: the tail as shown.
    func testCancelDropsTheTailAndDoneFallsBackToIt() throws {
        app(nil, .ready)
        let c = client()
        c.appear()
        c.tap()
        var id = try XCTUnwrap(store.request?.id)
        app(id, .listening, tail: "first")
        c.sync()
        app(id, .listening, ["First."], tail: "scrap this")
        c.cancel()
        XCTAssertEqual(typed, ["First."])
        XCTAssertEqual(pings.last, .cancel)
        XCTAssertEqual(c.strip, .idle)

        app(id, .ready, ["First."])
        c.tap()
        id = try XCTUnwrap(store.request?.id)
        app(id, .listening, tail: "almost there")
        c.sync()
        c.done()
        clock += 1
        c.sync()
        XCTAssertEqual(c.strip, .finishing("almost there"))
        clock += Dictation.finishLimit
        app(id, .listening, tail: "almost there")   // beating, but no final
        c.sync()
        XCTAssertEqual(typed, ["First.", "almost there"])
        XCTAssertEqual(c.strip, .idle)
    }

    /// Leaving mid-dictation (not for the hop) is ✕; the app stopping (a call, Siri) or going
    /// away ends it with a hint, its finished phrases in.
    func testLeavingCancelsAndTheAppStoppingEnds() throws {
        app(nil, .ready)
        let c = client()
        c.appear()
        c.tap()
        var id = try XCTUnwrap(store.request?.id)
        app(id, .listening, tail: "x")
        c.sync()
        c.disappear()
        XCTAssertEqual(pings, [.start, .cancel])
        XCTAssertNil(store.request)

        app(id, .ready)
        c.appear()
        c.tap()
        id = try XCTUnwrap(store.request?.id)
        app(id, .listening)
        c.sync()
        app(id, .off, ["Last."], note: "The mic stopped for a call or Siri — tap it to reopen Prosper")
        c.sync()
        XCTAssertEqual(typed, ["Last."])
        XCTAssertEqual(hints, ["The mic stopped for a call or Siri — tap it to reopen Prosper"])
        XCTAssertEqual(c.strip, .idle)

        app(nil, .ready)
        c.tap()
        id = try XCTUnwrap(store.request?.id)
        app(id, .listening)
        c.sync()
        clock += Dictation.stale
        c.sync()
        XCTAssertEqual(c.strip, .idle, "no heartbeat: the app is gone")
        XCTAssertEqual(hints.count, 2)
    }

    // MARK: The toolbar key

    private func rig(_ text: String, dictation: DictationClient?, fullAccess: Bool = true)
        -> (TerminalKeyboard, SuggestionBar, Proxy) {
        let doc = Proxy()
        doc.text = text
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        let suite = "DictationTests.\(UUID().uuidString)"
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: UserDefaults(suiteName: suite)!)))
        bar.dictation = dictation
        let pb = UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true)
        if fullAccess { bar.suggestions.pasteboard = { pb } }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        bar.attach(kb)
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults + [Shortcuts.dictate] }
        view.layoutIfNeeded()
        return (kb, bar, doc)
    }

    private static func caps(_ v: UIView) -> [KeyCapButton] {
        v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) }
    }

    /// The toolbar's alone, added in the editor, an iOS 16 symbol; only with Full Access and a
    /// client (the controller makes one on iOS 26).
    func testMicKeyIsToolbarOnlyAndNeedsFullAccessAndAClient() throws {
        XCTAssertEqual(Shortcuts.hostKey(Shortcuts.dictate.id), .dictate)
        XCTAssertTrue(Shortcuts.Bar.toolbar.catalog.contains(Shortcuts.dictate))
        XCTAssertFalse(Shortcuts.Bar.terminal.catalog.contains { $0.id == Shortcuts.dictate.id })
        XCTAssertFalse(Shortcuts.Bar.toolbar.defaults.contains(Shortcuts.dictate), "added in the editor")
        XCTAssertNotNil(UIImage(systemName: try XCTUnwrap(Shortcuts.dictate.systemImage)))

        let label = Shortcuts.dictate.label
        let (_, none, _) = rig("", dictation: client(), fullAccess: false)
        XCTAssertFalse(Self.caps(try XCTUnwrap(none.toolbar)).contains { $0.accessibilityLabel == label }, "no Full Access")
        let (_, clientless, _) = rig("", dictation: nil)
        XCTAssertFalse(Self.caps(try XCTUnwrap(clientless.toolbar)).contains { $0.accessibilityLabel == label }, "below iOS 26")
        let (kb, full, _) = rig("", dictation: client())
        XCTAssertTrue(Self.caps(try XCTUnwrap(full.toolbar)).contains { $0.accessibilityLabel == label })
        withExtendedLifetime(kb) {}
    }

    /// The key starts it; the strip covers the bar with the words not yet typed; phrases go in
    /// at the cursor, spaced; the strip's ✕ ends it.
    func testKeyStripAndTyping() throws {
        app(nil, .ready)
        let c = client()
        let (kb, bar, doc) = rig("Note:", dictation: c)
        c.appear()
        bar.press(Shortcuts.dictate)
        XCTAssertEqual(pings, [.start])
        let strip = bar.dictationStrip
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(strip.frame, bar.bounds)
        XCTAssertEqual(strip.label.text, "Starting the mic…")
        let id = try XCTUnwrap(store.request?.id)
        app(id, .listening, ["Buy milk."], tail: "and")
        c.sync()
        XCTAssertEqual(doc.text, "Note: Buy milk.")
        XCTAssertEqual(strip.label.text, "and")
        strip.cancelButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(pings, [.start, .cancel])
        XCTAssertTrue(strip.isHidden)
        XCTAssertEqual(doc.text, "Note: Buy milk.", "the tail dropped")
        c.disappear()
        withExtendedLifetime(kb) {}
    }
}
