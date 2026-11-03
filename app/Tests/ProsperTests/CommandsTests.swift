import XCTest
import Network
@testable import Prosper

/// #615: the Mac's palette commands: the requests on the wire, the list and result decoded,
/// each refusal's copy, the confirm before the three that act at once, the argument's byte cap,
/// one run at a time, and the menu gate. A loopback Mac on an ephemeral port.
@MainActor
final class CommandsTests: XCTestCase {
    /// The fake Mac. Each connection's first frame is kept in `requests` and answered: commands
    /// 0x28 with `list`, anything else with `reply`, after `delay`.
    private final class FakeMac: @unchecked Sendable {   // main queue only
        let requests = Box<[(UInt8, Data)]>([])
        var list: (UInt8, String) = (0x2a, CommandsTests.listJSON)
        var reply: (UInt8, String) = (0x2b, #"{"text":"4"}"#)
        var delay: TimeInterval = 0
        var transport: ProsperTransport!
        var listener: NWListener!
        var runs: [Data] { requests.v.filter { $0.0 == 0x29 }.map(\.1) }
        var lists: Int { requests.v.filter { $0.0 == 0x28 }.count }
    }

    static let listJSON = #"""
    [{"id":"calc.eval","title":"Calculate","subtitle":"Evaluate an expression","ext":"Calculator","argument":"2+2","icon":"function"},
     {"id":"openlid.toggle","title":"Toggle Lid Awake","ext":"OpenLid","icon":"laptopcomputer"},
     {"id":"openlid.status","title":"Lid Status","ext":"OpenLid"},
     {"id":"toggles.lock","title":"Lock Screen","ext":"System","icon":"lock"},
     {"id":"toggles.displayoff","title":"Display Off","ext":"System","icon":"display"},
     {"id":"toggles.screensaver","title":"Screen Saver","ext":"System","icon":"no.such.symbol"}]
    """#

    private var macs: [FakeMac] = []

    override func tearDown() {
        macs.forEach { $0.listener.cancel() }
        super.tearDown()
    }

    private func fakeMac() async throws -> FakeMac {
        let mac = FakeMac()
        let listener = try loopbackServer { c in
            let buf = Box(Data())
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                    if let d { buf.v.append(d) }
                    if let frame = try? FrameCodec.pop(&buf.v) {
                        mac.requests.v.append(frame)
                        let (t, s) = frame.0 == 0x28 ? mac.list : mac.reply
                        DispatchQueue.main.asyncAfter(deadline: .now() + (frame.0 == 0x28 ? 0 : mac.delay)) {
                            c.send(content: FrameCodec.encode(t, Data(s.utf8)), completion: .idempotent)
                        }
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
        mac.listener = listener
        mac.transport = ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue)
        macs.append(mac)
        return mac
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func loaded(_ mac: FakeMac) async -> CommandsSession {
        let s = CommandsSession(transport: mac.transport)
        await s.load()
        return s
    }

    private func command(_ s: CommandsSession, _ id: String) -> MacCommand { s.commands!.first { $0.id == id }! }
    private func error(_ message: String) -> (UInt8, String) { (0x13, #"{"message":"\#(message)"}"#) }
    private func json(_ d: Data) -> NSDictionary { (try! JSONSerialization.jsonObject(with: d)) as! NSDictionary }

    // MARK: The wire

    func testTheListRequestIsEmpty() async throws {
        let mac = try await fakeMac()
        let s = await loaded(mac)
        XCTAssertEqual(mac.requests.v.first?.0, 0x28)
        XCTAssertEqual(mac.requests.v.first?.1, Data(), "an empty request")
        XCTAssertEqual(s.commands?.map(\.id), ["calc.eval", "openlid.toggle", "openlid.status", "toggles.lock",
                                               "toggles.displayoff", "toggles.screensaver"], "the Mac's order")
        XCTAssertNil(s.listError)
    }

    func testATapToRunCommandOmitsTheArgumentKey() async throws {
        let mac = try await fakeMac()
        mac.reply = (0x2b, #"{"text":"Screen saver started"}"#)
        let s = await loaded(mac)
        let saver = command(s, "toggles.screensaver")
        s.drafts[saver.id] = "stray"   // never sent for one that takes no text
        XCTAssertTrue(s.run(saver))
        try await waitUntil("the reply") { s.running == nil }
        XCTAssertEqual(mac.runs.count, 1)
        XCTAssertEqual(String(data: mac.runs[0], encoding: .utf8), #"{"id":"toggles.screensaver"}"#, "no argument, not even null")
        XCTAssertEqual(s.outcome, .init(id: saver.id, result: CommandResult(text: "Screen saver started")))

        XCTAssertEqual(json(ProsperTransport.runRequest(id: "a", argument: nil)), ["id": "a"])
        XCTAssertEqual(json(ProsperTransport.runRequest(id: "a", argument: "")), ["id": "a"], "empty is omitted too")
    }

    func testAnArgumentGoesTrimmed() async throws {
        let mac = try await fakeMac()
        mac.reply = (0x2b, #"{"text":"1000 m","detail":"km → m"}"#)
        let s = await loaded(mac)
        let calc = command(s, "calc.eval")
        XCTAssertFalse(s.run(calc), "no text, nothing sent")
        s.drafts[calc.id] = "  1 km to m \n"
        XCTAssertTrue(s.run(calc))
        try await waitUntil("the reply") { s.running == nil }
        XCTAssertEqual(mac.runs.map(json), [["id": "calc.eval", "argument": "1 km to m"]])
        XCTAssertEqual(s.outcome?.result, CommandResult(text: "1000 m", detail: "km → m"))
    }

    func testOneRunAtATime() async throws {
        let mac = try await fakeMac()
        mac.delay = 0.4
        let s = await loaded(mac)
        XCTAssertTrue(s.run(command(s, "openlid.status")))
        XCTAssertEqual(s.running, "openlid.status")
        XCTAssertFalse(s.run(command(s, "toggles.screensaver")), "waits for the reply")
        try await waitUntil("the reply") { s.running == nil }
        XCTAssertTrue(s.run(command(s, "toggles.screensaver")))
        try await waitUntil("the second reply") { s.running == nil }
        XCTAssertEqual(mac.runs.map(json), [["id": "openlid.status"], ["id": "toggles.screensaver"]])
    }

    // MARK: Decoding

    func testDecoding() throws {
        let rows = try ProsperTransport.decodeCommands(Data(#"""
        [{"id":"a","title":"A","ext":"X"},
         {"id":"b","title":"B","subtitle":"Bee","ext":"Y","argument":"hint","icon":"star"},
         {"title":"no id","ext":"X"}, {"id":"c","ext":"X"}, {"id":"d","title":"no ext"},
         {"id":7,"title":"T","ext":"X"}, 5, "junk", null,
         {"id":"e","title":"E","ext":"X","subtitle":null,"icon":3,"extra":true}]
        """#.utf8))
        XCTAssertEqual(rows, [MacCommand(id: "a", title: "A", ext: "X"),
                              MacCommand(id: "b", title: "B", subtitle: "Bee", ext: "Y", argument: "hint", icon: "star"),
                              MacCommand(id: "e", title: "E", ext: "X")])
        XCTAssertEqual(try ProsperTransport.decodeCommands(Data("[]".utf8)), [], "right at the Mac's launch")
        XCTAssertThrowsError(try ProsperTransport.decodeCommands(Data("{}".utf8)))

        XCTAssertEqual(try ProsperTransport.decodeResult(Data(#"{"text":"4"}"#.utf8)), CommandResult(text: "4"))
        XCTAssertEqual(try ProsperTransport.decodeResult(Data(#"{"text":"1000 m","detail":"km → m","x":1}"#.utf8)),
                       CommandResult(text: "1000 m", detail: "km → m"))
        XCTAssertThrowsError(try ProsperTransport.decodeResult(Data(#"{"detail":"no text"}"#.utf8)))

        XCTAssertEqual(CommandsSession.groups(rows + [MacCommand(id: "f", title: "F", ext: "Y")]).map { "\($0.ext):\($0.commands.map(\.id))" },
                       [#"X:["a", "e"]"#, #"Y:["b", "f"]"#], "by ext, where each first shows")
        XCTAssertEqual(CommandsSession.symbol("lock"), "lock")
        XCTAssertEqual(CommandsSession.symbol("no.such.symbol"), "command", "unknown falls back")
        XCTAssertEqual(CommandsSession.symbol(nil), "command", "missing falls back")
    }

    func testAnEmptyList() async throws {
        let mac = try await fakeMac()
        mac.list = (0x2a, "[]")
        let s = await loaded(mac)
        XCTAssertEqual(s.commands, [])
        mac.list = (0x2a, Self.listJSON)
        await s.load()
        XCTAssertEqual(s.commands?.count, 6, "a refresh picks the list up")
    }

    // MARK: Errors

    func testErrorCopy() {
        XCTAssertEqual(CommandsSession.copy("no result"), "No result for that input.")
        XCTAssertEqual(CommandsSession.copy("not allowed"), "That command isn't available on the Mac now. The list is refreshed.")
        XCTAssertEqual(CommandsSession.copy("commands are off"),
                       "Commands are off on the Mac. Turn on Settings › Remote Terminal › Run commands from iPhone in Prosper on the Mac.")
        for m in ["malformed", "argument too long", "unsupported result", "busy with an earlier request"] {
            XCTAssertEqual(CommandsSession.copy(m), m, "as written")
        }
    }

    func testNoResultShowsInline() async throws {
        let mac = try await fakeMac()
        mac.reply = error("no result")
        let s = await loaded(mac)
        let calc = command(s, "calc.eval")
        s.drafts[calc.id] = "hello"
        s.run(calc)
        try await waitUntil("the refusal") { s.running == nil }
        XCTAssertEqual(s.outcome, .init(id: calc.id, error: "No result for that input."))
        XCTAssertEqual(mac.lists, 1, "no refresh")
    }

    func testNotAllowedRefreshesTheList() async throws {
        let mac = try await fakeMac()
        mac.reply = error("not allowed")
        let s = await loaded(mac)
        mac.list = (0x2a, #"[{"id":"calc.eval","title":"Calculate","ext":"Calculator","argument":"2+2"}]"#)
        s.run(command(s, "openlid.status"))
        try await waitUntil("the refreshed list") { s.commands?.count == 1 }
        XCTAssertEqual(mac.lists, 2)
        XCTAssertEqual(s.outcome?.error, "That command isn't available on the Mac now. The list is refreshed.")
    }

    func testCommandsOffSaysWhereToTurnThemOn() async throws {
        let mac = try await fakeMac()
        mac.list = error("commands are off")
        let s = await loaded(mac)
        XCTAssertNil(s.commands)
        XCTAssertEqual(s.listError, CommandsSession.copy("commands are off"))

        mac.list = (0x2a, Self.listJSON)
        await s.load()
        XCTAssertNil(s.listError, "a good read clears it")
        mac.reply = error("commands are off")
        s.run(command(s, "openlid.status"))
        try await waitUntil("the refusal") { s.running == nil }
        XCTAssertEqual(s.outcome?.error, CommandsSession.copy("commands are off"))
    }

    func testOtherErrorsAsWritten() async throws {
        let mac = try await fakeMac()
        mac.reply = error("busy with an earlier request")
        let s = await loaded(mac)
        s.run(command(s, "openlid.status"))
        try await waitUntil("the refusal") { s.running == nil }
        XCTAssertEqual(s.outcome?.error, "busy with an earlier request")
    }

    // MARK: The confirm and the cap

    func testTheThreeThatActAtOnceAskFirst() async throws {
        let mac = try await fakeMac()
        mac.reply = (0x2b, #"{"text":"Mac awake — lid closed"}"#)
        let s = await loaded(mac)
        for id in ["toggles.lock", "toggles.displayoff", "openlid.toggle"] {
            let c = command(s, id)
            XCTAssertFalse(s.run(c), id)
            XCTAssertEqual(s.confirming, c, "\(id) asks")
            s.confirming = nil   // Cancel
        }
        for id in ["fans.auto", "fans.manual", "com.example.ext/run"] {
            XCTAssertTrue(CommandsSession.asks(id), id)
        }
        XCTAssertFalse(CommandsSession.asks("calc.eval"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(mac.runs.count, 0, "nothing reached the Mac unconfirmed")

        let lid = command(s, "openlid.toggle")
        s.run(lid)
        XCTAssertTrue(s.run(lid, confirmed: true))
        XCTAssertNil(s.confirming)
        try await waitUntil("the reply") { s.running == nil }
        XCTAssertEqual(mac.runs.map(json), [["id": "openlid.toggle"]])
        XCTAssertEqual(s.outcome?.result, CommandResult(text: "Requested: Mac awake — lid closed",
                                                        detail: "If the Mac asks to approve it, answer there."), "requested, not done")

        XCTAssertTrue(s.run(command(s, "toggles.screensaver")), "the rest run on a tap")
        XCTAssertNil(s.confirming)
    }

    func testTheArgumentCapIsCheckedOnThePhone() async throws {
        let mac = try await fakeMac()
        let s = await loaded(mac)
        let calc = command(s, "calc.eval")
        s.drafts[calc.id] = String(repeating: "a", count: 1023) + "é"   // 1025 bytes
        XCTAssertTrue(s.tooLong(calc))
        XCTAssertFalse(s.run(calc))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mac.runs.count, 0, "not sent")

        s.drafts[calc.id] = String(repeating: "é", count: 512)   // exactly 1024 bytes
        XCTAssertFalse(s.tooLong(calc))
        XCTAssertTrue(s.run(calc))
        try await waitUntil("the reply") { s.running == nil }
        XCTAssertEqual(mac.runs.count, 1)
    }

    // MARK: The gate

    func testTheMenuGate() {
        XCTAssertFalse(SessionVerb.offered(["history", "chat", "library"]).contains(.commands), "no commands, no Commands item")
        XCTAssertTrue(SessionVerb.offered(["commands"]).contains(.commands))
        XCTAssertTrue(SessionVerb.menuShown(SessionVerb.offered(["commands"])), "commands alone shows the menu")
        XCTAssertTrue(SessionVerb.menuShown([.commands, .library, .clipboard]))
        XCTAssertFalse(SessionVerb.menuShown([.library, .clipboard]))
        // #656: revive, pin and forget have no item in the menu: no empty ⋯.
        XCTAssertFalse(SessionVerb.menuShown([.revive, .pin, .forget, .library, .clipboard]))
        XCTAssertEqual(SessionVerb.commands.failTitle(all: false), "Commands")
    }
}
