import XCTest
@testable import Prosper

/// The text size is persisted user state — a bad clamp bricks the terminal grid
/// (a 0 pt font means zero cols/rows), so the store keeps it inside the range.
final class TerminalPrefsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: TerminalPrefs.sizeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TerminalPrefs.sizeKey)
        super.tearDown()
    }

    func testDefaultIsTenPercentBelowThirteen() {
        XCTAssertEqual(TerminalPrefs.fontSize, 11.7, accuracy: 0.001)
    }

    func testStoresAndReadsBack() {
        TerminalPrefs.fontSize = 14
        XCTAssertEqual(TerminalPrefs.fontSize, 14, accuracy: 0.001)
    }

    func testClampsOutOfRange() {
        TerminalPrefs.fontSize = 100
        XCTAssertEqual(TerminalPrefs.fontSize, TerminalPrefs.range.upperBound, accuracy: 0.001)
        TerminalPrefs.fontSize = 1
        XCTAssertEqual(TerminalPrefs.fontSize, TerminalPrefs.range.lowerBound, accuracy: 0.001)
    }

    /// The size is stored as a plain Double under the documented key: the editor's
    /// stepper and the terminal's font both go through here, and a type/key drift would
    /// silently reset the size on every launch.
    func testStoresAPlainDoubleUnderTheSharedKey() {
        TerminalPrefs.fontSize = 13
        XCTAssertEqual(UserDefaults.standard.double(forKey: TerminalPrefs.sizeKey), 13, accuracy: 0.001)
        XCTAssertEqual(TerminalPrefs.sizeKey, "terminalFontSize", "the key is the persisted contract")
    }

    /// A zero/garbage value (never written, or cleared) must fall back, not through.
    func testZeroFallsBackToDefault() {
        UserDefaults.standard.set(0.0, forKey: TerminalPrefs.sizeKey)
        XCTAssertEqual(TerminalPrefs.fontSize, TerminalPrefs.defaultSize, accuracy: 0.001)
    }
}
