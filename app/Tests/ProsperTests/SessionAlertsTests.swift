import XCTest
@testable import Prosper

/// The watcher's rules. All of them live in `SessionAlertEngine.step` and the persisted
/// switch, so none of this needs a Mac, a socket or a clock.
final class SessionAlertsTests: XCTestCase {

    private func list(_ pairs: [(String, String)]) -> [DchSession] {
        pairs.map { DchSession(name: $0.0, alias: nil, state: $0.1) }
    }

    private func watchAll(_: String) -> Bool { true }

    // MARK: the two pings

    /// working → blocked pings "needs you"; working → done pings "finished".
    func testPingsOnTheTwoTransitionsThatMatter() {
        var e = SessionAlertEngine()
        XCTAssertEqual(e.step(list([("a", "working"), ("b", "working")]), now: 0, isWatched: watchAll), [])
        let first = e.step(list([("a", "blocked"), ("b", "working")]), now: 1, isWatched: watchAll)
        XCTAssertEqual(first, [SessionAlert(session: "a", style: .blocked)])
        let second = e.step(list([("a", "blocked"), ("b", "done")]), now: 2, isWatched: watchAll)
        XCTAssertEqual(second, [SessionAlert(session: "b", style: .done)])
    }

    /// Reaching `working` or `idle` is not worth a banner.
    func testQuietTransitionsDontPing() {
        var e = SessionAlertEngine()
        _ = e.step(list([("a", "blocked")]), now: 0, isWatched: watchAll)
        XCTAssertEqual(e.step(list([("a", "working")]), now: 1, isWatched: watchAll), [])
        XCTAssertEqual(e.step(list([("a", "idle")]), now: 2, isWatched: watchAll), [])
    }

