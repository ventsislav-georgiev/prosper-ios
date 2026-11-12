import XCTest
import Network
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

/// #801: a host that doesn't answer reads as one line naming it by its label, never with the
/// transport's reason; a host that accepts and closes with no frame is the same as a timeout.
final class UnreachableLineTests: XCTestCase {
    private let studio = "Can't reach Studio. Check Tailscale, and that Prosper or dch serve is running on it."

    private func mac(_ accept: @escaping (NWConnection) -> Void) async throws -> (ProsperTransport, NWListener) {
        let listener = try loopbackServer(accept)
        let end = Date().addingTimeInterval(3)
        while (listener.port?.rawValue ?? 0) == 0 {
            if Date() > end { throw XCTSkip("loopback listener never came up") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return (ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue), listener)
    }

    func testATimeoutNamesTheLabelNotTheReason() async throws {
        let (t, listener) = try await mac { _ in }   // accepts, never answers
        defer { listener.cancel() }
        do {
            _ = try await connectFirst(["127.0.0.1"], timeout: 0.3) { _ in try await t.listSessions() }
            XCTFail("nothing answered")
        } catch {
            guard case TransportError.hostUnreachable = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(TransportError.message(error, host: "Studio"), studio)
            XCTAssertFalse(error.localizedDescription.contains("timed out"))
        }
    }

    func testAHostThatClosesWithNoFrameIsUnreachable() async throws {
        let (t, listener) = try await mac { $0.cancel() }   // a refused peer: accept, then close
        defer { listener.cancel() }
        do {
            _ = try await t.listSessions()
            XCTFail("nothing answered")
        } catch {
            guard case TransportError.hostUnreachable = error else { return XCTFail("raw error: \(error)") }
            XCTAssertEqual(TransportError.message(error, host: "Studio"), studio)
        }
    }

    func testAResetIsUnreachableAndOtherErrorsAreNot() {
        XCTAssertTrue(ProsperTransport.droppedBeforeReply(NWError.posix(.ECONNRESET)))
        XCTAssertTrue(ProsperTransport.droppedBeforeReply(TransportError.protocolError(FrameCodec.closedEarly)))
        XCTAssertFalse(ProsperTransport.droppedBeforeReply(TransportError.protocolError("frame too large")))
        XCTAssertFalse(ProsperTransport.droppedBeforeReply(TransportError.server("off")))
        XCTAssertEqual(TransportError.message(TransportError.server("off"), host: "Studio"), "off")
    }
}

/// #889: the options every connection to the Mac uses, read off the value; no socket.
final class TCPOptionsTests: XCTestCase {
    func testTCPOptionsKeepaliveDropTimeAndNoDelay() {
        let tcp = ProsperTransport.tcpOptions()
        XCTAssertTrue(tcp.enableKeepalive)
        XCTAssertEqual(tcp.keepaliveIdle, 15)
        XCTAssertEqual(tcp.keepaliveInterval, 5)
        XCTAssertEqual(tcp.keepaliveCount, 3)
        XCTAssertEqual(tcp.connectionDropTime, 15)
        XCTAssertTrue(tcp.noDelay)
    }
}

/// #827: a loopback dch serve gate: on accept, before reading a byte, one error 0x13 `json`
/// and FIN; then it reads until the phone's EOF and closes, as the server does. `accepted`
/// counts the connections.
func refusingServer(_ json: String, accepted: Box<Int>) async throws -> NWListener {
    let listener = try loopbackServer { c in
        accepted.v += 1
        c.send(content: FrameCodec.encode(0x13, Data(json.utf8)), contentContext: .finalMessage, isComplete: true,
               completion: .idempotent)
        func drain() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { _, _, done, err in
                if done || err != nil { c.cancel() } else { drain() }
            }
        }
        drain()
    }
    let end = Date().addingTimeInterval(3)
    while (listener.port?.rawValue ?? 0) == 0 {
        if Date() > end { throw XCTSkip("loopback listener never came up") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return listener
}

/// #827: dch serve's gate refusal (error 0x13 with a "code") reads as refused, not offline: its
/// message as written, the address walk stopped, never the unreachable line.
@MainActor
final class GateRefusalTests: XCTestCase {
    private let notOwner = #"{"code":"not_owner","message":"This Mac belongs to another tailnet user."}"#

    func testListSessionsThrowsTheRefusalWithItsCodeAndMessage() async throws {
        let accepted = Box(0)
        let listener = try await refusingServer(notOwner, accepted: accepted)
        defer { listener.cancel() }
        do {
            _ = try await ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue).listSessions()
            XCTFail("refused")
        } catch {
            guard case TransportError.refused(let code, let message) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(code, "not_owner")
            XCTAssertEqual(message, "This Mac belongs to another tailnet user.")
            XCTAssertEqual(TransportError.message(error, host: "Studio"), message, "as written, never the unreachable line")
            XCTAssertTrue((error as? TransportError)?.isRefusal == true)
        }
    }

    /// The first address refusing ends the walk: the second is the same host and is never dialed.
    func testARefusalStopsTheAddressWalk() async throws {
        let accepted = Box(0)
        let listener = try await refusingServer(notOwner, accepted: accepted)
        defer { listener.cancel() }
        let t = ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue)
        let probes = Box<[String]>([])
        do {
            _ = try await connectFirst(["first", "second"], timeout: 2) { addr -> [DchSession] in
                probes.v.append(addr)
                guard addr == "first" else { return [] }
                return try await t.listSessions()
            }
            XCTFail("refused")
        } catch {
            guard case TransportError.refused(let code, _) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(code, "not_owner")
        }
        XCTAssertEqual(probes.v, ["first"], "no attempt on the second address")
        XCTAssertEqual(accepted.v, 1)
    }

