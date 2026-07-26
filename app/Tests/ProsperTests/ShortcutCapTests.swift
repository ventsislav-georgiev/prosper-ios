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
        XCTAssertEqual(Shortcuts.defaults.count, 11)
        XCTAssertEqual(Set(Shortcuts.catalog.map(\.id)).count, Shortcuts.catalog.count)
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
}
