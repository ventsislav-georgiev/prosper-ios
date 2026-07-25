import XCTest
@testable import Prosper

/// The Live Activity decisions. ActivityKit itself can't run in CI (no Catalyst, no
/// simulator island), so the rules live in a pure planner and get pinned here.
final class SessionActivityPlanTests: XCTestCase {

    private func list(_ pairs: [(String, String)]) -> [DchSession] {
        pairs.map { DchSession(name: $0.0, alias: nil, state: $0.1) }
    }

    /// A watched session with no activity yet gets one; an unwatched one doesn't.
    func testStartsOnlyWatchedSessions() {
        let plan = SessionActivityPlan.make(sessions: list([("a", "working"), ("b", "working")]),
                                            watched: ["a"], shown: [:], limit: 3)
        XCTAssertEqual(plan, SessionActivityPlan(start: ["a"], update: [], end: []))
    }

    /// The island only gets poked when the state actually changed — an update per poll
    /// would be five system calls a second for nothing.
    func testUnchangedStateDoesNothing() {
        let plan = SessionActivityPlan.make(sessions: list([("a", "working")]),
                                            watched: ["a"], shown: ["a": "working"], limit: 3)
        XCTAssertTrue(plan.isEmpty, "got \(plan)")
    }

    func testChangedStateUpdates() {
        let plan = SessionActivityPlan.make(sessions: list([("a", "blocked")]),
                                            watched: ["a"], shown: ["a": "working"], limit: 3)
        XCTAssertEqual(plan, SessionActivityPlan(start: [], update: ["a"], end: []))
    }

    /// `done` is terminal: end the activity instead of holding a slot for a session that
    /// will never change again — and never start a new one for an already-finished session.
    func testDoneEndsAndIsNeverStarted() {
        XCTAssertEqual(SessionActivityPlan.make(sessions: list([("a", "done")]),
                                                watched: ["a"], shown: ["a": "working"], limit: 3),
                       SessionActivityPlan(start: [], update: [], end: ["a"]))
        XCTAssertTrue(SessionActivityPlan.make(sessions: list([("a", "done")]),
                                               watched: ["a"], shown: [:], limit: 3).isEmpty)
    }

    /// Bell off → off the island. Same for a session that got killed.
    func testUnwatchedAndVanishedEnd() {
        XCTAssertEqual(SessionActivityPlan.make(sessions: list([("a", "working")]),
                                                watched: [], shown: ["a": "working"], limit: 3),
                       SessionActivityPlan(start: [], update: [], end: ["a"]))
        XCTAssertEqual(SessionActivityPlan.make(sessions: [], watched: ["a"],
                                                shown: ["a": "working"], limit: 3),
                       SessionActivityPlan(start: [], update: [], end: ["a"]))
    }

    /// The cap holds: watching five sessions fills the slots and stops.
    func testSlotCapIsRespected() {
        let sessions = list([("a", "working"), ("b", "working"), ("c", "working"),
                            ("d", "working"), ("e", "working")])
        let plan = SessionActivityPlan.make(sessions: sessions, watched: ["a", "b", "c", "d", "e"],
                                            shown: [:], limit: 3)
        XCTAssertEqual(plan.start, ["a", "b", "c"], "list order decides who gets a slot")
        XCTAssertTrue(plan.update.isEmpty)
        XCTAssertTrue(plan.end.isEmpty)
    }

    /// Existing activities count against the cap, so a poll doesn't quietly double up.
    func testExistingActivitiesSpendSlots() {
        let sessions = list([("a", "working"), ("b", "working"), ("c", "working")])
        let plan = SessionActivityPlan.make(sessions: sessions, watched: ["a", "b", "c"],
                                            shown: ["a": "working", "b": "working"], limit: 3)
        XCTAssertEqual(plan.start, ["c"])
    }

    /// A slot freed by a finishing session is reusable in the same pass.
    func testFinishedSessionFreesItsSlot() {
        let sessions = list([("a", "done"), ("b", "working"), ("c", "working"), ("d", "working")])
        let plan = SessionActivityPlan.make(sessions: sessions, watched: ["a", "b", "c", "d"],
                                            shown: ["a": "working", "b": "working", "c": "working"],
                                            limit: 3)
        XCTAssertEqual(plan.end, ["a"])
        XCTAssertEqual(plan.start, ["d"], "a's slot goes to the next watched session")
    }

    /// An unknown state from a newer Mac still tracks (it just draws a neutral badge) and
    /// is never mistaken for `done`.
    func testUnknownStateIsTreatedAsRunning() {
        let plan = SessionActivityPlan.make(sessions: list([("a", "compacting")]),
                                            watched: ["a"], shown: [:], limit: 3)
        XCTAssertEqual(plan.start, ["a"])
    }

    /// Nothing watched, nothing shown → no work at all (the common case on every poll).
    func testIdleMachinePlansNothing() {
        XCTAssertTrue(SessionActivityPlan.make(sessions: list([("a", "working")]),
                                               watched: [], shown: [:], limit: 3).isEmpty)
    }

    /// Response requirement: the island must not be able to outnumber the cutout.
    func testCapIsSane() {
        XCTAssertLessThanOrEqual(SessionLiveActivities.maxActive, 4)
        XCTAssertGreaterThanOrEqual(SessionLiveActivities.maxActive, 1)
        // Response requirement the other way round: updates only flow while the app is in
        // front, so the island must stay trusted long enough to be useful in another app.
        XCTAssertGreaterThanOrEqual(SessionLiveActivities.staleAfter, 60,
                                    "greying out seconds after the app leaves makes the island pointless")
        XCTAssertLessThanOrEqual(SessionLiveActivities.staleAfter, SessionLiveActivities.dismissAfter,
                                 "and it must go stale well before a finished session is dismissed")
    }
}
