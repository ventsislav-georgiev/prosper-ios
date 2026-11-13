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

    // MARK: #964: the loop

    private let a = DchSession(name: "a", state: "idle"), b = DchSession(name: "b", state: "working")

    /// What one run of the loop did: each wait asked for, each list applied, each refusal shown.
    private struct Run { var waits: [TimeInterval] = []; var applied: [[DchSession]] = []; var refused: [String] = []; var listed = 0 }

    /// Runs `SessionPoll.run` over `mac` with no real sleeping, cancelled at the `stop`th wait.
    @MainActor
    private func loop(_ mac: ScriptedMac, mode: UpdateMode = .live, first: TimeInterval?, shown: [DchSession] = [],
                      ready: @escaping () -> Bool = { true }, stop: Int) async -> Run {
        let run = Box(Run()), turns = Box(0)
        await Task { @MainActor in
            // A loop that never waits (a mutant) still ends: cancelled after 50 turns.
            await SessionPoll.run(mac, mode: mode, first: first, shown: { shown }, ready: {
                                      turns.v += 1
                                      if turns.v > 50 { withUnsafeCurrentTask { $0?.cancel() } }
                                      return ready()
                                  },
                                  apply: { run.v.applied.append($0) }, refused: { run.v.refused.append($0.localizedDescription) },
                                  listed: { run.v.listed += 1 },
                                  sleep: { wait in
                                      run.v.waits.append(wait)
                                      if run.v.waits.count >= stop { withUnsafeCurrentTask { $0?.cancel() } }
                                  })
        }.value
        return run.v
    }

    /// A poll task started before the first refresh ends waits its first interval before
    /// listing; one started after lists at once. Cancelled in the wait: no list goes out.
    @MainActor
    func testTheFirstWaitIsHonouredAndCancellingInItSendsNothing() async {
        let waited = ScriptedMac([.success([a])])
        let r = await loop(waited, first: 5, stop: 1)
        XCTAssertEqual(r.waits, [5])
        XCTAssertEqual(waited.lists, 0, "cancelled in the first wait: no request")
        XCTAssertEqual(r.applied, [])

        let atOnce = ScriptedMac([.success([a])])
        let r2 = await loop(atOnce, first: nil, shown: [a], stop: 1)
        XCTAssertEqual(atOnce.lists, 1, "listed before any wait")
        XCTAssertEqual(r2.waits, [5], "then the fastest wait")
    }

    /// A still list doubles the wait to `slowest`; a change is `fastest` again. The first poll
    /// compares against what is shown, later ones against the previous poll. Each list is applied.
    @MainActor
    func testAChangeSpeedsUpAndAStillListSlowsDownToSlowest() async {
        let lists = [[a], [a], [a], [a], [a], [a, b], [a, b]]
        let mac = ScriptedMac(lists.map { .success($0) })
        let r = await loop(mac, first: nil, shown: [a], stop: lists.count)
        XCTAssertEqual(r.waits, [5, 10, 20, 30, 30, 5, 10])
        XCTAssertEqual(r.applied, lists, "apply gets each list")
        XCTAssertEqual(r.listed, lists.count)
        XCTAssertEqual(mac.lists, lists.count)

        let saver = ScriptedMac([[a], [a], [a], [a], [b]].map { .success($0) })
        let s = await loop(saver, mode: .saver, first: 15, shown: [a], stop: 6)
        XCTAssertEqual(s.waits, [15, 30, 60, 120, 120, 15], "Battery saver: its own floor and cap")
    }

    /// A failed poll waits the failure backoff and is not applied; a refusal is shown, "busy"
    /// and an unreachable Mac are not. Back, still: slow.
    @MainActor
    func testAFailureBacksOff() async {
        let mac = ScriptedMac([.failure(TransportError.hostUnreachable("x")), .failure(TransportError.refused(code: "busy", message: "busy")),
                               .failure(TransportError.refused(code: "denied", message: "turned away")), .success([a])])
        let r = await loop(mac, first: nil, shown: [a], stop: 4)
        XCTAssertEqual(r.waits, [20, 20, 20, 30])
        XCTAssertEqual(r.refused, ["turned away"])
        XCTAssertEqual(r.applied, [[a]])
        XCTAssertEqual(mac.lists, 4)
    }

    /// While the screen is not ready (unreachable, in error, loading) no list goes out, and the
    /// wait still grows.
    @MainActor
    func testNotReadySkipsThePoll() async {
        let mac = ScriptedMac([.success([a])])
        let r = await loop(mac, first: nil, ready: { false }, stop: 3)
        XCTAssertEqual(r.waits, [5, 10, 20])
        XCTAssertEqual(mac.lists, 0)
    }

    /// Cancelled while a list is in flight: it is not applied, and the loop ends with no wait
    /// and no further request.
    @MainActor
    func testCancelledDuringAListAppliesNothing() async {
        let mac = ScriptedMac([.success([a]), .success([b])])
        mac.cancelAt = 2
        let r = await loop(mac, first: nil, shown: [a], stop: 99)
        XCTAssertEqual(mac.lists, 2)
        XCTAssertEqual(r.applied, [[a]], "the list that landed after the cancel is dropped")
        XCTAssertEqual(r.waits, [5])
    }

    /// #1028: a refresh 3.8 s into a 5 s wait lists; the poll then waits until 5 s after that
    /// list, not 1.2 s later. A list from before the wait (the poll's own) re-arms nothing.
    @MainActor
    func testAListInTheWaitPushesTheNextPollAFullWaitLater() async {
        let mac = ScriptedMac([.success([a]), .success([a]), .success([a])])
        let t0 = Date(timeIntervalSince1970: 1_000)
        let clock = Box(t0), listedAt = Box<Date?>(nil), waits = Box([TimeInterval]()), polledAt = Box([TimeInterval]())
        await Task { @MainActor in
            await SessionPoll.run(mac, mode: .live, first: nil, shown: { [a] }, ready: { true },
                                  apply: { _ in listedAt.v = clock.v; polledAt.v.append(clock.v.timeIntervalSince(t0)) },
                                  refused: { _ in }, listedAt: { listedAt.v }, now: { clock.v },
                                  sleep: { wait in
                                      waits.v.append(wait)
                                      if waits.v.count == 1 { listedAt.v = clock.v + 3.8 }   // the refresh
                                      clock.v += wait
                                      if waits.v.count >= 4 { withUnsafeCurrentTask { $0?.cancel() } }
                                  })
        }.value
        XCTAssertEqual(waits.v.count, 4)
        XCTAssertEqual(waits.v[0], 5)
        XCTAssertEqual(waits.v[1], 3.8, accuracy: 0.001, "the rest of a full wait from the refresh")
        XCTAssertEqual(polledAt.v.count, 3)
        XCTAssertEqual(polledAt.v[1], 8.8, accuracy: 0.001, "the next list 5 s after the refresh's, not 1.2 s")
        XCTAssertEqual(Array(waits.v[2...]), [10, 20], "the backoff goes on as before")
    }
}

/// #964: a Mac that answers each list from a script and counts them; it cancels the polling
/// task during the `cancelAt`th list, and once the script runs out, so a runaway loop ends.
private final class ScriptedMac: SessionTransport {
    var lists = 0
    var cancelAt = 0
    private let script: [Result<[DchSession], Error>]
    init(_ script: [Result<[DchSession], Error>]) { self.script = script }
    func listSessions() async throws -> [DchSession] {
        lists += 1
        if lists == cancelAt || lists > script.count { withUnsafeCurrentTask { $0?.cancel() } }
        return try script[min(lists, script.count) - 1].get()
    }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
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
