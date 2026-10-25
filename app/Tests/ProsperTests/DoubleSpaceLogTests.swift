import XCTest
import UIKit
@testable import Prosper

/// The temporary double-space log (#540): shapes, never characters; a capped ring; a line
/// per space naming the branch. Remove with `DoubleSpaceLog`.
@MainActor
final class DoubleSpaceLogTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "DoubleSpaceLogTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testTheShapeNeverShowsACharacter() {
        XCTAssertEqual(DoubleSpaceLog.shape(nil), "nil")
        XCTAssertEqual(DoubleSpaceLog.shape(""), "-")
        XCTAssertEqual(DoubleSpaceLog.shape("say hi. "), "LPS")
        XCTAssertEqual(DoubleSpaceLog.shape("x\n😀"), "LNE")
        XCTAssertEqual(DoubleSpaceLog.shape("ok1️⃣"), "LLE", "a keycap is an emoji")
        for text in ["Hello, world", "здравей ", "LSNPE", "a$b", "Ⓜ️❤️\r\n", "tab\t"] {
            let shape = DoubleSpaceLog.shape(text)
            XCTAssertTrue(shape.allSatisfy { "LSNPE".contains($0) }, shape)
            XCTAssertEqual(shape.count, min(3, text.count), text)
        }
    }

    func testTheRingKeepsTheNewestLines() {
        for i in 0..<70 { DoubleSpaceLog.add("line \(i)", to: defaults) }
        let lines = DoubleSpaceLog.lines(in: defaults)
        XCTAssertEqual(lines.count, DoubleSpaceLog.cap)
        XCTAssertTrue(lines.first!.hasSuffix(" line 69"), "newest first")
        XCTAssertTrue(lines.last!.hasSuffix(" line 10"))
        DoubleSpaceLog.add("unstored", to: nil)
        DoubleSpaceLog.clear(defaults)
        XCTAssertEqual(DoubleSpaceLog.lines(in: defaults), [])
    }

    /// The extension's: a word's first space is plain, its second a period, each logged
    /// with the context's shape and never its text.
    func testEachSpaceLogsItsBranchInAHostField() {
        let kb = TerminalKeyboard(), doc = KeyboardExtensionTests.FakeProxy()
        kb.target = doc
        kb.doubleSpacePeriod = true
        kb.spaceLog = defaults
        kb.press(.char("q")); kb.press(.space); kb.press(.space)
        XCTAssertEqual(doc.text, "q. ")
        let lines = DoubleSpaceLog.lines(in: defaults)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[2].hasSuffix(" ext attach"), "a keyboard made afresh")
        XCTAssertTrue(lines[0].contains(" ext space +"), lines[0])
        XCTAssertTrue(lines[0].contains(" before=LS doubles=1 third=0 mark=. dsp=1 doc=1 kt=0 ctx=LS period=1 fs=0 bytes=0 -> period"), lines[0])
        XCTAssertTrue(lines[1].contains(" ext space +"), lines[1])
        XCTAssertTrue(lines[1].contains(" before=L doubles=0 "), lines[1])
        XCTAssertTrue(lines[1].hasSuffix("-> plain"), lines[1])
        XCTAssertFalse(lines.joined().contains("q"), "no typed character")
    }

    /// The terminal's: the second space goes out as bytes and clears the history, logged
    /// in that order. No store writes nothing.
    func testEachSpaceLogsItsBranchInTheTerminal() {
        let kb = TerminalKeyboard()
        var sent: [[UInt8]] = []
        kb.sendBytes = { sent.append($0) }
        kb.spaceLog = defaults
        kb.press(.char("q")); kb.press(.space); kb.press(.space)
        XCTAssertEqual(sent, [[0x7f, 0x2e, 0x20]])
        let lines = DoubleSpaceLog.lines(in: defaults)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasSuffix(" app clear sent"), lines[0])
        XCTAssertTrue(lines[1].contains(" app space +"), lines[1])
        XCTAssertTrue(lines[1].hasSuffix(" doc=0 kt=- ctx=nil period=0 fs=0 bytes=1 -> bytes"), lines[1])

        let quiet = TerminalKeyboard()
        quiet.sendBytes = { _ in }
        quiet.press(.char("q")); quiet.press(.space); quiet.press(.space)
        XCTAssertNil(quiet.spaceLog)
        XCTAssertEqual(DoubleSpaceLog.lines(in: defaults).count, 4, "no store, no lines")
    }

    /// A space touch logs its phases; a hold that turns it into the trackpad says so.
    func testSpaceTouchesAreLogged() throws {
        let kb = TerminalKeyboard()
        kb.frame = CGRect(x: 0, y: 0, width: 390, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        kb.sendBytes = { _ in }
        kb.spaceLog = defaults
        let cap = try XCTUnwrap(kb.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "space" })
        let space = CGPoint(x: cap.frame.midX, y: cap.frame.midY)
        XCTAssertEqual(kb.key(at: space), .space)
        kb.track(.began, id: 1, at: space)
        kb.track(.ended, id: 1, at: space)
        kb.track(.began, id: 2, at: space)
        kb.track(.cancelled, id: 2, at: CGPoint(x: space.x + 3, y: space.y))
        kb.track(.began, id: 3, at: space)
        kb.fireHold()
        kb.track(.ended, id: 3, at: space)
        let touches = DoubleSpaceLog.lines(in: defaults).reversed().map { $0.split(separator: " ").dropFirst(2).joined(separator: " ") }
            .filter { $0.hasPrefix("touch") }
        XCTAssertEqual(touches, [
            "touch began travel=0 below=0 done=0", "touch ended travel=0 below=0 done=0",
            "touch began travel=0 below=0 done=0", "touch cancelled travel=3 below=0 done=0",
            "touch began travel=0 below=0 done=0", "touch trackpad", "touch ended travel=0 below=0 done=1",
        ])
    }
}
