import XCTest
@testable import Prosper

/// The session list's state poll and the labels it feeds.
final class SessionPollTests: XCTestCase {

    /// A row's state has to catch up within a few seconds, without the app dialing the
    /// Mac constantly, and a dead Mac must be dialed much less often than a live one.
    /// #764: a list taken at once, then 5 s, doubling while nothing moves, to 30 s; any change
    /// is 5 s again.
    func testBackoffSchedule() {
        var wait: TimeInterval? = nil   // a return: listed at once
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            wait = SessionPoll.next(after: wait, changed: false, mode: .live)
            waits.append(wait!)
        }
        XCTAssertEqual(waits, [5, 10, 20, 30, 30, 30])
        XCTAssertEqual(SessionPoll.next(after: 30, changed: true), 5, "a change: fast again")
        XCTAssertEqual(SessionPoll.next(after: nil, changed: true), 5)
        XCTAssertEqual(SessionPoll.next(after: 5, changed: true), 5)
    }

    /// A failed poll waits the backoff, and never shortens a longer wait.
    func testFailureBackoff() {
        XCTAssertEqual(SessionPoll.failed(after: nil), 20)
        XCTAssertEqual(SessionPoll.failed(after: 5), 20)
        XCTAssertEqual(SessionPoll.failed(after: 30), 30)
        XCTAssertEqual(SessionPoll.next(after: SessionPoll.failed(after: 5), changed: false), 30, "back, still: slow")
        XCTAssertEqual(SessionPoll.next(after: SessionPoll.failed(after: 5), changed: true), 5, "back, moved: fast")
    }

    /// #764: Battery saver: 15 s, doubling to 2 min; a change is 15 s again.
    func testBatterySaverSchedule() {
        var wait: TimeInterval? = nil
        var waits: [TimeInterval] = []
        for _ in 0..<5 {
            wait = SessionPoll.next(after: wait, changed: false, mode: .saver)
            waits.append(wait!)
        }
        XCTAssertEqual(waits, [15, 30, 60, 120, 120])
        XCTAssertEqual(SessionPoll.next(after: 120, changed: true, mode: .saver), 15)
        XCTAssertEqual(SessionPoll.next(after: 5, changed: false, mode: .saver), 15, "a switch mid-poll: never faster than its floor")
        XCTAssertEqual(SessionPoll.next(after: 120, changed: false, mode: .live), 30, "and never slower than its cap")
    }

    func testPollBounds() {
        XCTAssertGreaterThanOrEqual(SessionPoll.fastest(.live), 5, "faster is traffic for nothing")
        XCTAssertLessThanOrEqual(SessionPoll.slowest(.live), 30, "a label older than this reads as stale")
        XCTAssertGreaterThan(SessionPoll.failureBackoff, SessionPoll.fastest(.live) * 2)
    }

    /// #771: Real-time rides out a quick app switch; Battery saver detaches at once.
    func testDetachGrace() {
        XCTAssertEqual(UpdateMode.live.detachGrace, .seconds(30))
        XCTAssertEqual(UpdateMode.saver.detachGrace, .zero)
        XCTAssertEqual(UpdateMode.resolve(stored: "live", lowPower: true).detachGrace, .zero, "Low Power Mode is saver")
    }

    func testStateStyleParsing() {
        XCTAssertEqual(SessionStateStyle("blocked"), .blocked)
        XCTAssertEqual(SessionStateStyle("done"), .done)
        XCTAssertNil(SessionStateStyle("compacting"))
        XCTAssertNil(SessionStateStyle(nil))
        XCTAssertNil(SessionStateStyle(""))
    }
}
