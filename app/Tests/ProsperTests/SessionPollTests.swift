import XCTest
@testable import Prosper

/// The session list's state poll and the labels it feeds.
final class SessionPollTests: XCTestCase {

    /// A row's state has to catch up within a few seconds, without the app dialing the
    /// Mac constantly, and a dead Mac must be dialed much less often than a live one.
    func testPollCadence() {
        XCTAssertLessThanOrEqual(SessionPoll.interval, 5)
        XCTAssertGreaterThanOrEqual(SessionPoll.interval, 2, "faster is traffic for nothing")
        XCTAssertGreaterThan(SessionPoll.failureBackoff, SessionPoll.interval * 2)
    }

    /// An unknown state has to come back nil (the row shows no label) rather than a
    /// wrong badge.
    func testStateStyleParsing() {
        XCTAssertEqual(SessionStateStyle("blocked"), .blocked)
        XCTAssertEqual(SessionStateStyle("done"), .done)
        XCTAssertNil(SessionStateStyle("compacting"))
        XCTAssertNil(SessionStateStyle(nil))
        XCTAssertNil(SessionStateStyle(""))
    }
}
