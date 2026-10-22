import XCTest
import UIKit
@testable import Prosper

/// The keycaps: what they say, and how they answer a finger.
final class ShortcutCapTests: XCTestCase {

    private func key(_ id: String) throws -> ShortcutKey {
        try XCTUnwrap(Shortcuts.catalog.first { $0.id == id }, "no \(id) in the catalog")
    }

    // MARK: what the caps say

    /// esc and tab are words. `escape` and the indent arrows are guessed, not read.
    func testEscAndTabAreWordsNotGlyphs() throws {
        for id in ["esc", "tab", "stab"] {
            XCTAssertNil(try key(id).systemImage, "\(id) should render its label")
        }
        XCTAssertEqual(try key("esc").label, "esc")
        XCTAssertEqual(try key("tab").label, "tab")
    }

    /// The newline cap must not wear the keyboard's own return glyph — it sits inches from
    /// the real return key and does the opposite (newline, no submit).
    func testNoCapImpersonatesTheReturnKey() {
        for k in Shortcuts.catalog {
            XCTAssertNotEqual(k.systemImage, "arrow.turn.down.left",
                              "\(k.id) is wearing the keyboard's return glyph")
        }
        XCTAssertNil(Shortcuts.catalog.first { $0.id == "snl" }?.systemImage)
    }

    /// ctrl is one centred word. It used to be a big "^" over a tiny caption, which read as
    /// a cap with a hole in the middle.
    func testCtrlIsASingleWord() throws {
        let ctrl = try key("ctrl")
        XCTAssertEqual(ctrl.label, "ctrl")
        XCTAssertNil(ctrl.systemImage)
        XCTAssertEqual(ctrl.kind, .ctrl)
    }

    /// Every default resolves to a real catalog entry, and ids are unique — a typo here
    /// silently drops a key off the bar.
    func testDefaultsResolveAndIdsAreUnique() {
        XCTAssertEqual(Shortcuts.defaults.map(\.id), ["paste", "pasteImg", "up", "down", "tab", "shift", "home", "insert",
                                                       "esc", "ctrl", "left", "right", "pgup", "pgdn", "end", "enter"])
        XCTAssertEqual(Set(Shortcuts.catalog.map(\.id)).count, Shortcuts.catalog.count)
    }

