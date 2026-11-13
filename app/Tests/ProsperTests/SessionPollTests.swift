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

    /// #963: launch lists once. The first refresh lists, its handshake ends (`connected`), then
    /// the scene turns active 0.2 s later and restarts the poll: that list answers it. A
    /// foreground return later, a verb's relist (`listedAt` cleared) and the poll's own tick
    /// still list.
    func testLaunchListsOnceAndLaterTriggersStillList() async throws {
        let mac = CountingMac()
        var listedAt: Date?
        let t0 = Date()
        // What a poll task does when it starts: its first list at once, or only after a wait.
        func pollStarts(connected: Bool, at now: Date) async throws {
            guard SessionPoll.first(connected: connected, listedAt: listedAt, mode: .live, now: now) == nil else { return }
            _ = try await mac.listSessions()
            listedAt = now
        }
        try await pollStarts(connected: false, at: t0)          // first appear: refresh in flight, waits
        _ = try await mac.listSessions(); listedAt = t0          // the refresh
        try await pollStarts(connected: true, at: t0 + 0.2)      // scene active just after it
        XCTAssertEqual(mac.lists, 1, "launch: one list")

        try await pollStarts(connected: true, at: t0 + 10)       // back from the background
        XCTAssertEqual(mac.lists, 2, "a return still lists")
        listedAt = nil                                           // a verb's relist
        try await pollStarts(connected: true, at: t0 + 10.5)
        XCTAssertEqual(mac.lists, 3, "a relist still lists at once")
        XCTAssertEqual(SessionPoll.first(connected: true, listedAt: t0, mode: .live, now: t0 + 0.2), SessionPoll.fastest(.live),
                       "the answered start waits the usual interval, no longer")
    }

    func testFirstPollComparesAgainstShownList() {
        XCTAssertFalse(SessionPoll.changed([1, 2], last: nil, shown: [1, 2]), "#774: refresh filled the list after the task started")
        XCTAssertTrue(SessionPoll.changed([1, 2], last: nil, shown: [1]))
        XCTAssertTrue(SessionPoll.changed([1, 2], last: [1], shown: [1, 2]), "later polls compare against the previous poll")
        XCTAssertFalse(SessionPoll.changed([1], last: [1], shown: []))
    }
}

/// #963: a Mac that counts the session lists it is asked for.
private final class CountingMac: SessionTransport {
    var lists = 0
    func listSessions() async throws -> [DchSession] { lists += 1; return [] }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}
