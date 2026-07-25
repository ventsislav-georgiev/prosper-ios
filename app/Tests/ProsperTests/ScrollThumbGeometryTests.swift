import XCTest
import SwiftTerm
@testable import Prosper

/// The wheel has one resting place: the middle of what you can see. A pill that
/// rests low reads as broken before it is ever dragged.
@MainActor
final class ScrollThumbGeometryTests: XCTestCase {

    private func makeVC(_ size: CGSize) -> TerminalHostVC {
        let conn = SessionConnection(transport: SpyTransport(),
                                     session: DchSession(name: "t", alias: nil))
        let vc = TerminalHostVC(conn: conn, handle: TermHandle())
        vc.view.frame = CGRect(origin: .zero, size: size)
        vc.view.layoutIfNeeded()
        return vc
    }

    /// The strip (44pt wide, right edge) and the pill inside it.
    private func thumbAndPill(_ vc: TerminalHostVC) throws -> (strip: UIView, pill: UIView) {
        let strip = try XCTUnwrap(vc.view.subviews.first { $0.bounds.width == 44 },
                                 "no 44pt scroll strip in the hierarchy")
        let pill = try XCTUnwrap(strip.subviews.first, "the strip has no pill")
        return (strip, pill)
    }

    /// The strip must start where the black screen starts — the nav bar lives inside the
    /// top safe area, so a strip anchored to the view's top hides behind it and rests the
    /// pill half a nav bar high. Same edge as the terminal view, on device and here.
    func testStripStartsWhereTheTerminalDoes() throws {
        let vc = makeVC(CGSize(width: 393, height: 852))
        let (strip, _) = try thumbAndPill(vc)
        let tv = try XCTUnwrap(vc.view.subviews.first { $0 is TerminalView }, "no terminal view")
        XCTAssertEqual(strip.frame.minY, tv.frame.minY, accuracy: 0.5,
                       "strip starts at \(strip.frame.minY), the visible terminal at \(tv.frame.minY)")
    }

    func testPillRestsInTheMiddleOfTheVisibleTerminal() throws {
        let vc = makeVC(CGSize(width: 393, height: 852))
        let (strip, pill) = try thumbAndPill(vc)
        let pillCenter = pill.convert(CGPoint(x: pill.bounds.midX, y: pill.bounds.midY), to: vc.view).y
        let stripCenter = strip.convert(CGPoint(x: 0, y: strip.bounds.midY), to: vc.view).y
        XCTAssertEqual(pillCenter, stripCenter, accuracy: 1,
                       "pill rests \(pillCenter - stripCenter)pt off the strip's middle")
        let visibleMiddle = vc.view.bounds.midY
        XCTAssertEqual(pillCenter, visibleMiddle, accuracy: 1,
                       "pill rests at \(pillCenter) but the middle of the screen is \(visibleMiddle)")
    }

    /// With the keyboard up the visible screen ends at the shortcut bar, and the wheel
    /// has to rest in the middle of THAT — measuring against the keyboard height left
    /// the pill a safe-area inset low.
    func testPillRestsInTheMiddleAboveTheKeyboard() throws {
        let vc = makeVC(CGSize(width: 393, height: 852))
        let keyboard = CGRect(x: 0, y: 500, width: 393, height: 352)
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboard)])
        vc.view.layoutIfNeeded()

        let (strip, pill) = try thumbAndPill(vc)
        let bar = try XCTUnwrap(vc.view.subviews.first { $0 is ShortcutBar }, "no shortcut bar")
        let tv = try XCTUnwrap(vc.view.subviews.first { $0 is TerminalView }, "no terminal view")
        let pillCenter = pill.convert(CGPoint(x: 0, y: pill.bounds.midY), to: vc.view).y
        XCTAssertEqual(strip.frame.maxY, bar.frame.minY, accuracy: 1,
                       "the strip must end where the shortcut bar begins")
        let visibleMiddle = (tv.frame.minY + bar.frame.minY) / 2
        XCTAssertEqual(pillCenter, visibleMiddle, accuracy: 1,
                       "pill rests at \(pillCenter); the middle of the visible screen is \(visibleMiddle)")
    }
}
