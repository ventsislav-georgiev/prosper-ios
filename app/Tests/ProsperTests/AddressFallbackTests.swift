import XCTest
@testable import Prosper

/// Walking a machine's several addresses (PLAN §3). The money case is the SILENT one: a
/// stale LAN address or a sleeping Mac never refuses the connection, so without a
/// per-address deadline the first entry swallows the whole attempt and the rest are
/// never tried — which is exactly the bug these pin.
/// Probe counter shared with a concurrent probe closure.
private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class AddressFallbackTests: XCTestCase {

    /// A refused first address falls through to the second.
    func testFallsBackPastAFailingAddress() async throws {
        let (value, addr) = try await connectFirst(["dead", "live"], timeout: 1) { host in
            guard host == "live" else { throw TransportError.hostUnreachable(host) }
            return host
        }
        XCTAssertEqual(value, "live")
        XCTAssertEqual(addr, "live")
    }

    /// A SILENT first address costs its own timeout and no more — the rest of the list
    /// still gets tried.
    func testSilentAddressTimesOutAndTheNextOneWins() async throws {
        let started = CFAbsoluteTimeGetCurrent()
        let (_, addr) = try await connectFirst(["black-hole", "live"], timeout: 0.2) { host in
            if host == "black-hole" { try await Task.sleep(nanoseconds: 5_000_000_000) }
            return host
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(addr, "live")
        XCTAssertLessThan(elapsed, 2, "the hung address must not swallow the attempt (took \(elapsed)s)")
        XCTAssertGreaterThan(elapsed, 0.15, "it should have waited out its deadline first")
    }

    /// A working first address wins immediately; nothing further is dialed.
    func testFirstWorkingAddressWinsAndStopsTheWalk() async throws {
        var tried: [String] = []
        let (_, addr) = try await connectFirst(["a", "b", "c"], timeout: 1) { host in
            tried.append(host)
            return host
        }
        XCTAssertEqual(addr, "a")
        XCTAssertEqual(tried, ["a"], "later addresses must not be probed once one answers")
    }

    /// Every address failing throws the LAST error — hostUnreachable is what promotes
    /// the Wake card, so it must survive the walk.
    func testAllFailingThrowsTheLastError() async {
        do {
            _ = try await connectFirst(["a", "b"], timeout: 1) { host -> String in
                throw TransportError.hostUnreachable(host)
            }
            XCTFail("expected a throw")
        } catch let e as TransportError {
            guard case .hostUnreachable(let host) = e else { return XCTFail("wrong case: \(e)") }
            XCTAssertEqual(host, "b")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// An empty list throws instead of hanging or returning junk.
    func testEmptyListThrows() async {
        do {
            _ = try await connectFirst([], timeout: 1) { $0 }
            XCTFail("expected a throw")
        } catch {}
    }

    /// Blank entries (a stray line in the address editor) are skipped, not dialed.
    func testBlankAddressesAreSkipped() async throws {
        var tried: [String] = []
        let (_, addr) = try await connectFirst(["", "   ", "live"], timeout: 1) { host in
            tried.append(host)
            return host
        }
        XCTAssertEqual(addr, "live")
        XCTAssertEqual(tried, ["live"])
    }

    /// `onTry` reports each address as it is dialed, in order — that is what the loading
    /// row shows, so a stuck walk is visible instead of one anonymous spinner.
    @MainActor
    func testOnTryReportsEachAddressInOrder() async throws {
        var shown: [String] = []
        let (_, addr) = try await connectFirst(["a", "b", "c"], timeout: 1,
                                              onTry: { shown.append($0) }) { host in
            guard host == "c" else { throw TransportError.hostUnreachable(host) }
            return host
        }
        XCTAssertEqual(addr, "c")
        XCTAssertEqual(shown, ["a", "b", "c"])
    }

    /// Leaving the screen cancels the walk: the remaining addresses must not be dialed,
    /// and the error must read as a cancellation so the UI can swallow it instead of
    /// printing "Swift.CancellationError" at the user.
    func testCancellationStopsTheWalkAndIsRecognisable() async {
        let dialed = LockedCount()
        let task = Task {
            try await connectFirst(["a", "b", "c"], timeout: 5) { host -> String in
                dialed.bump()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw TransportError.hostUnreachable(host)
            }
        }
        // Let the first probe get going, then walk away mid-dial.
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(isCancellation(error), "surfaced \(error) instead of a cancellation")
        }
        XCTAssertEqual(dialed.value, 1, "cancelled walk kept dialing the rest of the list")
    }

    /// A real failure is NOT a cancellation — the Wake card and the error text depend on
    /// telling those apart.
    func testRealFailuresAreNotMistakenForCancellation() {
        XCTAssertFalse(isCancellation(TransportError.hostUnreachable("mac")))
        XCTAssertTrue(isCancellation(CancellationError()))
        XCTAssertTrue(isCancellation(URLError(.cancelled)))
        XCTAssertFalse(isCancellation(URLError(.timedOut)))
    }

    /// The shipped deadline is the 5s the connect UI is built around.
    func testDefaultTimeoutIsFiveSeconds() {
        XCTAssertEqual(addressAttemptTimeout, 5)
    }

    /// withDeadline hands back the value when the work beats the clock, and cancels the
    /// loser — a leaked sleeper would keep the task group alive.
    func testWithDeadlinePassesFastWorkThrough() async throws {
        let v = try await withDeadline(seconds: 1) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testWithDeadlineThrowsUnreachableOnTimeout() async {
        do {
            _ = try await withDeadline(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 0
            }
            XCTFail("expected a timeout")
        } catch let e as TransportError {
            guard case .hostUnreachable = e else { return XCTFail("wrong case: \(e)") }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
