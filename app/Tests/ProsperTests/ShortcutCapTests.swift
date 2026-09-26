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
        XCTAssertEqual(Shortcuts.defaults.map(\.id), ["paste", "pasteImg", "insert", "ctlc", "stab", "snl", "esc", "left", "right", "up", "down", "pgup", "pgdn"])
        XCTAssertEqual(Set(Shortcuts.catalog.map(\.id)).count, Shortcuts.catalog.count)
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

    /// The user's build-69 set at phone width: every column's two caps share an edge
    /// and a width, and a one-row set keeps natural widths.
    @MainActor
    func testTwoRowBarColumnsLineUp() throws {
        let saved = UserDefaults.standard.string(forKey: Shortcuts.storageKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: Shortcuts.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: Shortcuts.storageKey) }
        }
        let ids = ["paste", "pasteImg", "up", "down", "stab", "snl", "enter",
                   "esc", "ctlc", "left", "right", "pgup", "pgdn", "insert"]
        Shortcuts.save(try ids.map(key))

        let bar = ShortcutBar()
        bar.frame = CGRect(x: 0, y: 0, width: 393, height: 86)
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

    func testEnterIsACatalogOptionNotADefault() {
        let enter = Shortcuts.catalog.first { $0.id == "enter" }
        XCTAssertEqual(enter?.bytes, [0x0d])
        XCTAssertFalse(Shortcuts.defaults.contains { $0.id == "enter" })
    }

    func testPasteImageGlyphIsPortrait() throws {
        let name = try XCTUnwrap(try key("pasteImg").systemImage)
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let img = try XCTUnwrap(UIImage(systemName: name, withConfiguration: cfg))
        XCTAssertGreaterThan(img.size.height, img.size.width, "\(name) is not portrait")
    }
}
