import XCTest
@testable import Prosper

final class CopyViewTests: XCTestCase {
    /// Copy mode opens on the last line even for a long buffer: UITextView lays long
    /// text out lazily, so an offset taken from the estimated contentSize would stop
    /// screens short of the end.
    @MainActor
    func testOpensAtTheEndOfALongBuffer() throws {
        let text = (1...5000).map { "line \($0) " + String(repeating: "x", count: $0 % 90) }
            .joined(separator: "\n")
        let vc = CopyTextVC(text: text)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        win.rootViewController = UINavigationController(rootViewController: vc)
        win.isHidden = false
        win.layoutIfNeeded()
        let tv = try XCTUnwrap(vc.view.subviews.compactMap { $0 as? UITextView }.first)
        let caret = tv.caretRect(for: tv.endOfDocument)
        let visible = CGRect(origin: tv.contentOffset, size: tv.bounds.size)
        XCTAssertTrue(visible.contains(CGPoint(x: caret.midX, y: caret.maxY)),
                      "last line \(caret) not in view \(visible)")
        XCTAssertEqual(tv.contentOffset.y,
                       tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom,
                       accuracy: 1, "not pinned to the bottom")
    }
}
