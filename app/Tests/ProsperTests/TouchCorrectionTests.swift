import XCTest
import SwiftTerm
import UIKit
@testable import Prosper

/// The compact keyboard's touch correction: a touch between two letters goes to the one
/// that continues the word being typed, from the dictionary, the shell word list or the
/// terminal's own text. Geometry is the real layout at 402 pt (iPhone 17 Pro).
@MainActor
final class TouchCorrectionTests: XCTestCase {
    typealias K = TerminalKeyboard

    private final class SpyInput: NSObject, UIKeyInput {
        var calls: [String] = []
        var hasText: Bool { true }
        func insertText(_ text: String) { calls.append(text) }
        func deleteBackward() { calls.append("⌫") }
    }

    private func laidOut(width: CGFloat = 402) -> (K, [String: CGRect]) {
        let kb = K()
        kb.frame = CGRect(x: 0, y: 0, width: width, height: K.height)
        kb.layoutIfNeeded()
        var frames: [String: CGRect] = [:]
        for case let b as UIButton in kb.subviews { frames[b.title(for: .normal) ?? b.accessibilityLabel ?? ""] = b.frame }
        return (kb, frames)
    }

    /// The single-character keys as the pure decision sees them.
    private func keys(_ frames: [String: CGRect]) -> [(K.Key, CGRect)] {
        frames.filter { $0.key.count == 1 }.map { (.char($0.key), $0.value) }
    }

    private func knowing(_ words: String...) -> (String) -> Bool {
        { s in words.contains { $0.hasPrefix(s) } }
    }

    /// Types `letters`, then taps `point`; returns what the tap typed.
    private func type(_ letters: String, thenTap point: CGPoint, on kb: K) -> String? {
        let spy = SpyInput()
        kb.target = spy
        for c in letters { kb.press(.char(String(c))) }
        kb.track(.began, id: 1, at: point)
        kb.track(.ended, id: 1, at: point)
        return spy.calls.count == letters.count + 1 ? spy.calls.last : nil
    }

    // MARK: The decision

    func testTesAndATouchTowardTTypesT() {
        let (_, f) = laidOut()
        let r = f["r"]!, t = f["t"]!
        let rightThird = CGPoint(x: r.maxX - r.width / 6, y: r.midY)
        let gap = CGPoint(x: (r.maxX + t.minX) / 2, y: r.midY)
        for p in [rightThird, gap] {
            XCTAssertEqual(K.corrected(.char("r"), at: p, keys: keys(f), prefix: "tes", known: knowing("test")),
                           .char("t"), "\(p)")
        }
    }

    func testACenteredHitIsNeverMoved() {
        let (_, f) = laidOut()
        let r = f["r"]!
        XCTAssertEqual(K.corrected(.char("r"), at: CGPoint(x: r.midX, y: r.midY), keys: keys(f),
                                   prefix: "tes", known: knowing("test")), .char("r"))
        // Landscape keys are wide enough that a point inside r's center is within reach of t.
        let (_, wide) = laidOut(width: 874)
        let wr = wide["r"]!, inCenter = CGPoint(x: wr.maxX - wr.width / 4 - 1, y: wr.midY)
        XCTAssertLessThanOrEqual(K.distance(inCenter, wide["t"]!), wr.width / 2, "precondition: t in reach")
        XCTAssertEqual(K.corrected(.char("r"), at: inCenter, keys: keys(wide), prefix: "tes", known: knowing("test")),
                       .char("r"))
    }

    func testNoPrefixAKnownNearestOrNoReachKeepsTheNearest() {
        let (_, f) = laidOut()
        let r = f["r"]!
        let edge = CGPoint(x: r.maxX - 1, y: r.midY)
        XCTAssertEqual(K.corrected(.char("r"), at: edge, keys: keys(f), prefix: "", known: knowing("t")),
                       .char("r"), "an empty prefix")
        XCTAssertEqual(K.corrected(.char("r"), at: edge, keys: keys(f), prefix: "tes", known: knowing("test", "tesr")),
                       .char("r"), "nearest continues a word")
        // r's top edge, mid-key: t and e are out of reach, and the 4 above is a digit.
        let top = CGPoint(x: r.midX, y: r.minY + 1)
        XCTAssertEqual(K.corrected(.char("r"), at: top, keys: keys(f), prefix: "tes", known: knowing("test", "tes4")),
                       .char("r"), "no letter within half a key width")
        XCTAssertEqual(K.corrected(.char("4"), at: CGPoint(x: f["4"]!.maxX - 1, y: f["4"]!.midY), keys: keys(f),
                                   prefix: "tes", known: knowing("tes5")), .char("4"), "digits are never corrected")
    }

