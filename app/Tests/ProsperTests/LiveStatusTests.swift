import XCTest
@testable import Prosper

/// Live status by push (contract v1): the content-state the Worker pushes, the token
/// requests the phone sends it, the install id, and where a tapped alert lands.
final class LiveStatusTests: XCTestCase {

    private func decode(_ json: String) throws -> SessionsStatus {
        try JSONDecoder().decode(SessionsStatus.self, from: Data(json.utf8))
    }

    // MARK: content-state

    func testDecodesTheFullContractExample() throws {
        let s = try decode(#"{"v":1,"online":true,"counts":{"blocked":1,"working":2,"idle":3,"done":0},"sessions":[{"name":"a","alias":"Fix it","state":"blocked","agents":2}],"more":0}"#)
        XCTAssertEqual(s, SessionsStatus(v: 1, online: true,
                                         counts: .init(blocked: 1, working: 2, idle: 3, done: 0),
                                         sessions: [.init(name: "a", alias: "Fix it", state: .blocked, agents: 2)],
                                         more: 0))
        XCTAssertEqual(s.sessions[0].title, "Fix it")
    }

    /// No alias, no agents, missing counts: still a card, never a failed update.
    func testDecodesAMinimalState() throws {
        let s = try decode(#"{"v":1,"online":false,"counts":{},"sessions":[{"name":"b","state":"working"}],"more":4}"#)
        XCTAssertFalse(s.online)
        XCTAssertEqual(s.counts, .init())
        XCTAssertEqual(s.sessions, [.init(name: "b", alias: nil, state: .working, agents: nil)])
        XCTAssertEqual(s.sessions[0].title, "b")
        XCTAssertEqual(s.more, 4)
    }

    func testUnknownStateReadsAsIdle() throws {
        let s = try decode(#"{"v":1,"online":true,"counts":{"idle":1},"sessions":[{"name":"c","state":"compacting"}],"more":0}"#)
        XCTAssertEqual(s.sessions[0].state, .idle)
    }

    /// A newer Worker adds keys and bumps `v`; this build keeps reading what it knows.
    func testUnknownKeysAndANewerVersionDecode() throws {
        let s = try decode(#"{"v":2,"online":true,"extra":{"x":1},"counts":{"working":1,"paused":5},"sessions":[{"name":"d","state":"working","agents":1,"color":"red"}],"more":0,"since":123}"#)
        XCTAssertEqual(s.v, 2)
        XCTAssertEqual(s.counts.working, 1)
        XCTAssertEqual(s.sessions[0].agents, 1)
    }

    /// A wrong type reads as missing instead of failing the push: the card keeps updating.
    func testWrongTypesReadAsMissing() throws {
        let s = try decode(#"{"v":"1","online":"yes","counts":{"blocked":"2","working":1},"sessions":[{"name":"e","alias":7,"state":3,"agents":"2"}],"more":"2"}"#)
        XCTAssertEqual(s, SessionsStatus(counts: .init(working: 1),
                                         sessions: [.init(name: "e", alias: nil, state: .idle, agents: nil)]))
        XCTAssertEqual(try decode(#"{"counts":{"idle":1},"sessions":[{"state":"idle"}]}"#).sessions, [], "no name, no rows")
    }

    /// What ActivityKit encodes for a local activity decodes back to the same state.
    func testRoundTrips() throws {
        let s = SessionsStatus(counts: .init(blocked: 1), sessions: [.init(name: "a", alias: nil, state: .blocked, agents: nil)])
        XCTAssertEqual(try JSONDecoder().decode(SessionsStatus.self, from: JSONEncoder().encode(s)), s)
    }

    // MARK: card text

    private let busy = SessionsStatus(
        counts: .init(blocked: 1, working: 2, idle: 3, done: 0),
        sessions: (1...6).map { .init(name: "s\($0)", alias: nil, state: $0 == 1 ? .blocked : .working, agents: nil) },
        more: 4)

    func testLiveCardShowsCountsAndTopSessions() {
        let card = SessionsCard(status: busy, isStale: false)
        XCTAssertEqual(card.headline, "1 needs input · 2 working · 3 idle")
        XCTAssertEqual(card.lead, .blocked)
        XCTAssertEqual(card.compactText, "1")
        let top = card.rows(limit: 3)
        XCTAssertEqual(top.sessions.map(\.name), ["s1", "s2", "s3"])
        XCTAssertEqual(top.more, 7, "3 pushed but not shown + 4 the Worker left out")
        XCTAssertEqual(SessionsCard.detail(.init(name: "x", alias: nil, state: .working, agents: 2)), "Working · +2 agents")
        XCTAssertEqual(card.compactLabel, "1 session needs input")
        XCTAssertEqual(SessionsStatus.Session(name: "x", alias: "", state: .idle).title, "x", "an empty alias is no alias")
    }

    /// With nothing blocked, the island leads with working, then idle.
    func testLeadFallsToWorkingThenIdle() {
        let working = SessionsCard(status: SessionsStatus(counts: .init(working: 2, idle: 3)), isStale: false)
        XCTAssertEqual(working.lead, .working)
        XCTAssertEqual(working.compactText, "2")
        XCTAssertEqual(working.compactLabel, "2 sessions working")
        let idle = SessionsCard(status: SessionsStatus(counts: .init(idle: 3, done: 1)), isStale: false)
        XCTAssertEqual(idle.lead, .idle)
        XCTAssertEqual(idle.compactText, "3")
        XCTAssertEqual(SessionsCard(status: SessionsStatus(counts: .init(blocked: 3)), isStale: false).compactLabel,
                       "3 sessions need input")
    }

    func testNegativeMoreCountsAsNone() {
        let s = SessionsStatus(sessions: [.init(name: "a", alias: nil, state: .idle)], more: -3)
        XCTAssertEqual(SessionsCard(status: s, isStale: false).rows(limit: 3).more, 0)
    }

    /// Past the stale date: no session state at all, only "status unavailable".
    func testStaleCardShowsNoStates() {
        let card = SessionsCard(status: busy, isStale: true)
        XCTAssertEqual(card.headline, "status unavailable")
        XCTAssertNil(card.lead)
        XCTAssertTrue(card.rows(limit: 3).sessions.isEmpty)
        XCTAssertEqual(card.rows(limit: 3).more, 0)
        XCTAssertEqual(card.compactText, "–")
        XCTAssertEqual(card.compactLabel, "status unavailable")
        XCTAssertEqual(card.symbol, "questionmark.circle")
    }

    func testOfflineCardSaysSoAndShowsNoStates() {
        var s = busy
        s.online = false
        let card = SessionsCard(status: s, isStale: false)
        XCTAssertEqual(card.headline, "Mac offline")
        XCTAssertEqual(card.compactText, "offline")
        XCTAssertTrue(card.rows(limit: 3).sessions.isEmpty)
    }

    /// The Worker's last push before it ends the card: offline, nothing listed, all zero.
    func testFinalOfflinePayload() throws {
        let s = try decode(#"{"v":1,"online":false,"counts":{"blocked":0,"working":0,"idle":0,"done":0},"sessions":[],"more":0}"#)
        XCTAssertEqual(s, SessionsStatus(online: false))
        let card = SessionsCard(status: s, isStale: false)
        XCTAssertEqual(card.headline, "Mac offline")
        XCTAssertEqual(card.compactText, "offline")
        XCTAssertNil(card.lead)
        XCTAssertTrue(card.rows(limit: 3).sessions.isEmpty)
        XCTAssertEqual(card.rows(limit: 3).more, 0)
    }

    func testEmptyCard() {
        XCTAssertEqual(SessionsCard(status: SessionsStatus(), isStale: false).headline, "no sessions")
    }

    // MARK: token requests

    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        var codes: [Int] = []
        func send(_ r: URLRequest) async throws -> Int {
            requests.append(r)
            return codes.isEmpty ? 204 : codes.removeFirst()
        }
        func body(_ i: Int = 0) -> [String: String] {
            (try? JSONSerialization.jsonObject(with: requests[i].httpBody ?? Data())) as? [String: String] ?? [:]
        }
    }

    private let tok = String(repeating: "0a", count: 16)

    private func client(_ rec: Recorder, env: String = "sandbox") -> PushTokens {
        var c = PushTokens(base: URL(string: "https://worker.test")!, session: "bearer-1", deviceId: "dev-12345678", env: env)
        c.send = rec.send
        c.retryDelays = [0, 0, 0]
        return c
    }

    func testAlertTokenBody() async {
        let rec = Recorder()
        let ok = await client(rec).post(.alert, token: tok)
        XCTAssertTrue(ok)
        let r = rec.requests[0]
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://worker.test/push/tokens")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-1")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(rec.body(), ["device_id": "dev-12345678", "kind": "alert", "token": tok, "env": "sandbox"])
    }

    func testPushToStartTokenBody() async {
        let rec = Recorder()
        await client(rec, env: "production").post(.laStart, token: tok)
        XCTAssertEqual(rec.body(), ["device_id": "dev-12345678", "kind": "la_start", "token": tok, "env": "production"])
    }

    func testActivityUpdateTokenBody() async {
        let rec = Recorder()
        await client(rec).post(.laUpdate, token: tok, activityId: "act-1", macId: "mac-hex")
        XCTAssertEqual(rec.body(), ["device_id": "dev-12345678", "kind": "la_update", "token": tok, "env": "sandbox",
                                    "activity_id": "act-1", "mac_id": "mac-hex"])
    }

    /// The Worker refuses activity_id or mac_id on alert and la_start: the keys are left
    /// out entirely, even when a caller passes them.
    func testAlertAndPushToStartCarryNoActivityKeys() async {
        let rec = Recorder()
        let c = client(rec)
        await c.post(.alert, token: tok, activityId: "act-1", macId: "mac-hex")
        await c.post(.laStart, token: tok, activityId: "act-1", macId: "mac-hex")
        for i in 0..<2 {
            XCTAssertNil(rec.body(i)["activity_id"])
            XCTAssertNil(rec.body(i)["mac_id"])
        }
    }

    /// What the Worker would answer 400 to never leaves the phone.
    func testInvalidValuesAreNotSent() async {
        let rec = Recorder()
        let c = client(rec)
        let refused = [
            await c.post(.alert, token: "abcd"),                       // too short
            await c.post(.alert, token: String(repeating: "AB", count: 16)),  // uppercase
            await c.post(.alert, token: String(repeating: "a", count: 513)),
            await c.post(.laUpdate, token: tok, activityId: "act-1"),  // no mac_id
            await c.post(.laUpdate, token: tok, macId: "m"),            // no activity_id
            await c.post(.laUpdate, token: tok, activityId: "act-1", macId: ""),
            await c.post(.laUpdate, token: tok, activityId: "has space", macId: "m"),
            await c.delete(.laUpdate, activityId: ""),
        ]
        XCTAssertEqual(refused, Array(repeating: false, count: refused.count))
        XCTAssertTrue(rec.requests.isEmpty)
        XCTAssertTrue(PushTokens.isValidActivityId(UUID().uuidString))
        XCTAssertTrue(PushTokens.isValidActivityId("a.b_c:d-1"))
        XCTAssertFalse(PushTokens.isValidActivityId(String(repeating: "a", count: 129)))
    }

    /// The Worker already dropped the row: fine, nothing to retry.
    func testDeleteOf404IsNotRetried() async {
        let rec = Recorder()
        rec.codes = [404]
        await client(rec).delete(.laUpdate, activityId: "act-1")
        XCTAssertEqual(rec.requests.count, 1)
    }

    func testDeleteBodies() async {
        let rec = Recorder()
        let c = client(rec)
        await c.delete()
        await c.delete(.laUpdate, activityId: "act-1")
        XCTAssertEqual(rec.requests.map(\.httpMethod), ["DELETE", "DELETE"])
        XCTAssertEqual(rec.body(0), ["device_id": "dev-12345678"], "no kind: every token of this device")
        XCTAssertEqual(rec.body(1), ["device_id": "dev-12345678", "kind": "la_update", "activity_id": "act-1"])
    }

    /// Sign-out waits on the DELETE, so a dead connection must give up in seconds.
    func testRequestsTimeOutQuickly() async {
        let rec = Recorder()
        let c = client(rec)
        await c.post(.alert, token: tok)
        await c.delete()
        XCTAssertEqual(rec.requests.map(\.timeoutInterval), [10, 10])
        XCTAssertEqual(rec.requests.map(\.httpMethod), ["POST", "DELETE"])
        XCTAssertEqual(rec.requests.map { $0.url?.path }, ["/push/tokens", "/push/tokens"])
    }

    /// A rotated-away card is stale; alert and la_start never are.
    func testStaleActivities() {
        var cache = PushTokenCache()
        cache.remember(.init(kind: .alert, token: tok))
        cache.remember(.init(kind: .laStart, token: tok))
        cache.remember(.init(kind: .laUpdate, token: tok, activityId: "act-1", macId: "mac-a"))
        cache.remember(.init(kind: .laUpdate, token: tok, activityId: "act-2", macId: "mac-a"))
        XCTAssertEqual(cache.stale(live: ["act-2"]), ["act-1"])
        XCTAssertEqual(cache.stale(live: ["act-1", "act-2"]), [])
        XCTAssertEqual(Set(cache.stale(live: [])), ["act-1", "act-2"])
    }

    /// What a foreground re-posts: the last token per key, each once, with its own body;
    /// nothing once cleared (turnOff and sign-out), and not an ended activity's.
    func testForegroundRepostSet() async {
        var cache = PushTokenCache()
        let older = String(repeating: "11", count: 16)
        cache.remember(.init(kind: .alert, token: older))
        cache.remember(.init(kind: .alert, token: tok))              // rotation replaces
        cache.remember(.init(kind: .laStart, token: tok))
        cache.remember(.init(kind: .laUpdate, token: tok, activityId: "act-1", macId: "mac-a"))
        cache.remember(.init(kind: .laUpdate, token: tok, activityId: "act-2", macId: "mac-b"))
        cache.forget(activityId: "act-2")                            // ended

        let rec = Recorder()
        await cache.repost(client(rec))
        let bodies = rec.requests.indices.map { rec.body($0) }.sorted { ($0["kind"] ?? "") < ($1["kind"] ?? "") }
        XCTAssertEqual(rec.requests.map(\.httpMethod), ["POST", "POST", "POST"])
        XCTAssertEqual(bodies, [
            ["device_id": "dev-12345678", "kind": "alert", "token": tok, "env": "sandbox"],
            ["device_id": "dev-12345678", "kind": "la_start", "token": tok, "env": "sandbox"],
            ["device_id": "dev-12345678", "kind": "la_update", "token": tok, "env": "sandbox",
             "activity_id": "act-1", "mac_id": "mac-a"],
        ])

        cache.clear()
        let after = Recorder()
        await cache.repost(client(after))
        XCTAssertTrue(after.requests.isEmpty)
    }

    /// A 5xx is retried, a 4xx is an answer.
    func testRetriesServerErrorsOnly() async {
        let rec = Recorder()
        rec.codes = [503, 204]
        let retried = await client(rec).post(.alert, token: tok)
        XCTAssertTrue(retried)
        XCTAssertEqual(rec.requests.count, 2)

        let rec2 = Recorder()
        rec2.codes = [403]
        let refused = await client(rec2).post(.laUpdate, token: tok, activityId: "x", macId: "m")
        XCTAssertFalse(refused)
        XCTAssertEqual(rec2.requests.count, 1)
    }

    // MARK: the switch and the tokens

    /// A send that can hold one request until released, to have a repost in flight.
    private final class Gate: @unchecked Sendable {
        var requests: [URLRequest] = []
        var holdNext = false
        private var held: CheckedContinuation<Void, Never>?
        var holding: Bool { held != nil }
        func send(_ r: URLRequest) async throws -> Int {
            requests.append(r)
            if holdNext {
                holdNext = false
                await withCheckedContinuation { held = $0 }
            }
            return 204
        }
        func release() { held?.resume(); held = nil }
        func waitHeld() async {
            for _ in 0..<500 where !holding { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        var methods: [String?] { requests.map(\.httpMethod) }
    }

    @MainActor
    private func liveStatus(_ gate: Gate, on: Bool = true, notifications: Bool = true) -> LiveStatus {
        let d = UserDefaults(suiteName: "LiveStatusTests-\(UUID())")!
        d.set(on, forKey: LiveStatus.enabledKey)
        return LiveStatus(defaults: d, client: {
            var c = PushTokens(base: URL(string: "https://worker.test")!, session: "b", deviceId: "dev-12345678", env: "sandbox")
            c.send = gate.send
            c.retryDelays = [0]
            return c
        }, notificationsAllowed: { notifications })
    }

    @MainActor
    func testNoPostAndNothingCachedWithTheSwitchOff() async {
        let gate = Gate()
        let ls = liveStatus(gate, on: false)
        await ls.post(.alert, token: tok)
        XCTAssertTrue(gate.requests.isEmpty)
        XCTAssertTrue(ls.cache.entries.isEmpty)
    }

    /// The switch goes off mid-repost: its DELETE is the last request, no POST after it.
    @MainActor
    func testRepostStopsWhenTheSwitchGoesOff() async {
        let gate = Gate()
        let ls = liveStatus(gate)
        await ls.post(.alert, token: tok)
        await ls.post(.laStart, token: tok)
        gate.holdNext = true
        let fg = Task { await ls.foreground() }
        await gate.waitHeld()
        await ls.turnOff()
        gate.release()
        await fg.value
        XCTAssertEqual(gate.methods, ["POST", "POST", "POST", "DELETE"])
    }

    /// A foreground while a repost is in flight adds nothing.
    @MainActor
    func testOneRepostAtATime() async {
        let gate = Gate()
        let ls = liveStatus(gate)
        await ls.post(.alert, token: tok)
        await ls.post(.laStart, token: tok)
        gate.holdNext = true
        let fg = Task { await ls.foreground() }
        await gate.waitHeld()
        await ls.foreground()
        gate.release()
        await fg.value
        XCTAssertEqual(gate.methods, ["POST", "POST", "POST", "POST"])
    }

    /// An ended card's token is taken back and never reposted.
    @MainActor
    func testEndedActivityIsNotReposted() async {
        let gate = Gate()
        let ls = liveStatus(gate)
        await ls.post(.laUpdate, token: tok, activityId: "act-1", macId: "mac-a")
        await ls.ended("act-1")
        await ls.foreground()
        XCTAssertEqual(gate.methods, ["POST", "DELETE"])
    }

    /// Notifications turned off in the Settings app: the switch follows and the Worker
    /// forgets this device.
    @MainActor
    func testNotificationsOffInSettingsTurnsTheSwitchOff() async {
        let gate = Gate()
        let ls = liveStatus(gate, notifications: false)
        await ls.post(.alert, token: tok)
        await ls.foreground()
        XCTAssertFalse(ls.enabled)
        XCTAssertEqual(gate.methods, ["POST", "DELETE"])
    }

    func testEnvChoice() {
        XCTAssertEqual(PushEnv.name(debug: true), "sandbox")
        XCTAssertEqual(PushEnv.name(debug: false), "production")
        XCTAssertEqual(PushEnv.current, "sandbox", "tests run a Debug build")
    }

    func testTokenHex() {
        XCTAssertEqual(Data([0x00, 0x0f, 0xab]).hex, "000fab")
    }

    // MARK: install id

    func testInstallIdFormatStabilityAndScope() {
        var store: [String: String] = [:]
        let get = { (email: String) in
            InstallID.get(email: email, load: { store[$0] }, save: { store[$1] = $0 })
        }
        let a = get("me@example.com")
        XCTAssertTrue(InstallID.isValid(a))
        XCTAssertEqual(get(" ME@example.com"), a, "same account, same id")
        XCTAssertNotEqual(get("other@example.com"), a, "another account gets its own")
        XCTAssertEqual(store.count, 2)

        store[InstallID.key(email: "me@example.com")] = "bad id!"
        XCTAssertNotEqual(get("me@example.com"), "bad id!", "a corrupt id is replaced")
    }

    func testInstallIdValidation() {
        XCTAssertTrue(InstallID.isValid(UUID().uuidString))
        XCTAssertTrue(InstallID.isValid("abcd-123"))
        XCTAssertFalse(InstallID.isValid("short"))
        XCTAssertFalse(InstallID.isValid(String(repeating: "a", count: 65)))
        XCTAssertFalse(InstallID.isValid("has space1"))
        XCTAssertFalse(InstallID.isValid("ümlaut-123"))
    }

    // MARK: tap routing

    private let machines = [
        Machine(name: "Studio", addresses: ["studio"], serverDeviceId: "aa11"),
        Machine(name: "Laptop", addresses: ["laptop"], serverDeviceId: "bb22"),
    ]

    func testAlertMatchesSavedMachine() {
        let t = LiveTarget(userInfo: ["mac_id": "bb22", "session": "fix", "aps": ["alert": "x"]])
        XCTAssertEqual(t.machine(in: machines)?.name, "Laptop")
        XCTAssertEqual(t.session, "fix")
    }

    func testAlertForUnknownMacGoesHome() {
        XCTAssertNil(LiveTarget(userInfo: ["mac_id": "cc33", "session": "fix"]).machine(in: machines))
    }

    func testGarbageUserInfoGoesHome() {
        for info: [AnyHashable: Any] in [[:], ["mac_id": 5], ["mac_id": ""], ["session": "fix"], ["mac_id": ["aa11"]]] {
            let t = LiveTarget(userInfo: info)
            XCTAssertNil(t.machine(in: machines), "\(info)")
            XCTAssertNil(t.session, "no session without a Mac")
        }
    }

    /// Several sessions blocked at once arrive as one alert: it opens the Mac's list.
    func testAggregateAlertTargetsTheMacsList() {
        let t = LiveTarget(userInfo: ["mac_id": "aa11", "session": "fix", "more": 2])
        XCTAssertEqual(t.machine(in: machines)?.name, "Studio")
        XCTAssertNil(t.session)
    }

    /// `more: 0`, or a `more` that isn't a positive integer, is a single alert as before.
    func testSingleAlertKeepsItsSession() {
        for more: Any? in [0, nil, "2", -1, 1.5] {
            var info: [AnyHashable: Any] = ["mac_id": "aa11", "session": "fix"]
            info["more"] = more
            XCTAssertEqual(LiveTarget(userInfo: info).session, "fix", "\(String(describing: more))")
        }
    }

    /// In front, inside the named session: its single alert is quiet, an aggregate still
    /// banners, and anything else banners.
    func testForegroundBannerDecision() {
        let onScreen = LiveTarget(macId: "aa11", session: "fix")
        XCTAssertFalse(LiveTarget(userInfo: ["mac_id": "aa11", "session": "fix", "more": 0]).banners(over: onScreen))
        XCTAssertTrue(LiveTarget(userInfo: ["mac_id": "aa11", "session": "fix", "more": 3]).banners(over: onScreen))
        XCTAssertTrue(LiveTarget(userInfo: ["mac_id": "aa11", "session": "other", "more": 0]).banners(over: onScreen))
        XCTAssertTrue(LiveTarget(userInfo: ["mac_id": "bb22", "session": "fix"]).banners(over: onScreen))
        XCTAssertTrue(LiveTarget(userInfo: ["mac_id": "aa11", "session": "fix"]).banners(over: nil))
    }

    /// Each tap is its own route, so a second alert for the session an earlier one opened
    /// still navigates after the user moved to another by hand; the screen is replaced,
    /// never stacked.
    func testEveryTapIsANewRoute() {
        let t = LiveTarget(userInfo: ["mac_id": "aa11", "session": "fix"])
        guard case .sessions(.machine(let id), "fix", let tap1?)? = t.route(in: machines),
              case .sessions(.machine(id), "fix", let tap2?)? = t.route(in: machines) else {
            return XCTFail("a route to that Mac's session")
        }
        XCTAssertEqual(id, machines[0].id)
        XCTAssertNotEqual(tap1, tap2)
        XCTAssertNil(LiveTarget(userInfo: ["mac_id": "cc33", "session": "fix"]).route(in: machines), "home")
        XCTAssertFalse(t.banners(over: LiveTarget(macId: "aa11", session: "fix")), "already on screen: stays put")
    }

    func testCardURLRoundTrips() {
        let url = LiveTarget.url(macId: "aa11")
        XCTAssertEqual(url.absoluteString, "prosper://sessions?mac=aa11")
        XCTAssertEqual(LiveTarget(url: url), LiveTarget(macId: "aa11"))
        XCTAssertEqual(LiveTarget(url: URL(string: "prosper://sessions")!), LiveTarget(macId: nil))
        XCTAssertNil(LiveTarget(url: URL(string: "prosper://help")!))
        XCTAssertNil(LiveTarget(url: URL(string: "https://sessions")!))
    }
}
