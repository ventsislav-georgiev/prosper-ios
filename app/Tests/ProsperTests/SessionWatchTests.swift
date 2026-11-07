import XCTest
import Network
@testable import Prosper

/// #775: the session list pushed over the Mac's 0x2e watch stream: the gate, the frames, the
/// silence that counts as dead, the refusals that fall back to the poll, and the socket closed
/// with the task. A loopback Mac only.
@MainActor
final class SessionWatchTests: XCTestCase {
    private var saved: (UserDefaults, TimeInterval, String?)!
    private var defaults: UserDefaults!
    private let a = DchSession(name: "a", state: "idle"), b = DchSession(name: "b", state: "working")

    override func setUp() async throws {
        saved = (SidekickSync.defaults, SessionWatch.reopen, UserDefaults.standard.string(forKey: UpdateMode.key))
        defaults = UserDefaults(suiteName: "session-watch-tests")!
        defaults.removePersistentDomain(forName: "session-watch-tests")
        SidekickSync.defaults = defaults
        SessionWatch.reopen = 0.05
    }

    override func tearDown() async throws {
        SidekickSync.offer([], over: SidekickSpy())
        (SidekickSync.defaults, SessionWatch.reopen) = (saved.0, saved.1)
        UserDefaults.standard.set(saved.2, forKey: UpdateMode.key)
        defaults.removePersistentDomain(forName: "session-watch-tests")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static let listA = #"[{"name":"a","state":"idle"}]"#
    private static let listAB = #"[{"name":"a","state":"idle"},{"name":"b","state":"working"}]"#
    private static let listB = #"[{"name":"b","state":"working"}]"#

    /// The stream run as the list's task does, each list it applies collected.
    private func run(_ t: SessionTransport, _ lists: Box<[[DchSession]]>) -> Task<Bool, Never> {
        Task { await SessionWatch.run(t, device: "phone-1") { lists.v.append($0) } }
    }

    // MARK: The gate

    /// Only Real-time on a Mac listing "watch": Battery saver, Low Power Mode and a Mac without
    /// it keep the poll.
    func testOnlyRealTimeOnAMacListingWatchOpensTheStream() {
        XCTAssertEqual(SessionVerb.offered(["watch", "sidekick"]), [.watch, .sidekick])
        XCTAssertTrue(SessionWatch.wanted([.watch], .live))
        XCTAssertFalse(SessionWatch.wanted([.watch], .saver), "Battery saver polls")
        XCTAssertFalse(SessionWatch.wanted([.watch], UpdateMode.resolve(stored: "live", lowPower: true)), "Low Power Mode polls")
        XCTAssertFalse(SessionWatch.wanted(SessionVerb.offered(["sidekick", "history", "library"]), .live), "no watch, no stream")
        XCTAssertFalse(SessionWatch.wanted([], .live), "an older Mac lists no ops")
    }

    /// A transport without the stream (the demo, the test stubs) refuses it: the poll runs.
    func testATransportWithoutTheStreamFallsBackToThePoll() async {
        let refused = await SessionWatch.run(SidekickSpy(), device: nil) { _ in XCTFail("no list") }
        XCTAssertTrue(refused)
    }

    // MARK: The stream

    func testASnapshotThenAChangeUpdatesTheList() async throws {
        let mac = try await WatchMac { _, c in
            send(c, 0x11, Self.listA)
            send(c, 0x14, #"{"sidekick":{"pattern":"-qa","updated":0}}"#)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { send(c, 0x11, Self.listAB) }
        }
        defer { mac.listener.cancel() }
        let lists = Box<[[DchSession]]>([])
        let task = run(try await mac.transport(), lists)
        try await waitUntil("the change") { lists.v.count == 2 }
        XCTAssertEqual(lists.v, [[a], [a, b]])
        XCTAssertEqual(mac.requests.v.first?.0, 0x2e)
        let sent = mac.requests.v.first.flatMap { (try? JSONSerialization.jsonObject(with: $0.1)) as? NSDictionary }
        XCTAssertEqual(sent, ["device_id": "phone-1"])
        task.cancel()
        _ = await task.value
    }

    /// The Mac's pattern lands with its own stamp; an older one leaves the phone's, and the
    /// phone's newer one goes to the Mac over 0x2d.
    func testTheSidekickFrameIsAdopted() async throws {
        defaults.set("-mine", forKey: DchSession.sidekickKey)
        defaults.set(100, forKey: SidekickSync.updatedKey)
        let mac = try await WatchMac { _, c in
            send(c, 0x11, Self.listA)
            send(c, 0x14, #"{"sidekick":{"pattern":" -mac ","updated":200}}"#)
        }
        defer { mac.listener.cancel() }
        let task = run(try await mac.transport(), Box([]))
        try await waitUntil("adopted") { SidekickSync.local().pattern == " -mac " }
        XCTAssertEqual(SidekickSync.local(), SidekickValue(pattern: " -mac ", updated: 200))
        task.cancel()
        _ = await task.value

        XCTAssertEqual(ProsperTransport.decodeWatchOk(Data("{}".utf8)), .heartbeat)
        XCTAssertEqual(ProsperTransport.decodeWatchOk(Data(#"{"sidekick":"x"}"#.utf8)), .heartbeat, "unreadable: no pattern")
        XCTAssertEqual(ProsperTransport.decodeWatchOk(Data(#"{"sidekick":{"pattern":"x","updated":true}}"#.utf8)), .heartbeat)

        let spy = SidekickSpy()
        SidekickSync.offer([.sidekick, .watch], over: spy)
        SidekickSync.pushed(SidekickValue(pattern: "-old", updated: 150))
        try await waitUntil("ours sent") { !SidekickSync.running && spy.sent.count == 1 }
        XCTAssertEqual(spy.sent, [SidekickValue(pattern: " -mac ", updated: 200)])
        XCTAssertEqual(SidekickSync.local().pattern, " -mac ", "the older one is not taken")
    }

    /// In Real-time a Mac listing "watch" sends its pattern on the stream: connect sends no 0x2d.
    /// Battery saver, or no stream, keeps it.
    func testTheStreamReplacesTheConnectSync() async throws {
        UserDefaults.standard.set("live", forKey: UpdateMode.key)
        let spy = SidekickSpy()
        SidekickSync.offer([.sidekick, .watch], over: spy)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(spy.sent.count, 0)
        UserDefaults.standard.set("saver", forKey: UpdateMode.key)
        SidekickSync.offer([.sidekick, .watch], over: spy)
        try await waitUntil("Battery saver syncs") { !SidekickSync.running && spy.sent.count == 1 }
        UserDefaults.standard.set("live", forKey: UpdateMode.key)
        SidekickSync.offer([.sidekick], over: spy)
        try await waitUntil("a refused stream syncs") { !SidekickSync.running && spy.sent.count == 2 }
    }

    /// Heartbeats keep a stream that sends no list alive past the silence limit; silence past
    /// it is a dead stream, opened again, and the new one's list lands.
    func testHeartbeatsKeepItAliveAndSilenceReopensIt() async throws {
        let mac = try await WatchMac { n, c in
            send(c, 0x11, n == 0 ? Self.listA : Self.listB)
            guard n == 0 else { return }
            for i in 1...6 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(i)) { send(c, 0x14, "{}") } }
        }
        defer { mac.listener.cancel() }
        let t = try await mac.transport()
        XCTAssertEqual(t.watchSilence, 60, "the shipped limit")
        t.watchSilence = 0.4
        let lists = Box<[[DchSession]]>([])
        let task = run(t, lists)
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertEqual(mac.requests.v.count, 1, "the heartbeats kept it alive")
        try await waitUntil("reopened after the silence") { lists.v.count == 2 }
        XCTAssertEqual(mac.requests.v.count, 2)
        XCTAssertEqual(lists.v, [[a], [b]])
        task.cancel()
        _ = await task.value
    }

    func testSilenceThrows() async throws {
        let mac = try await WatchMac { _, _ in }
        defer { mac.listener.cancel() }
        let t = try await mac.transport()
        t.watchSilence = 0.3
        let start = Date()
        do {
            for try await _ in t.watch(device: nil) { XCTFail("nothing was sent") }
            XCTFail("silence is no clean close")
        } catch let e as TransportError {
            guard case .hostUnreachable = e else { return XCTFail("wrong case: \(e)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(mac.requests.v.first?.1, Data("{}".utf8), "no device id: the Mac takes the address")
    }

    /// Error 0x13 (Agent Island off): back to the poll, never a reconnect loop.
    func testAnErrorFallsBackToThePoll() async throws {
        let mac = try await WatchMac { _, c in
            send(c, 0x13, #"{"message":"watch needs Agent Island listing Remote Terminal's sessions"}"#)
        }
        defer { mac.listener.cancel() }
        let lists = Box<[[DchSession]]>([])
        let refused = await run(try await mac.transport(), lists).value
        XCTAssertTrue(refused)
        XCTAssertEqual(lists.v, [])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mac.requests.v.count, 1, "not opened again")
    }

    /// The Mac closing the stream between frames (its island stopped): back to the poll too.
    /// One cut mid-frame is a dead stream, opened again.
    func testACleanCloseFallsBackToThePoll() async throws {
        let mac = try await WatchMac { n, c in
            if n == 0 {
                c.send(content: FrameCodec.encode(0x11, Data(Self.listA.utf8)).prefix(8), contentContext: .finalMessage,
                       isComplete: true, completion: .idempotent)
                return
            }
            send(c, 0x11, Self.listB)
            c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        }
        defer { mac.listener.cancel() }
        let lists = Box<[[DchSession]]>([])
        let refused = await run(try await mac.transport(), lists).value
        XCTAssertTrue(refused)
        XCTAssertEqual(lists.v, [[b]], "the cut frame never applied")
        XCTAssertEqual(mac.requests.v.count, 2, "the cut one opened again, the clean close not")
    }

    /// The list's task ending (background, a sheet, a pushed session) closes the socket: the
    /// Mac's cap of 4 streams per device never fills with dead ones.
    func testEndingTheTaskClosesTheSocket() async throws {
        let mac = try await WatchMac { _, c in send(c, 0x11, Self.listA) }
        defer { mac.listener.cancel() }
        let lists = Box<[[DchSession]]>([])
        let task = run(try await mac.transport(), lists)
        try await waitUntil("the snapshot") { lists.v.count == 1 }
        XCTAssertEqual(mac.closed.v, 0)
        task.cancel()
        let refused = await task.value
        XCTAssertFalse(refused, "cancelled is no refusal")
        try await waitUntil("the Mac sees the close") { mac.closed.v == 1 }
        XCTAssertEqual(mac.requests.v.count, 1)
    }
}

private func send(_ c: NWConnection, _ type: UInt8, _ json: String) {
    c.send(content: FrameCodec.encode(type, Data(json.utf8)), completion: .idempotent)
}

/// A loopback Mac: each connection's first frame is recorded, then `serve` scripts that
/// connection, by its index. `closed` counts the connections whose phone end went away.
@MainActor
private final class WatchMac {
    let listener: NWListener
    let requests = Box<[(UInt8, Data)]>([])
    let closed = Box(0)

    init(_ serve: @escaping (Int, NWConnection) -> Void) async throws {
        let requests = requests, closed = closed
        listener = try loopbackServer { c in
            let buf = Box(Data())
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                    if let d { buf.v.append(d) }
                    if let frame = try? FrameCodec.pop(&buf.v) {
                        requests.v.append(frame)
                        serve(requests.v.count - 1, c)
                    }
                    if done || err != nil { closed.v += 1 } else { read() }
                }
            }
            read()
        }
        let end = Date().addingTimeInterval(3)
        while (listener.port?.rawValue ?? 0) == 0 {
            if Date() > end { throw XCTSkip("loopback listener never came up") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func transport() async throws -> ProsperTransport {
        ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue)
    }
}

/// A Mac that records each 0x2d and answers with what it was sent; no stream.
private final class SidekickSpy: SessionTransport {
    var sent: [SidekickValue] = []
    func sidekickSync(_ mine: SidekickValue) async throws -> SidekickValue { sent.append(mine); return mine }
    func listSessions() async throws -> [DchSession] { [] }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
        throw TransportError.notConnected
    }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}