    /// An unknown code is still a refusal; "busy" (the connection limit) is not: the walk goes on.
    func testBusyIsNoStopAndAnUnknownCodeIs() async throws {
        XCTAssertTrue(TransportError.refused(code: "something_new", message: "no").isRefusal)
        XCTAssertFalse(TransportError.refused(code: "busy", message: "later").isRefusal)
        XCTAssertFalse(TransportError.server("off").isRefusal)
        let accepted = Box(0)
        let listener = try await refusingServer(#"{"code":"busy","message":"Too many connections.","retry_after":2}"#,
                                                accepted: accepted)
        defer { listener.cancel() }
        let t = ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue)
        let probes = Box<[String]>([]), first = Box<Error?>(nil)
        let (_, addr) = try await connectFirst(["first", "second"], timeout: 2) { addr -> [DchSession] in
            probes.v.append(addr)
            guard addr == "first" else { return [] }
            do { return try await t.listSessions() } catch { first.v = error; throw error }
        }
        XCTAssertEqual(addr, "second")
        XCTAssertEqual(probes.v, ["first", "second"])
        guard case TransportError.refused("busy", "Too many connections.")? = first.v else {
            return XCTFail("wrong error: \(String(describing: first.v))")
        }
    }

    /// #827 QA: the session list's refresh turned away "busy" tries again after the poll's failure
    /// backoff (it stuck on "Host busy"); a gate refusal, an unreachable host and a cancel hold.
    func testOnlyABusyRefreshRetries() async throws {
        let accepted = Box(0)
        let listener = try await refusingServer(#"{"code":"busy","message":"Host busy"}"#, accepted: accepted)
        defer { listener.cancel() }
        do {
            _ = try await ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue).listSessions()
            XCTFail("busy")
        } catch {
            XCTAssertEqual(SessionListView.retryWait(error), SessionPoll.failureBackoff)
            XCTAssertEqual(TransportError.message(error, host: "Studio"), "Host busy", "shown meanwhile")
        }
        XCTAssertNil(SessionListView.retryWait(TransportError.refused(code: "not_owner", message: "no")))
        XCTAssertNil(SessionListView.retryWait(TransportError.hostUnreachable("timed out")))
        XCTAssertNil(SessionListView.retryWait(TransportError.server("Host busy")))
        XCTAssertNil(SessionListView.retryWait(CancellationError()))
    }

    /// #827: the keyboard's Commands panel shows a gate refusal as written, never "Mac not reachable".
    func testTheKeyboardsReachShowsARefusalAsWritten() async throws {
        let accepted = Box(0)
        let listener = try await refusingServer(notOwner, accepted: accepted)
        defer { listener.cancel() }
        let port = listener.port!.rawValue
        do {
            _ = try await CommandsSession.reach(["127.0.0.1"]) { ProsperTransport(host: $0, port: port) }()
            XCTFail("refused")
        } catch {
            XCTAssertEqual(CommandsSession.copy(error.localizedDescription), "This Mac belongs to another tailnet user.")
        }
        XCTAssertEqual(accepted.v, 1)
    }

    /// A 0x13 without "code" is the Mac's own error, as before #827: `.server`, its message.
    func testAnErrorWithoutACodeIsStillServer() async throws {
        let accepted = Box(0)
        let listener = try await refusingServer(#"{"message":"history is off"}"#, accepted: accepted)
        defer { listener.cancel() }
        let t = ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue)
        for op in [{ _ = try await t.history() }, { _ = try await t.listSessions() }] as [() async throws -> Void] {
            do { try await op(); XCTFail("an error") } catch {
                guard case TransportError.server(let m) = error else { return XCTFail("wrong error: \(error)") }
                XCTAssertEqual(m, "history is off")
            }
        }
    }
}
