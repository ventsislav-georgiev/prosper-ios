import XCTest
import Network
@testable import Prosper

/// #761: the sidekick pattern synced with the Mac over 0x2d: the merge, the stamps, the cap,
/// the "sidekick" gate and the read deadline. Fakes and a loopback server only.
@MainActor
final class SidekickSyncTests: XCTestCase {
    private var saved: (UserDefaults, TimeInterval)!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        saved = (SidekickSync.defaults, SidekickSync.debounce)
        defaults = UserDefaults(suiteName: "sidekick-sync-tests")!
        defaults.removePersistentDomain(forName: "sidekick-sync-tests")
        SidekickSync.defaults = defaults
    }

    override func tearDown() async throws {
        SidekickSync.offer([], over: MacFake())
        (SidekickSync.defaults, SidekickSync.debounce) = saved
        defaults.removePersistentDomain(forName: "sidekick-sync-tests")
    }

    private func set(_ pattern: String, _ updated: Int64) {
        defaults.set(pattern, forKey: DchSession.sidekickKey)
        defaults.set(updated, forKey: SidekickSync.updatedKey)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testNeverEditedReadsTheDefaultAndZero() {
        XCTAssertEqual(SidekickSync.local(), SidekickValue(pattern: "-qa", updated: 0))
    }

    func testNewerPhoneWinsAndStaysAsItWas() async throws {
        set("-rev", 200)
        let mac = MacFake(SidekickValue(pattern: "-qa", updated: 100))
        try await SidekickSync.sync(over: mac)
        XCTAssertEqual(mac.sent, [SidekickValue(pattern: "-rev", updated: 200)])
        XCTAssertEqual(mac.value, SidekickValue(pattern: "-rev", updated: 200), "the Mac adopted it")
        XCTAssertEqual(SidekickSync.local(), SidekickValue(pattern: "-rev", updated: 200))
    }

    /// The Mac's value lands with the Mac's stamp, not a new one: the next sync is a tie and
    /// nothing moves, so the two sides never bounce it.
    func testNewerMacIsAdoptedWithoutAReStamp() async throws {
        set("-rev", 100)
        let mac = MacFake(SidekickValue(pattern: " -(qa|x)$ ", updated: 200))
        try await SidekickSync.sync(over: mac)
        XCTAssertEqual(SidekickSync.local(), SidekickValue(pattern: " -(qa|x)$ ", updated: 200), "raw, untrimmed, its own stamp")
        try await SidekickSync.sync(over: mac)
        XCTAssertEqual(mac.sent.last, SidekickValue(pattern: " -(qa|x)$ ", updated: 200))
        XCTAssertEqual(SidekickSync.local(), mac.value)
    }

    func testATieGoesToTheMac() async throws {
        let mac = MacFake(SidekickValue(pattern: "-x", updated: 0))
        try await SidekickSync.sync(over: mac)
        XCTAssertEqual(SidekickSync.local(), SidekickValue(pattern: "-x", updated: 0), "both never edited: the Mac's")
        set("-mine", 300)
        mac.value = SidekickValue(pattern: "-theirs", updated: 300)
        try await SidekickSync.sync(over: mac)
        XCTAssertEqual(SidekickSync.local(), SidekickValue(pattern: "-theirs", updated: 300))
    }

    /// For a later push: an older value than ours never lands.
    func testAdoptIgnoresAnOlderValue() {
        set("-mine", 300)
        SidekickSync.adopt(SidekickValue(pattern: "-old", updated: 299))
        XCTAssertEqual(SidekickSync.local(), SidekickValue(pattern: "-mine", updated: 300))
    }

    /// An edit typed while a sync was out is newer than both; the reply doesn't take it.
    func testAnEditMidSyncIsKept() async throws {
        set("-a", 100)
        let mac = MacFake(SidekickValue(pattern: "-mac", updated: 200))
        mac.during = { SidekickSync.edit("-typed", now: Date(timeIntervalSince1970: 1)) }
        try await SidekickSync.sync(over: mac)
        XCTAssertEqual(SidekickSync.local().pattern, "-typed")
    }

    func testAnEditStampsNowOrPastTheStoredStamp() {
        SidekickSync.edit("-a", now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(SidekickSync.local(), SidekickValue(pattern: "-a", updated: 1_000_000))
        set("-a", 5_000_000)   // adopted from a Mac whose clock is ahead
        SidekickSync.edit("-b", now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(SidekickSync.local(), SidekickValue(pattern: "-b", updated: 5_000_001))
        SidekickSync.edit("-b", now: Date(timeIntervalSince1970: 9_000))
        XCTAssertEqual(SidekickSync.local().updated, 5_000_001, "no change, no stamp")
    }

    func testTheFieldIsCappedAt512Bytes() {
        XCTAssertEqual(SidekickSync.capped(String(repeating: "a", count: 512)).utf8.count, 512)
        XCTAssertEqual(SidekickSync.capped(String(repeating: "a", count: 600)), String(repeating: "a", count: 512))
        XCTAssertEqual(SidekickSync.capped(String(repeating: "é", count: 300)), String(repeating: "é", count: 256))
        XCTAssertEqual(SidekickSync.capped(String(repeating: "😀", count: 129)), String(repeating: "😀", count: 128),
                       "never half a character")
        SidekickSync.edit(String(repeating: "b", count: 513), now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(SidekickSync.local().pattern.utf8.count, 512)
    }

    /// An older Mac never answers 0x2d: without "sidekick" in ops nothing is sent.
    func testNoSyncWithoutTheVerb() async throws {
        XCTAssertEqual(SessionVerb.offered(["sidekick"]), [.sidekick])
        let mac = MacFake()
        SidekickSync.offer(SessionVerb.offered(["library", "clipboard", "snippets_put"]), over: mac)
        XCTAssertNil(SidekickSync.mac)
        SidekickSync.kick()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mac.sent, [])

        SidekickSync.offer(SessionVerb.offered(["library", "sidekick"]), over: mac)
        try await waitUntil("sent on connect") { !SidekickSync.running && mac.sent.count == 1 }
        SidekickSync.offer([], over: mac)
        SidekickSync.kick()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mac.sent.count, 1, "a Mac without it replaced the one with it")
    }

    /// #1769: a Mac listing "groups" gets a 0x2f read and never a 0x2d; its groups are stored. One
    /// without it gets 0x2d as before, and the stored groups go (the Sidekicks split shows).
    func testGroupsReadOnlyWithTheVerb() async throws {
        XCTAssertEqual(SessionVerb.offered(["sidekick", "groups"]), [.sidekick, .groups])
        let g = [SessionGroup(id: "sidekicks", name: "Sidekicks", pattern: "-qa"), SessionGroup(id: "g7", name: "Reviewers", pattern: "-rev")]
        let mac = MacFake()
        mac.groups = .success(g)
        SidekickSync.offer(SessionVerb.offered(["sidekick", "groups"]), over: mac)
        try await waitUntil("read on connect") { !SidekickSync.running && mac.groupReads == 1 }
        XCTAssertEqual(mac.sent, [], "no 0x2d")
        XCTAssertEqual(DchSession.groups(defaults.data(forKey: SidekickSync.groupsKey), sidekick: "-x"), g)

        // An error keeps the last groups.
        mac.groups = .failure(TransportError.server("groups unavailable"))
        do { try await SidekickSync.sync(over: mac); XCTFail("the error throws") } catch {
            XCTAssertEqual(error.localizedDescription, "groups unavailable")
        }
        XCTAssertEqual(DchSession.groups(defaults.data(forKey: SidekickSync.groupsKey), sidekick: "-x"), g)

        SidekickSync.offer([.sidekick], over: mac)
        try await waitUntil("0x2d on an older Mac") { !SidekickSync.running && mac.sent.count == 1 }
        XCTAssertEqual(mac.groupReads, 2)
        XCTAssertNil(defaults.data(forKey: SidekickSync.groupsKey), "the sidekick fallback")
    }

    /// Typing syncs once, after the last keystroke.
    func testEditsSyncOnceTypingPauses() async throws {
        SidekickSync.debounce = 0.2
        let mac = MacFake(SidekickValue(pattern: "-qa", updated: 0))
        SidekickSync.offer([.sidekick], over: mac)
        try await waitUntil("sent on connect") { !SidekickSync.running && mac.sent.count == 1 }
        for p in ["-r", "-re", "-rev"] { SidekickSync.edit(p) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mac.sent.count, 1, "not before the pause")
        try await waitUntil("sent after the pause") { !SidekickSync.running && mac.sent.count == 2 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(mac.sent.map(\.pattern), ["-qa", "-rev"])
        XCTAssertEqual(mac.value.pattern, "-rev")
    }

    // MARK: The wire

    /// A loopback Mac that records each frame and answers `reply`, or never answers when nil.
    private func loopbackMac(_ reply: Box<(UInt8, String)?>) async throws -> (ProsperTransport, Box<[(UInt8, Data)]>, NWListener) {
        let requests = Box<[(UInt8, Data)]>([])
        let listener = try loopbackServer { c in
            let buf = Box(Data())
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                    if let d { buf.v.append(d) }
                    if let frame = try? FrameCodec.pop(&buf.v) {
                        requests.v.append(frame)
                        if let r = reply.v { c.send(content: FrameCodec.encode(r.0, Data(r.1.utf8)), completion: .idempotent) }
                    }
                    if done || err != nil { c.cancel() } else { read() }
                }
            }
            read()
        }
        let end = Date().addingTimeInterval(3)
        while (listener.port?.rawValue ?? 0) == 0 {
            if Date() > end { throw XCTSkip("loopback listener never came up") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return (ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue), requests, listener)
    }

    func testTheWireIsFrame0x2dAndOkOrErrorIsRead() async throws {
        let reply = Box<(UInt8, String)?>((0x14, #"{"pattern":" -qa ","updated":1700000000123}"#))
        let (t, requests, l) = try await loopbackMac(reply)
        defer { l.cancel() }
        let won = try await t.sidekickSync(SidekickValue(pattern: " -rev ", updated: 42))
        XCTAssertEqual(won, SidekickValue(pattern: " -qa ", updated: 1700000000123))
        XCTAssertEqual(requests.v.first?.0, 0x2d)
        let sent = requests.v.first.flatMap { (try? JSONSerialization.jsonObject(with: $0.1)) as? NSDictionary }
        XCTAssertEqual(sent, ["pattern": " -rev ", "updated": 42], "raw, untrimmed")

        reply.v = (0x13, #"{"message":"sidekick pattern over 512 UTF-8 bytes"}"#)
        do { _ = try await t.sidekickSync(SidekickValue(pattern: "x", updated: 1)); XCTFail("the error frame throws") } catch {
            XCTAssertEqual(error.localizedDescription, "sidekick pattern over 512 UTF-8 bytes")
        }
        XCTAssertThrowsError(try ProsperTransport.decodeSidekick(Data(#"{"pattern":"x","updated":true}"#.utf8)))
        XCTAssertThrowsError(try ProsperTransport.decodeSidekick(Data(#"{"updated":1}"#.utf8)))
    }

    /// #1769: 0x2f with `{}`; the ok reply in order, malformed groups dropped, at most 8; error 0x13's message.
    func testTheGroupsWireIsFrame0x2f() async throws {
        let reply = Box<(UInt8, String)?>((0x14, #"{"groups":[{"id":"sidekicks","name":"Sidekicks","pattern":"-qa"},{"id":"g7f3a2c","name":"Reviewers","pattern":"-(rev|review)$","x":1}],"updated":1763654400000}"#))
        let (t, requests, l) = try await loopbackMac(reply)
        defer { l.cancel() }
        let groups = try await t.groupsSync()
        XCTAssertEqual(groups, [SessionGroup(id: "sidekicks", name: "Sidekicks", pattern: "-qa"),
                                SessionGroup(id: "g7f3a2c", name: "Reviewers", pattern: "-(rev|review)$")])
        XCTAssertEqual(requests.v.first?.0, 0x2f)
        XCTAssertEqual(requests.v.first.flatMap { (try? JSONSerialization.jsonObject(with: $0.1)) as? NSDictionary }, [:])

        reply.v = (0x13, #"{"message":"groups unavailable"}"#)
        do { _ = try await t.groupsSync(); XCTFail("the error frame throws") } catch {
            XCTAssertEqual(error.localizedDescription, "groups unavailable")
        }

        let bad = #"{"groups":[{"id":"a b","name":"x","pattern":""},{"id":"ok","name":"","pattern":""},{"id":"ok","name":"\#(String(repeating: "n", count: 33))","pattern":""},{"id":"ok","name":"x","pattern":"\#(String(repeating: "p", count: 513))"},{"id":"ok","name":"x"},7,{"id":"keep","name":"Keep","pattern":""}],"updated":0}"#
        XCTAssertEqual(try ProsperTransport.decodeGroups(Data(bad.utf8)), [SessionGroup(id: "keep", name: "Keep", pattern: "")])
        let nine = (0..<9).map { #"{"id":"g\#($0)","name":"G","pattern":"x"}"# }.joined(separator: ",")
        XCTAssertEqual(try ProsperTransport.decodeGroups(Data(#"{"groups":[\#(nine)]}"#.utf8)).count, 8)
        XCTAssertEqual(try ProsperTransport.decodeGroups(Data(#"{"groups":[],"updated":0}"#.utf8)), [])
        XCTAssertThrowsError(try ProsperTransport.decodeGroups(Data(#"{"updated":0}"#.utf8)))
    }

    /// A Mac that takes the frame and says nothing: the read gives up at the deadline and
    /// the phone keeps its own value.
    func testASilentMacTimesOutAndThePhoneKeepsItsValue() async throws {
        let (t, requests, l) = try await loopbackMac(Box(nil))
        defer { l.cancel() }
        XCTAssertEqual(t.sidekickDeadline, 5, "the shipped deadline")
        t.sidekickDeadline = 0.3
        set("-mine", 7)
        let start = Date()
        do { try await SidekickSync.sync(over: t); XCTFail("a silent Mac times out") } catch let e as TransportError {
            guard case .hostUnreachable = e else { return XCTFail("wrong case: \(e)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "the read ends at its deadline")
        XCTAssertEqual(requests.v.first?.0, 0x2d)
        XCTAssertEqual(SidekickSync.local(), SidekickValue(pattern: "-mine", updated: 7))
    }
}

/// The Mac's side of 0x2d, its merge as shipped: the newer wins, a tie keeps the Mac's.
private final class MacFake: SessionTransport {
    var value: SidekickValue
    var sent: [SidekickValue] = []
    var during: (@MainActor () -> Void)?
    var groups: Result<[SessionGroup], Error> = .success([])   // #1769
    var groupReads = 0
    init(_ value: SidekickValue = SidekickValue(pattern: "-qa", updated: 0)) { self.value = value }

    func sidekickSync(_ mine: SidekickValue) async throws -> SidekickValue {
        sent.append(mine)
        if let during { await during() }
        if mine.updated > value.updated { value = mine }
        return value
    }
    func groupsSync() async throws -> [SessionGroup] { groupReads += 1; return try groups.get() }
    func listSessions() async throws -> [DchSession] { [] }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
        throw TransportError.notConnected
    }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}