    /// The row above counts too: "ki" and a touch on g's top edge, under t, is "kit".
    func testAVerticalNeighbor() {
        let (_, f) = laidOut()
        let g = f["g"]!, t = f["t"]!
        let p = CGPoint(x: (g.minX + t.maxX) / 2, y: g.minY + 1)
        XCTAssertEqual(K.corrected(.char("g"), at: p, keys: keys(f), prefix: "ki", known: knowing("kit")), .char("t"))
        XCTAssertEqual(K.corrected(.char("g"), at: p, keys: keys(f), prefix: "ki", known: knowing("kit", "kiga")),
                       .char("g"), "kig is known: g stays")
    }

    /// Both continue a word: a touch on r's left edge after "th" is e, "the" far likelier
    /// than "three". Equally likely, or a centered r, it stays r.
    func testALikelierNeighborWinsWhereBothContinueAWord() {
        let (_, f) = laidOut()
        let r = f["r"]!, edge = CGPoint(x: r.minX + 0.5, y: r.midY)
        let likely: (String) -> Double = { ["the": 2, "thr": 0.05][$0] ?? 0 }
        XCTAssertEqual(K.corrected(.char("r"), at: edge, keys: keys(f), prefix: "th", known: { _ in true }, likely: likely),
                       .char("e"))
        XCTAssertEqual(K.corrected(.char("r"), at: edge, keys: keys(f), prefix: "th", known: { _ in true },
                                   likely: { _ in 1 }), .char("r"), "alike: the nearest")
        XCTAssertEqual(K.corrected(.char("r"), at: CGPoint(x: r.midX - r.width / 4 + 1, y: r.midY), keys: keys(f),
                                   prefix: "th", known: { _ in true }, likely: { ["the": 1000, "thr": 0.001][$0] ?? 0 }),
                       .char("r"), "a centered r, however unlikely")
        XCTAssertEqual(K.corrected(.char("r"), at: CGPoint(x: r.midX - r.width / 4 - 1, y: r.midY), keys: keys(f),
                                   prefix: "th", known: { _ in true }, likely: likely),
                       .char("r"), "just off the center: e is too far for its odds")
    }

