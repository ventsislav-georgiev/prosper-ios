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
        let vc = CopyTextVC(text: text, cols: 80)
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

    /// #457: "One line" joins the selection in the editor, toggling off restores it,
    /// and the choice is remembered.
    @MainActor
    func testOneLineToggleJoinsAndRestoresTheSelection() throws {
        let saved = UserDefaults.standard.object(forKey: CopyTextVC.oneLineKey)
        defer { UserDefaults.standard.set(saved, forKey: CopyTextVC.oneLineKey) }
        UserDefaults.standard.set(false, forKey: CopyTextVC.oneLineKey)

        let raw = "curl https://exa\n  mple.com \\\n  -o out"
        let vc = CopyTextVC(text: raw, cols: 16)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        win.rootViewController = UINavigationController(rootViewController: vc)
        win.isHidden = false
        win.layoutIfNeeded()
        let views = vc.view.subviews.compactMap { $0 as? UITextView }
        let (source, editor) = (views[0], views[1])
        source.selectedRange = NSRange(location: 0, length: raw.utf16.count)
        vc.textViewDidChangeSelection(source)
        XCTAssertEqual(editor.text, raw)

        let item = try XCTUnwrap(vc.navigationItem.rightBarButtonItems?
            .first { $0.accessibilityLabel == "One line" })
        let tap = { UIApplication.shared.sendAction(item.action!, to: item.target, from: item, for: nil) }
        tap()
        XCTAssertEqual(editor.text, "curl https://example.com -o out")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: CopyTextVC.oneLineKey))
        tap()
        XCTAssertEqual(editor.text, raw)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: CopyTextVC.oneLineKey))
    }

    /// #459: never toggled, One line starts on, so a selected wrapped command lands in
    /// the editor (the clipboard) already joined.
    @MainActor
    func testOneLineIsOnByDefault() throws {
        let saved = UserDefaults.standard.object(forKey: CopyTextVC.oneLineKey)
        defer { UserDefaults.standard.set(saved, forKey: CopyTextVC.oneLineKey) }
        UserDefaults.standard.removeObject(forKey: CopyTextVC.oneLineKey)

        let raw = "curl https://exa\n  mple.com \\\n  -o out"
        let vc = CopyTextVC(text: raw, cols: 16)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        win.rootViewController = UINavigationController(rootViewController: vc)
        win.isHidden = false
        win.layoutIfNeeded()
        let views = vc.view.subviews.compactMap { $0 as? UITextView }
        let (source, editor) = (views[0], views[1])
        source.selectedRange = NSRange(location: 0, length: raw.utf16.count)
        vc.textViewDidChangeSelection(source)
        XCTAssertEqual(editor.text, "curl https://example.com -o out")
        let item = try XCTUnwrap(vc.navigationItem.rightBarButtonItems?
            .first { $0.accessibilityLabel == "One line" })
        XCTAssertTrue(item.isSelected)
    }
}