    /// The FIRST sight of a session only seeds the baseline. Turning the bell on while an
    /// agent already waits must not fire a ping for something that didn't just happen.
    func testFirstSightNeverPings() {
        var e = SessionAlertEngine()
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: 0, isWatched: watchAll), [],
                       "a session that was already blocked when we started looking is not news")
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: 1, isWatched: watchAll), [],
                       "and a state that hasn't changed is still not news")
    }

    /// An unwatched session is tracked but silent — and turning its bell on afterwards
    /// doesn't retroactively ping, because the baseline already knows its state.
    func testUnwatchedIsSilentAndTogglingOnLaterIsQuiet() {
        var e = SessionAlertEngine()
        var watched = false
        _ = e.step(list([("a", "working")]), now: 0, isWatched: { _ in watched })
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: 1, isWatched: { _ in watched }), [])
        watched = true
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: 2, isWatched: { _ in watched }), [],
                       "it was already blocked before the bell went on")
        XCTAssertEqual(e.step(list([("a", "done")]), now: 3, isWatched: { _ in watched }),
                       [SessionAlert(session: "a", style: .done)])
    }

    /// The session on screen doesn't ping — the user is already looking at it.
    func testAttachedSessionIsSuppressed() {
        var e = SessionAlertEngine()
        _ = e.step(list([("a", "working")]), now: 0, isWatched: watchAll, attached: "a")
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: 1, isWatched: watchAll, attached: "a"), [])
        // Detach: the next transition pings normally.
        _ = e.step(list([("a", "working")]), now: 2, isWatched: watchAll)
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: 3, isWatched: watchAll),
                       [SessionAlert(session: "a", style: .blocked)])
    }

    // MARK: flapping

    /// dch derives state from the rendered screen, so a redrawing prompt can bounce
    /// blocked→working→blocked. The cooldown keeps that to one banner.
    func testFlappingStateOnlyPingsOncePerCooldown() {
        var e = SessionAlertEngine()
        _ = e.step(list([("a", "working")]), now: 0, isWatched: watchAll)
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: 1, isWatched: watchAll).count, 1)
        _ = e.step(list([("a", "working")]), now: 2, isWatched: watchAll)
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: 3, isWatched: watchAll), [],
                       "same session, same state, inside the cooldown → no second banner")
        _ = e.step(list([("a", "working")]), now: SessionAlertEngine.cooldown + 4, isWatched: watchAll)
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: SessionAlertEngine.cooldown + 5,
                              isWatched: watchAll).count, 1,
                       "past the cooldown it's news again")
    }

    /// A different state inside the cooldown still gets through — "done" must never be
    /// swallowed because "needs you" fired a second earlier.
    func testDoneIsNotSwallowedByAnEarlierBlockedPing() {
        var e = SessionAlertEngine()
        _ = e.step(list([("a", "working")]), now: 0, isWatched: watchAll)
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: 1, isWatched: watchAll).count, 1)
        XCTAssertEqual(e.step(list([("a", "done")]), now: 2, isWatched: watchAll),
                       [SessionAlert(session: "a", style: .done)])
    }

    /// A killed session drops out of the baseline, so the same name created later starts
    /// clean instead of inheriting the dead one's state.
    func testVanishedSessionResetsItsBaseline() {
        var e = SessionAlertEngine()
        _ = e.step(list([("a", "working")]), now: 0, isWatched: watchAll)
        XCTAssertEqual(e.step([], now: 1, isWatched: watchAll), [])
        XCTAssertEqual(e.step(list([("a", "blocked")]), now: 2, isWatched: watchAll), [],
                       "re-created session: first sight seeds, doesn't ping")
    }

    /// A state string a newer Mac invents is tracked but never pinged about.
    func testUnknownStateIsIgnored() {
        var e = SessionAlertEngine()
        _ = e.step(list([("a", "working")]), now: 0, isWatched: watchAll)
        XCTAssertEqual(e.step(list([("a", "compacting")]), now: 1, isWatched: watchAll), [])
    }

    /// An old Mac sends no state at all — nothing to ping about, and no crash.
    func testMissingStateIsIgnored() {
        var e = SessionAlertEngine()
        _ = e.step([DchSession(name: "a", alias: nil, state: nil)], now: 0, isWatched: watchAll)
        XCTAssertEqual(e.step([DchSession(name: "a", alias: nil, state: nil)], now: 1, isWatched: watchAll), [])
    }

    // MARK: hot path

    /// `step` runs on every poll. 200 sessions × 100 polls has to stay far under the 5s
    /// poll interval — this is the budget, not a benchmark.
    func testStepHotPathBudget() {
        let sessions = (0..<200).map { DchSession(name: "s\($0)", alias: nil, state: "working") }
        let flipped = sessions.map { DchSession(name: $0.name, alias: nil, state: "blocked") }
        var e = SessionAlertEngine()
        let started = CFAbsoluteTimeGetCurrent()
        for i in 0..<100 {
            _ = e.step(i.isMultiple(of: 2) ? sessions : flipped,
                       now: TimeInterval(i) * SessionAlertEngine.cooldown, isWatched: watchAll)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        XCTAssertLessThan(elapsed, 0.1, "20k session-steps took \(elapsed)s")
    }

    /// The bookkeeping must not grow with time — a screen left open for hours polls
    /// hundreds of times and must not accumulate a dictionary entry per poll.
    func testBookkeepingStaysBounded() {
        var e = SessionAlertEngine()
        for i in 0..<500 {
            // Every poll shows a differently-named session: the old ones must be dropped.
            _ = e.step(list([("s\(i)", "blocked")]), now: TimeInterval(i), isWatched: watchAll)
        }
        XCTAssertLessThanOrEqual(e.trackedCount, 4, "baseline kept \(e.trackedCount) dead sessions")
    }

    /// Response requirement: an agent that starts waiting has to be pinged within a few
    /// seconds, without the app dialing the Mac constantly, and a dead Mac must be dialed
    /// much less often than a live one.
    func testPollCadenceMeetsThePingLatencyBudget() {
        XCTAssertLessThanOrEqual(SessionAlertEngine.pollInterval, 5)
        XCTAssertGreaterThanOrEqual(SessionAlertEngine.pollInterval, 2, "faster is traffic for nothing")
        XCTAssertGreaterThan(SessionAlertEngine.failureBackoff, SessionAlertEngine.pollInterval * 2)
        XCTAssertGreaterThanOrEqual(SessionAlertEngine.cooldown, 30, "a flapping prompt must not buzz")
    }

    // MARK: the switch

    @MainActor
    func testTogglePersistsPerMachineAndSession() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionAlertsTests"))
        defaults.removePersistentDomain(forName: "SessionAlertsTests")
        let a = UUID(), b = UUID()
        let alerts = SessionAlerts(defaults: defaults)

        XCTAssertFalse(alerts.isOn(machine: a, session: "build"))
        XCTAssertTrue(alerts.toggle(machine: a, session: "build"))
        XCTAssertTrue(alerts.isOn(machine: a, session: "build"))
        XCTAssertFalse(alerts.isOn(machine: b, session: "build"), "same name on another Mac is another switch")
        XCTAssertTrue(alerts.anyWatched(machine: a))
        XCTAssertFalse(alerts.anyWatched(machine: b), "an unwatched machine must not pay for polling")

        // Survives a relaunch.
        let reopened = SessionAlerts(defaults: defaults)
        XCTAssertTrue(reopened.isOn(machine: a, session: "build"))
        XCTAssertFalse(reopened.toggle(machine: a, session: "build"))
        XCTAssertFalse(SessionAlerts(defaults: defaults).isOn(machine: a, session: "build"))
        defaults.removePersistentDomain(forName: "SessionAlertsTests")
    }

    @MainActor
    func testNamesFiltersToWatchedSessionsPresentInTheList() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionAlertsTests2"))
        defaults.removePersistentDomain(forName: "SessionAlertsTests2")
        let m = UUID()
        let alerts = SessionAlerts(defaults: defaults)
        alerts.toggle(machine: m, session: "here")
        alerts.toggle(machine: m, session: "gone")
        XCTAssertEqual(alerts.names(machine: m, in: list([("here", "working"), ("other", "idle")])),
                       ["here"])
        defaults.removePersistentDomain(forName: "SessionAlertsTests2")
    }

    // MARK: wording

    /// The banner text is what the user actually reads at 2am.
    func testPingWording() {
        XCTAssertEqual(SessionStateStyle.blocked.ping(session: "api"), "api is waiting for your input.")
        XCTAssertEqual(SessionStateStyle.done.ping(session: "api"), "api finished.")
        XCTAssertNil(SessionStateStyle.working.ping(session: "api"))
        XCTAssertNil(SessionStateStyle.idle.ping(session: "api"))
    }

    /// The state mapping is shared with the Dynamic Island, so an unknown value has to
    /// come back nil (the island draws a neutral dot) rather than a wrong badge.
    func testStateStyleParsing() {
        XCTAssertEqual(SessionStateStyle("blocked"), .blocked)
        XCTAssertEqual(SessionStateStyle("done"), .done)
        XCTAssertNil(SessionStateStyle("compacting"))
        XCTAssertNil(SessionStateStyle(nil))
        XCTAssertNil(SessionStateStyle(""))
    }
}