    /// VoiceOver reads the key's label, not the SF Symbol name of an icon cap.
    func testCapsReadTheirLabels() {
        UserDefaults.standard.removeObject(forKey: Shortcuts.storageKey)
        func caps(_ v: UIView) -> [KeyCapButton] { v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) } }
        let bar = ShortcutBar()
        bar.layoutIfNeeded()   // the caps join the bar's rows on layout
        XCTAssertEqual(caps(bar).compactMap(\.accessibilityLabel).sorted(), Shortcuts.defaults.map(\.label).sorted())
    }

    // MARK: how the caps split across the bar's rows

    func testKeysThatFitStayInOneRow() {
        // 3·50 + 2·6 = 162 ≤ 162
        XCTAssertEqual(ShortcutBar.rowSplit(widths: [50, 50, 50], spacing: 6, available: 162), 3)
    }

    /// Overflow → the in-order split whose ALIGNED grid is narrowest.
    /// [100, 40, 40, 40, 100] at 6 spacing, 200 available (total 344), grid columns:
    /// k=1 → 100,40,40,100 = 298 · k=2 → 100,40,100 = 252 · k=3 → 100,100,40 = 252 ·
    /// k=4 → 100,40,40,40 = 238 — pairing the two wide caps in one column wins.
    func testOverflowSplitsForTheNarrowestAlignedGrid() {
        XCTAssertEqual(ShortcutBar.rowSplit(widths: [100, 40, 40, 40, 100], spacing: 6, available: 200), 4)
        // [120, 30, 30, 30] (total 228 > 200): k=1 → 120,30,30 = 192 · k=2 → 120,30 = 156 ·
        // k=3 → 120,30,30 = 192.
        XCTAssertEqual(ShortcutBar.rowSplit(widths: [120, 30, 30, 30], spacing: 6, available: 200), 2)
    }

    /// Ties go to the fuller top row: [50, 50, 50] → k=1 and k=2 both give a 106 grid.
    func testAlignedSplitTieGoesToTheFullerTopRow() {
        XCTAssertEqual(ShortcutBar.rowSplit(widths: [50, 50, 50], spacing: 6, available: 150), 2)
    }

    /// Column i = the wider of its two caps; the longer row's tail keeps its own width.
    func testColumnWidths() {
        XCTAssertEqual(ShortcutBar.columnWidths(top: [40, 90, 30], bottom: [60, 50, 30]), [60, 90, 30])
        XCTAssertEqual(ShortcutBar.columnWidths(top: [40, 90, 30, 70], bottom: [60, 50]), [60, 90, 30, 70])
        XCTAssertEqual(ShortcutBar.columnWidths(top: [40], bottom: [60, 25]), [60, 25])
        XCTAssertEqual(ShortcutBar.columnWidths(top: [], bottom: []), [])
    }

    /// The default set at iPhone 17 width (402 pt; narrower phones squeeze, see
    /// testDefaultBarFitsTheNarrowPhones): every column's two caps share an edge and a
    /// width, and a one-row set keeps natural widths.
    @MainActor
    func testTwoRowBarColumnsLineUp() throws {
        let saved = UserDefaults.standard.string(forKey: Shortcuts.storageKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: Shortcuts.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: Shortcuts.storageKey) }
        }
        let ids = Shortcuts.defaults.map(\.id)
        Shortcuts.save(try ids.map(key))

        let bar = ShortcutBar()
        bar.frame = CGRect(x: 0, y: 0, width: 402, height: 86)
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.rowCount, 2)
        func rows(_ v: UIView) -> [UIStackView] {
            v.subviews.flatMap { s -> [UIStackView] in
                if let st = s as? UIStackView, st.axis == .horizontal { return [st] }
                return rows(s)
            }
        }
        let r = rows(bar)
        XCTAssertEqual(r.count, 2)
        let top = r[0].arrangedSubviews.map { $0.convert($0.bounds, to: bar) }
        let bottom = r[1].arrangedSubviews.map { $0.convert($0.bounds, to: bar) }
        XCTAssertEqual(top.count + bottom.count, ids.count)
        print("141-grid top=\(top.map(\.width)) bottom=\(bottom.map(\.width))",
              "natural=\(r.flatMap(\.arrangedSubviews).compactMap { ($0 as? KeyCapButton)?.naturalWidth })")
        func scrollView(_ v: UIView) -> UIScrollView? {
            v.superview.flatMap { $0 as? UIScrollView ?? scrollView($0) }
        }
        func fillsRow(_ row: UIStackView) throws {
            let sv = try XCTUnwrap(scrollView(row))
            let last = try XCTUnwrap(row.arrangedSubviews.last)
            let maxX = last.convert(last.bounds, to: sv).maxX
            XCTAssertEqual(maxX, sv.bounds.width, accuracy: 1, "row fills the bar")
            XCTAssertLessThanOrEqual(sv.contentSize.width, sv.bounds.width + 0.01, "not scrollable")
        }
        try fillsRow(r[0])
        for i in 0..<min(top.count, bottom.count) {
            XCTAssertEqual(top[i].minX, bottom[i].minX, accuracy: 0.5, "column \(i) left edge")
            XCTAssertEqual(top[i].width, bottom[i].width, accuracy: 0.5, "column \(i) width")
        }
        for cap in r.flatMap(\.arrangedSubviews) {
            let c = try XCTUnwrap(cap as? KeyCapButton)
            XCTAssertGreaterThanOrEqual(c.frame.width + 0.5, c.naturalWidth)
            XCTAssertGreaterThanOrEqual(c.frame.width, 36, "a cap is never narrower than it is tall")
            // Glyph stays centered in a widened cap.
            if c.frame.width > c.naturalWidth + 1 {
                let glyph = try XCTUnwrap(c.titleLabel?.superview != nil && !(c.titleLabel?.text ?? "").isEmpty
                                          ? c.titleLabel : c.imageView)
                XCTAssertEqual(glyph.convert(glyph.bounds, to: c).midX, c.bounds.midX, accuracy: 1,
                               "\(c.titleLabel?.text ?? "image") glyph off-center")
            }
        }

        // Few keys → one row, stretched to fill after a rebuild.
        Shortcuts.save(try ["esc", "tab"].map(key))
        bar.reload()
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.rowCount, 1)
        try fillsRow(rows(bar)[0])
    }

    func testFilledScalesOnlyWhenItFits() {
        let w: [CGFloat] = [40, 60, 100]
        let f = ShortcutBar.filled(w, spacing: 6, available: 300)
        XCTAssertEqual(f.reduce(0, +) + 12, 300, accuracy: 0.5)
        XCTAssertLessThanOrEqual(f.reduce(0, +) + 12, 300)
        XCTAssertEqual(f[2] / f[0], 2.5, accuracy: 0.05)
        XCTAssertEqual(ShortcutBar.filled(w, spacing: 6, available: 150), w)
        XCTAssertEqual(ShortcutBar.filled([], spacing: 6, available: 150), [])
    }

    /// One key never splits, even when it alone is wider than the bar; no keys → nothing on top.
    func testOneKeyAndNoKeys() {
        XCTAssertEqual(ShortcutBar.rowSplit(widths: [500], spacing: 6, available: 200), 1)
        XCTAssertEqual(ShortcutBar.rowSplit(widths: [], spacing: 6, available: 200), 0)
    }

    // MARK: how the caps answer a finger

    @MainActor
    func testPressLiftsTheFillAndSinksTheCap() {
        var cfg = UIButton.Configuration.plain()
        cfg.background.backgroundColor = .black
        let cap = KeyCapButton(configuration: cfg)
        cap.idleFill = .black
        cap.pressedFill = .blue
        cap.idleGlow = 0.5

        XCTAssertEqual(cap.configuration?.background.backgroundColor, .black)
        XCTAssertEqual(cap.transform, .identity)

        cap.isHighlighted = true
        XCTAssertEqual(cap.configuration?.background.backgroundColor, .blue, "fill lifts under the finger")
        XCTAssertEqual(cap.layer.shadowOpacity, 1, "and the halo flares")
        XCTAssertLessThan(cap.transform.a, 1, "and the cap sinks")

        cap.isHighlighted = false
        XCTAssertEqual(cap.configuration?.background.backgroundColor, .black)
        XCTAssertEqual(cap.layer.shadowOpacity, 0.5, "back to its resting glow")
    }

    /// The ctrl cap flips armed/idle by reassigning `idleFill`, which has to take effect
    /// even when nothing is being pressed.
    @MainActor
    func testChangingTheRestingFillAppliesImmediately() {
        let cap = KeyCapButton(configuration: .plain())
        cap.idleFill = .red
        XCTAssertEqual(cap.configuration?.background.backgroundColor, .red)
        cap.idleGlow = 0.9
        XCTAssertEqual(cap.layer.shadowOpacity, 0.9)
    }

    func testEnterSendsCRAndIsADefault() {
        let enter = Shortcuts.catalog.first { $0.id == "enter" }
        XCTAssertEqual(enter?.bytes, [0x0d])
        XCTAssertTrue(Shortcuts.defaults.contains { $0.id == "enter" })
    }

    // MARK: sticky modifiers, the send key, the default bar (#450)

    private static func caps(_ v: UIView) -> [KeyCapButton] {
        v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) }
    }
    /// A bar holding `ids`, laid out at `width`; the stored bar is restored afterwards.
    @MainActor
    private func makeBar(_ ids: [String], width: CGFloat = 402) throws -> ShortcutBar {
        let saved = UserDefaults.standard.string(forKey: Shortcuts.storageKey)
        addTeardownBlock {
            if let saved { UserDefaults.standard.set(saved, forKey: Shortcuts.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: Shortcuts.storageKey) }
        }
        Shortcuts.save(try ids.map(key))
        let bar = ShortcutBar()
        bar.frame = CGRect(x: 0, y: 0, width: width, height: 86)
        bar.layoutIfNeeded()
        return bar
    }

    func testAltAndShiftAreModifiersBesideCtrl() throws {
        XCTAssertEqual(try key("alt").kind, .alt)
        XCTAssertEqual(try key("alt").label, "alt")
        XCTAssertEqual(try key("shift").kind, .shift)
        XCTAssertEqual(try key("shift").label, "shift")
        XCTAssertEqual(ShortcutKey.Kind(rawValue: "ctrl"), .ctrl, "saved bars encode ctrl as \"ctrl\"")
    }

    /// once = solid fill, read as "on"; locked = the same fill plus a dark bar under the
    /// label, read as "locked"; off = no fill, no bar, no value.
    @MainActor
    func testLockedModifierShowsItsLight() throws {
        let bar = try makeBar(["ctrl", "alt", "shift"])
        let byLabel = Dictionary(uniqueKeysWithValues: Self.caps(bar).map { ($0.accessibilityLabel ?? "", $0) })
        let ctrl = try XCTUnwrap(byLabel["ctrl"]), alt = try XCTUnwrap(byLabel["alt"]), shift = try XCTUnwrap(byLabel["shift"])
        let idleFill = ctrl.configuration?.background.backgroundColor

        bar.modes = [.ctrl: .once, .alt: .locked]
        bar.layoutIfNeeded()

        let ctrlLED = try XCTUnwrap(ctrl.led), altLED = try XCTUnwrap(alt.led), shiftLED = try XCTUnwrap(shift.led)
        XCTAssertTrue(ctrlLED.isHidden, "once shows no light")
        XCTAssertTrue(shiftLED.isHidden, "off shows no light")
        XCTAssertFalse(altLED.isHidden, "locked shows the light")
        XCTAssertEqual(ctrl.accessibilityValue, "on")
        XCTAssertEqual(alt.accessibilityValue, "locked")
        XCTAssertNil(shift.accessibilityValue)
        XCTAssertNotEqual(ctrl.configuration?.background.backgroundColor, idleFill, "once fills the cap")
        XCTAssertEqual(alt.configuration?.background.backgroundColor, ctrl.configuration?.background.backgroundColor,
                       "locked fills the cap like once")
        XCTAssertEqual(shift.configuration?.background.backgroundColor, idleFill, "off keeps the dark card")
        XCTAssertEqual(altLED.backgroundColor, ctrl.configuration?.baseForegroundColor, "the bar is the dark glyph colour")
        XCTAssertEqual(alt.configuration?.baseForegroundColor, ctrl.configuration?.baseForegroundColor, "locked glyph is the once glyph")
        XCTAssertGreaterThan(alt.layer.shadowOpacity, ctrl.layer.shadowOpacity - 0.01, "locked glows at least as hard")

        // The bar: short, centered under the label, inside the cap.
        let led = altLED.frame
        XCTAssertEqual(led.width, 16, accuracy: 1)
        XCTAssertEqual(led.height, 2, accuracy: 0.34)   // one pixel at 3x
        XCTAssertEqual(led.midX, alt.bounds.midX, accuracy: 0.5)
        XCTAssertTrue(alt.bounds.contains(led), "the light sits inside the cap")
        let title = try XCTUnwrap(alt.titleLabel)
        let baseline = title.convert(CGPoint(x: 0, y: title.bounds.midY + title.font.lineHeight / 2 + title.font.descender), to: alt).y
        XCTAssertGreaterThanOrEqual(led.minY - baseline, 4, "the bar sits just under the label")
        XCTAssertLessThanOrEqual(led.minY - baseline, 7, "the bar hugs the label, not the cap's edge")

        bar.modes = [:]
        XCTAssertTrue(altLED.isHidden, "off again hides the light")
        XCTAssertNil(alt.accessibilityValue)
        bar.modes = [.alt: .locked]
        bar.layoutIfNeeded()
        XCTAssertEqual(altLED.frame, led, "the bar keeps its place through mode changes")
    }

    /// The send key: Slack's paper plane, labelled "send", with a doubled border.
    @MainActor
    func testSendCapIsAPaperPlaneWithADoubleBorder() throws {
        let send = try key("enter")
        XCTAssertEqual(send.label, "send")
        XCTAssertEqual(send.systemImage, "paperplane.fill")
        XCTAssertNotNil(UIImage(systemName: "paperplane.fill"))

        let bar = try makeBar(["esc", "enter"])
        let caps = Self.caps(bar)
        let cap = try XCTUnwrap(caps.first { $0.accessibilityLabel == "send" })
        let esc = try XCTUnwrap(caps.first { $0.accessibilityLabel == "esc" })
        XCTAssertNotNil(cap.configuration?.image, "the send cap shows the paper plane")
        let ring = try XCTUnwrap(cap.ring, "no inner ring")
        XCTAssertNil(esc.ring)
        XCTAssertGreaterThan(ring.layer.borderWidth, 0)
        XCTAssertEqual(ring.frame.minX, 2.5, accuracy: 0.34, "the inner ring sits 2-3 pt inside the outer stroke")
        XCTAssertEqual(cap.bounds.maxY - ring.frame.maxY, 2.5, accuracy: 0.34)
        XCTAssertGreaterThan(cap.configuration?.background.strokeWidth ?? 0, esc.configuration?.background.strokeWidth ?? 0,
                             "the outer stroke is stronger than the other caps'")
        XCTAssertGreaterThan(cap.layer.shadowOpacity, esc.layer.shadowOpacity, "and so is the halo")
    }

    /// The default bar on an iPhone 17 (402 pt): 8 over 8, columns paired as in the
    /// operator's screenshot — paste/esc … insert/send.
    @MainActor
    func testDefaultBarSplitsEightByEightOnIPhone17() throws {
        let bar = try makeBar(Shortcuts.defaults.map(\.id), width: 402)
        let caps = Self.caps(bar)
        XCTAssertEqual(caps.count, 16)
        let widths = caps.map(\.naturalWidth)
        print("450-split natural=\(widths)")
        XCTAssertEqual(ShortcutBar.rowSplit(widths: widths, spacing: 6, available: 402 - 16), 8)
        XCTAssertEqual(bar.rowCount, 2)
        let top = caps.filter { $0.superview === caps[0].superview }
        XCTAssertEqual(top.compactMap(\.accessibilityLabel), Shortcuts.defaults.prefix(8).map(\.label))
    }

    /// A grid at most 6% too wide squeezes to fit instead of scrolling; wider still scrolls.
    func testFilledSqueezesASmallOverflow() {
        let w: [CGFloat] = [40, 60, 100]                 // span 212
        let f = ShortcutBar.filled(w, spacing: 6, available: 200)
        XCTAssertLessThanOrEqual(f.reduce(0, +) + 12, 200)
        XCTAssertEqual(f.reduce(0, +) + 12, 200, accuracy: 0.5)
        XCTAssertEqual(f[2] / f[0], 2.5, accuracy: 0.05)
        let edge = 200 * ShortcutBar.minFillScale + 12  // exactly the narrowest squeeze
        XCTAssertNotEqual(ShortcutBar.filled(w, spacing: 6, available: edge), w)
        XCTAssertEqual(ShortcutBar.filled(w, spacing: 6, available: edge - 1), w)
    }

    /// QA #277: the default bar on the narrower phones (SE/mini 375, 390, 393) squeezes
    /// instead of clipping the send key; 402+ is untouched. Nothing scrolls, the send cap
    /// sits wholly inside the bar, and no cap's label truncates.
    @MainActor
    func testDefaultBarFitsTheNarrowPhones() throws {
        for width: CGFloat in [375, 390, 393, 402, 440] {
            let bar = try makeBar(Shortcuts.defaults.map(\.id), width: width)
            XCTAssertEqual(bar.rowCount, 2, "\(width)")
            let caps = Self.caps(bar)
            let sv = try XCTUnwrap(caps[0].superview?.superview?.superview as? UIScrollView)
            XCTAssertLessThanOrEqual(sv.contentSize.width, sv.bounds.width + 0.01, "\(width): scrolls")
            let send = try XCTUnwrap(caps.first { $0.accessibilityLabel == "send" })
            XCTAssertTrue(bar.bounds.contains(send.convert(send.bounds, to: bar)), "\(width): send clipped")
            for c in caps {
                if let t = c.titleLabel, !(t.text ?? "").isEmpty {
                    XCTAssertLessThanOrEqual(t.intrinsicContentSize.width, t.bounds.width + 0.5,
                                             "\(width): \(t.text ?? "") truncates")
                }
            }
            print("454-widths \(width): \(caps.map { "\($0.accessibilityLabel ?? "?")=\($0.frame.width)/\($0.naturalWidth)" })")
        }
    }

    /// QA #279: one bar re-laid out across squeezed widths (Split View, Stage Manager)
    /// keeps every cap's natural width — the squeeze's shrunken insets never feed back.
    @MainActor
    func testSqueezedBarReLaidOutAcrossWidthsIsStable() throws {
        let bar = try makeBar(Shortcuts.defaults.map(\.id), width: 375)
        var first: [CGFloat]?
        for width: CGFloat in [375, 393, 375, 390, 380, 375] {
            bar.frame.size.width = width
            bar.layoutIfNeeded()
            let caps = Self.caps(bar)
            let sv = try XCTUnwrap(caps[0].superview?.superview?.superview as? UIScrollView)
            XCTAssertLessThanOrEqual(sv.contentSize.width, sv.bounds.width + 0.01, "\(width): scrolls")
            for c in caps {
                if let t = c.titleLabel, !(t.text ?? "").isEmpty {
                    XCTAssertLessThanOrEqual(t.intrinsicContentSize.width, t.bounds.width + 0.5,
                                             "\(width): \(t.text ?? "") truncates")
                }
            }
            let natural = caps.map(\.naturalWidth)
            if let first {
                for (a, b) in zip(natural, first) { XCTAssertEqual(a, b, accuracy: 0.01, "\(width): drift") }
            } else { first = natural }
        }
    }

    /// A saved bar that is exactly the old default was never customized: it loads as the
    /// new default. Any other keeps its set and order and gains the send key if missing.
    func testOldDefaultBarMigratesAndSendIsAlwaysThere() throws {
        let saved = UserDefaults.standard.string(forKey: Shortcuts.storageKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: Shortcuts.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: Shortcuts.storageKey) }
        }
        Shortcuts.save(try ["paste", "pasteImg", "up", "down", "stab", "snl", "enter",
                            "esc", "ctlc", "left", "right", "pgup", "pgdn", "insert"].map(key))
        XCTAssertEqual(Shortcuts.load().map(\.id), Shortcuts.defaults.map(\.id))

        Shortcuts.save(try ["paste", "stab", "snl", "esc", "ctlc"].map(key))
        XCTAssertEqual(Shortcuts.load().map(\.id), ["paste", "stab", "snl", "esc", "ctlc", "enter"])

        Shortcuts.save(try ["enter", "esc"].map(key))
        XCTAssertEqual(Shortcuts.load().map(\.id), ["enter", "esc"], "a bar with send keeps its order")

        UserDefaults.standard.removeObject(forKey: Shortcuts.storageKey)
        XCTAssertEqual(Shortcuts.load().map(\.id), Shortcuts.defaults.map(\.id))
    }

    func testPasteImageGlyphIsPortrait() throws {
        let name = try XCTUnwrap(try key("pasteImg").systemImage)
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let img = try XCTUnwrap(UIImage(systemName: name, withConfiguration: cfg))
        XCTAssertGreaterThan(img.size.height, img.size.width, "\(name) is not portrait")
    }
}