    /// The same in Bulgarian, whose checker the simulator lacks: "т" and a touch on р's
    /// left edge is е when "те" is the likelier.
    func testALikelierNeighborInBulgarian() {
        let kb = K(layout: .bulgarian)
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: K.height)
        kb.layoutIfNeeded()
        var f: [String: CGRect] = [:]
        for case let b as UIButton in kb.subviews { if let t = b.title(for: .normal) { f[t.lowercased()] = b.frame } }
        let r = f["р"]!
        XCTAssertEqual(K.corrected(.char("р"), at: CGPoint(x: r.minX + 0.5, y: r.midY), keys: keys(f), prefix: "т",
                                   known: { _ in true }, likely: { ["те": 3, "тр": 0.05][$0] ?? 0 }), .char("е"))
    }

    // MARK: Through the real keyboard

    /// The real dictionary's odds: "th" and a touch on r's left edge types e.
    func testRealDictionaryOddsTypeTheOverThr() {
        let (kb, f) = laidOut()
        let r = f["r"]!
        XCTAssertTrue(K.dictionaryKnows("thr"), "precondition: both continue a word")
        XCTAssertEqual(type("th", thenTap: CGPoint(x: r.minX + 0.5, y: r.midY), on: kb), "e")
        let (kb2, _) = laidOut()
        XCTAssertEqual(type("th", thenTap: CGPoint(x: r.midX, y: r.midY), on: kb2), "r", "a centered r is typed")
    }

    /// Thumbs land low: a touch 8 pt under t, nearer g, types t, even as a word's first
    /// letter, where nothing is corrected. A hold there converts t too.
    func testALowTouchOnALetterAimsUp() {
        let (kb, f) = laidOut()
        let t = f["t"]!, g = f["g"]!
        let low = CGPoint(x: t.midX + 5, y: t.maxY + 8)
        XCTAssertLessThan(K.distance(low, g), K.distance(low, t), "precondition: g is nearer")
        XCTAssertEqual(kb.word, "")
        XCTAssertEqual(kb.key(at: low), .char("t"))
        let spy = SpyInput()
        kb.target = spy
        kb.track(.began, id: 1, at: low)
        kb.fireHold()
        kb.track(.ended, id: 1, at: low)
        XCTAssertEqual(spy.calls, ["["], "t's hold symbol")
    }

    /// The lift stays on the letter rows: a touch just over space, or just over q's row
    /// (nearer q than the 1 above), is what it was.
    func testTheLiftNeverLeavesTheLetterRows() {
        let (kb, f) = laidOut()
        let space = f["space"]!, q = f["q"]!
        XCTAssertEqual(kb.key(at: CGPoint(x: space.midX, y: space.minY - 3)), .space)
        XCTAssertEqual(kb.key(at: CGPoint(x: space.midX, y: space.maxY + 6)), .space, "under the bottom row")
        XCTAssertEqual(kb.key(at: CGPoint(x: q.midX, y: q.minY - 3)), .char("q"))
        XCTAssertEqual(kb.key(at: CGPoint(x: f["1"]!.midX, y: f["1"]!.maxY + 3)), .char("1"))
    }

    /// Row 3's letters lift too: a touch in the gap 3 pt over x, nearest x, aims into s's
    /// row.
    func testALowTouchOverXAimsUp() {
        let (kb, f) = laidOut()
        let x = f["x"]!, p = CGPoint(x: x.midX, y: x.minY - 3)
        XCTAssertLessThan(K.distance(p, x), min(K.distance(p, f["s"]!), K.distance(p, f["d"]!)), "precondition: x is nearer")
        XCTAssertTrue([.char("s"), .char("d")].contains(kb.key(at: p)))
    }

    /// Shift and backspace are never lifted: in landscape the 4 pt row gap is under the
    /// lift, so a touch 1.5 pt into their tops would type a or l's row.
    func testTheLiftNeverLeavesShiftOrBackspace() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.traitOverrides.verticalSizeClass = .compact
        let kb = K()
        kb.frame = CGRect(x: 0, y: 0, width: 874, height: K.height)
        window.addSubview(kb)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        for (label, key) in [("shift", K.Key.shift), ("delete", .backspace)] {
            let f = try XCTUnwrap(kb.subviews.lazy.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }, label).frame
            XCTAssertEqual(f.height, 26, "precondition: landscape")
            XCTAssertEqual(kb.key(at: CGPoint(x: f.midX, y: f.minY + 1.5)), key, label)
        }
    }

    /// The real UITextChecker: "tesr" starts no word, "test" does.
    func testRealDictionaryCorrectsTesR() {
        XCTAssertTrue(K.dictionaryKnows("test"))
        XCTAssertFalse(K.dictionaryKnows("tesr"))
        let (kb, f) = laidOut()
        let r = f["r"]!
        XCTAssertEqual(type("tes", thenTap: CGPoint(x: r.maxX - 1, y: r.midY), on: kb), "t")
        let (kb2, _) = laidOut()
        XCTAssertEqual(type("tes", thenTap: CGPoint(x: r.midX, y: r.midY), on: kb2), "r", "a centered r is typed")
    }

    func testShellWordsCompleteWhatTheDictionaryDoesNot() {
        XCTAssertFalse(K.dictionaryKnows("kubec"), "kubectl comes from the shell list")
        let (kb, f) = laidOut()
        let x = f["x"]!
        XCTAssertEqual(type("kube", thenTap: CGPoint(x: x.maxX - 1, y: x.midY), on: kb), "c")
    }

    func testShellWordsAreLowercaseLettersOnce() {
        let all = ShellWords.all
        XCTAssertGreaterThan(all.count, 200)
        XCTAssertEqual(Set(all).count, all.count, "duplicates")
        for w in all { XCTAssertTrue(w.allSatisfy { ("a"..."z").contains($0) }, w) }
        for w in ["kubectl", "rebase", "tfvars", "esac", "yaml"] { XCTAssertTrue(all.contains(w), w) }
    }

    func testScreenWordsCompleteNamesOnlyTheTerminalKnows() {
        let (kb, f) = laidOut()
        let r = f["r"]!, w = f["w"]!
        let towardT = CGPoint(x: r.maxX - 1, y: r.midY)
        XCTAssertEqual(type("blip", thenTap: towardT, on: kb), "r", "no screen word: nothing to correct to")
        kb.resetWord()
        kb.screenWords = { ["bliptok"] }
        XCTAssertEqual(type("blip", thenTap: towardT, on: kb), "t")
        kb.resetWord()
        kb.screenWords = { ["scalefox"] }
        XCTAssertEqual(type("scal", thenTap: CGPoint(x: w.maxX - 1, y: w.midY), on: kb), "e")
        kb.resetWord()
        // Only the screen's, a little: the dictionary's "blips" (its second) keeps the touch.
        kb.screenWords = { ["blipdtok"] }
        let s = f["s"]!, d = f["d"]!
        XCTAssertEqual(type("blip", thenTap: CGPoint(x: (s.maxX + d.minX) / 2 - 0.5, y: s.midY), on: kb), "s")
    }

    /// The screen is read only for an ambiguous touch, once per touch.
    func testScreenWordsAreReadLazily() {
        let (kb, f) = laidOut()
        var reads = 0
        kb.screenWords = { reads += 1; return ["scalefox"] }
        let r = f["r"]!
        XCTAssertEqual(type("scal", thenTap: CGPoint(x: r.midX, y: r.midY), on: kb), "r")
        XCTAssertEqual(reads, 0, "a centered touch reads nothing")
        kb.resetWord()
        XCTAssertEqual(type("scal", thenTap: CGPoint(x: r.minX + 1, y: r.midY), on: kb), "e")
        XCTAssertEqual(reads, 1, "once per touch: the lift reuses what began read")
    }

    func testScreenWordsReadTheVisibleRowsAndRecentScrollback() {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), font: TerminalFont.mono(size: 12))
        tv.layoutIfNeeded()
        let rows = tv.getTerminal().rows
        tv.feed(text: "Ancient-Word\r\n" + String(repeating: "filler\r\n", count: 300) + "ScaleFox x1 ab k8s-prod\r\n")
        let words = K.screenWords(in: tv.getTerminal())
        XCTAssertEqual(words, ["filler", "scalefox", "prod"])
        XCTAssertFalse(words.contains("ancientword"), "more than \(rows) + 200 lines up")
    }

    // MARK: The current word

    func testWordTracking() {
        let kb = K()
        kb.target = SpyInput()
        for c in "tes" { kb.press(.char(String(c))) }
        XCTAssertEqual(kb.word, "tes")
        kb.press(.backspace)
        XCTAssertEqual(kb.word, "te")
        kb.press(.shift); kb.press(.char("x"))
        XCTAssertEqual(kb.word, "tex", "shift keeps the word, lowercase")
        for key in [K.Key.space, .char("1"), .char("/"), .char("#"), .ret] {
            kb.press(.char("a"))
            XCTAssertEqual(kb.word.last, "a")
            kb.press(key)
            XCTAssertEqual(kb.word, "", "\(key)")
        }
        kb.press(.char("a"))
        kb.resetWord()
        XCTAssertEqual(kb.word, "")
        kb.press(.backspace)
        XCTAssertEqual(kb.word, "", "backspace past the word")
    }

    /// The host: a shortcut-bar key ends the word, and the screen closure reads its terminal.
    func testHostResetsTheWordOnABarKeyAndHandsOverTheScreen() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        let saved = K.hardwareKeyboardConnected
        K.hardwareKeyboardConnected = { false }
        defer { K.hardwareKeyboardConnected = saved }
        let vc = TerminalHostVC(conn: SessionConnection(transport: SpyTransport(),
                                                       session: DchSession(name: "t", alias: nil)),
                                handle: TermHandle())
        vc.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        vc.view.layoutIfNeeded()
        let kb = try XCTUnwrap(vc.keyboardInputView as? K)
        let tv = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? TerminalView }.first)
        tv.feed(text: "deploy scalefox\r\n")
        XCTAssertTrue(try XCTUnwrap(kb.screenWords)().contains("scalefox"))

        kb.press(.char("a"))
        XCTAssertEqual(kb.word, "a")
        let bar = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? ShortcutBar }.first)
        bar.onKey?(ShortcutKey(id: "left", label: "←", kind: .bytes, bytes: [0x1b, 0x5b, 0x44]))
        XCTAssertEqual(kb.word, "")
    }

    /// A letter the bar's sticky ctrl sends as ^C is a command, not the start of a word:
    /// after ^C, "l" and a touch on s's left edge types s ("ls"), not a ("cla", QA #287).
    func testHostEndsTheWordOnALetterSentAsAControlKey() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        let saved = K.hardwareKeyboardConnected
        K.hardwareKeyboardConnected = { false }
        defer { K.hardwareKeyboardConnected = saved }
        let vc = TerminalHostVC(conn: SessionConnection(transport: SpyTransport(),
                                                       session: DchSession(name: "t", alias: nil)),
                                handle: TermHandle())
        vc.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        vc.view.layoutIfNeeded()
        let kb = try XCTUnwrap(vc.keyboardInputView as? K)
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: K.height)
        kb.layoutIfNeeded()
        let s = try XCTUnwrap(kb.subviews.lazy.compactMap { $0 as? UIButton }.first { $0.title(for: .normal) == "s" }).frame
        let bar = try XCTUnwrap(vc.view.subviews.lazy.compactMap { $0 as? ShortcutBar }.first)

        bar.onKey?(ShortcutKey(id: "ctrl", label: "ctrl", kind: .ctrl))
        kb.press(.char("c"))
        XCTAssertEqual(kb.word, "", "^C starts no word")
        let typed = type("l", thenTap: CGPoint(x: s.minX + 1, y: s.midY), on: kb)
        XCTAssertEqual(typed, "s")
    }

    // MARK: Cost

    /// One ambiguous decision with everything consulted: the dictionary misses "tesr", the
    /// shell list misses it, the screen (a full one plus 200 lines) is scanned, then "test".
    /// Each round is a fresh keyboard, so nothing is cached; a finger moving within the
    /// touch then asks again, from the cache.
    func testAnAmbiguousDecisionStaysUnderAFrame() {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), font: TerminalFont.mono(size: 12))
        tv.layoutIfNeeded()
        let line = "kubectl rollout status deployment/scalefox-worker -n staging --timeout=120s ok"
        tv.feed(text: String(repeating: line + "\r\n", count: 400))
        func ms(_ body: () -> Void) -> Double {
            let t0 = CACurrentMediaTime(); body(); return (CACurrentMediaTime() - t0) * 1000
        }
        var fresh: [Double] = [], again: [Double] = []
        for _ in 0..<30 {
            let (kb, f) = laidOut()
            kb.screenWords = { K.screenWords(in: tv.getTerminal()) }
            kb.target = SpyInput()
            for c in "tes" { kb.press(.char(String(c))) }
            let p = CGPoint(x: f["r"]!.maxX - 1, y: f["r"]!.midY)
            fresh.append(ms { XCTAssertEqual(kb.key(at: p), .char("t")) })
            again.append(ms { XCTAssertEqual(kb.key(at: p), .char("t")) })
        }
        let scan = ms { _ = K.screenWords(in: tv.getTerminal()) }
        let first = fresh[0]
        fresh.sort(); again.sort()
        print(String(format: "touch correction: %d rows x %d cols + 200 lines; first %.3f ms, fresh median %.3f max %.3f ms, cached median %.3f ms; scan alone %.3f ms",
                     tv.getTerminal().rows, tv.getTerminal().cols, first, fresh[15], fresh.last!, again[15], scan))
        XCTAssertLessThan(fresh[15], 8)
        XCTAssertLessThan(again[15], 1)
    }
}
