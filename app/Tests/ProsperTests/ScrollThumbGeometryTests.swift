import XCTest
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
}
