import XCTest
@testable import Prosper

/// Shortcuts, the controls and the sessions widget (#611): each hands the app a link it
/// routes as `onOpenURL` does, and the widget reads only the snapshot the app wrote.
@MainActor
final class IntentsTests: XCTestCase {
    private let studio = Machine(name: "Studio", addresses: ["studio.ts.net"])
    private let laptop = Machine(name: "Laptop", addresses: ["laptop.ts.net"])
    private var dir: URL!
    private var suite: String!
    /// The intents' link, caught before the test host's Home takes it (and dials or listens).
    private var link: URL?

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("intents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "intents-tests-\(UUID().uuidString)"
        let (d, s) = (dir, suite!)
        ShareInbox.dir = { d }
        ShareInbox.defaults = { UserDefaults(suiteName: s) }
        SessionsSnapshot.dir = { d }
        ShareInbox.pending = nil
        link = nil
        IntentLink.open = { [unowned self] in link = $0 }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults().removePersistentDomain(forName: suite)
        ShareInbox.dir = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareInbox.group) }
        ShareInbox.defaults = { UserDefaults(suiteName: ShareInbox.group) }
        SessionsSnapshot.dir = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SessionsSnapshot.group) }
        SessionQuery.list = { try await connectFirstTransport($0.addresses).sessions }
        ShareInbox.pending = nil
        IntentLink.open = { IntentLink.shared.url = $0 }
        super.tearDown()
    }

    /// The session a route opens, nil for any other route.
    private func opened(_ route: Route?) -> (machine: UUID, session: String)? {
        guard case .sessions(.machine(let m), let open?, _)? = route else { return nil }
        return (m, open)
    }

    // MARK: - Session entity

    func testQueryListsEverySavedMacsLiveSessionsAndSkipsOneThatDoesNotAnswer() async throws {
        ShareInbox.save(machines: [studio, laptop])
        let (s, l) = (studio, laptop)
        SessionQuery.list = { m in
            if m.id == l.id { throw TransportError.hostUnreachable("asleep") }
            XCTAssertEqual(m.id, s.id)
            return [DchSession(name: "main", alias: nil, state: "idle"), DchSession(name: "web", alias: "API refactor")]
        }
        let found = try await SessionQuery().suggestedEntities()
        XCTAssertEqual(found.map(\.title), ["API refactor", "main"], "the session list's order, by title")
        XCTAssertEqual(found.map(\.mac), ["Studio", "Studio"])
        XCTAssertEqual(found.map(\.id), ["\(studio.id.uuidString)/web", "\(studio.id.uuidString)/main"])

        let back = try await SessionQuery().entities(for: found.map(\.id) + ["\(laptop.id.uuidString)/a/b", "junk"])
        XCTAssertEqual(back.map(\.name), ["web", "main", "a/b"], "from the ids alone; a name may hold a slash")
        XCTAssertEqual(back.map(\.machine), [studio.id, studio.id, laptop.id])
        XCTAssertEqual(back.map(\.mac), ["Studio", "Studio", "Laptop"])
    }

    func testOpenSessionLinksToThatSession() async throws {
        let intent = OpenSessionIntent()
        intent.target = SessionEntity(machine: studio.id, name: "main", title: "main", mac: "Studio")
        _ = try await intent.perform()
        let hit = opened(Route.opening(try XCTUnwrap(link)))
        XCTAssertEqual(hit?.machine, studio.id)
        XCTAssertEqual(hit?.session, "main")
    }

    // MARK: - Send Text

    func testSendTextIsPendingForItsSessionAsOnePasteWithNoReturn() async throws {
        let intent = SendTextIntent()
        intent.text = "git status\nls"
        intent.session = SessionEntity(machine: studio.id, name: "main", title: "main", mac: "Studio")
        _ = try await intent.perform()

        let hit = opened(Route.opening(try XCTUnwrap(link)))
        XCTAssertEqual(hit?.machine, studio.id)
        XCTAssertEqual(hit?.session, "main")
        let item = try XCTUnwrap(ShareInbox.pending, "pending for the terminal, as a share is")
        XCTAssertEqual(item.target, ShareTarget(machine: studio.id, session: "main"))
        XCTAssertNil(item.image)

        let (open, close) = (Array("\u{1b}[200~".utf8), Array("\u{1b}[201~".utf8))
        XCTAssertEqual(item.outbound, [.bytes(open + Array("git status\nls".utf8) + close)], "one bracketed paste")
        guard case .bytes(let b) = item.outbound.last else { return XCTFail("no bytes") }
        XCTAssertEqual(Array(b.suffix(close.count)), close, "nothing after the closer: no Return")
        XCTAssertNil(ShareInbox.take(for: "web"), "another session's terminal pastes nothing")
    }

    // MARK: - Controls

    func testDictateIsTheKeyboardMicsLink() async throws {
        _ = try await DictateIntent().perform()
        XCTAssertNotNil(Dictation.id(from: try XCTUnwrap(link)))
    }

    func testLastSessionOpensShareInboxLastAndNothingBeforeThere() async throws {
        _ = try await OpenLastSessionIntent().perform()
        let url = try XCTUnwrap(link)
        XCTAssertNil(Route.opening(url), "no session opened yet: home")
        ShareInbox.last = ShareTarget(machine: laptop.id, session: "web")
        let hit = opened(Route.opening(url))
        XCTAssertEqual(hit?.machine, laptop.id)
        XCTAssertEqual(hit?.session, "web")
    }

    // MARK: - Widget

    func testSnapshotRoundTripsAndOrdersNeedsInputFirst() throws {
        let s = SessionsSnapshot(machine: studio, sessions: [
            DchSession(name: "s10", alias: nil, state: "idle"),
            DchSession(name: "web", alias: "API refactor", state: "working"),
            DchSession(name: "s2", alias: nil, state: "idle"),
            DchSession(name: "old", alias: nil, state: "nonsense"),
            DchSession(name: "main", alias: nil, state: "blocked"),
            DchSession(name: "docs", alias: nil, state: "done"),
        ])
        SessionsSnapshot.save(s)
        let back = try XCTUnwrap(SessionsSnapshot.read())
        XCTAssertEqual(back.machine, studio.id)
        XCTAssertEqual(back.mac, "Studio")
        XCTAssertEqual(back.rows, s.rows)
        XCTAssertEqual(back.date.timeIntervalSince1970, s.date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(back.ordered.map(\.title), ["main", "API refactor", "s2", "s10", "docs", "old"],
                       "needs input, working, idle (s2 before s10), done, unknown")

        var later = s
        later.date = s.date.addingTimeInterval(30)
        SessionsSnapshot.save(later)
        XCTAssertEqual(SessionsSnapshot.read()?.date.timeIntervalSince1970 ?? 0, s.date.timeIntervalSince1970, accuracy: 0.001,
                       "the same list within the minute: not rewritten")
        later.rows.removeLast()
        SessionsSnapshot.save(later)
        XCTAssertEqual(SessionsSnapshot.read()?.rows.count, 5, "a changed list is")
    }

    func testWidgetRowLinkOpensThatSession() throws {
        let s = SessionsSnapshot(machine: studio, sessions: [DchSession(name: "a b&c", alias: "API refactor", state: "blocked")])
        let hit = opened(Route.opening(s.link(try XCTUnwrap(s.ordered.first))))
        XCTAssertEqual(hit?.machine, studio.id)
        XCTAssertEqual(hit?.session, "a b&c", "the dch name, escaped and back")
        XCTAssertNil(Route.opening(URL(string: "prosper://session?machine=nope&name=main")!))
        XCTAssertNil(Route.opening(URL(string: "prosper://sessions?mac=abc")!), "the Live Activity's link stays LiveTarget's")
    }
}
