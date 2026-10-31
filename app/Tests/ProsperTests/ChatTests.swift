import XCTest
import Network
@testable import Prosper

/// #646: chat with the Mac's local model: the request on the wire, a reply streamed then
/// ended or refused, Stop closing the connection, trimming at the Mac's byte cap, the menu
/// gate, the models reply and the busy copy. A loopback Mac on an ephemeral port.
@MainActor
final class ChatTests: XCTestCase {
    /// The fake Mac. Models 0x1e get `models`; any other request gets `reply`, frame by frame,
    /// then `later` 0.3 s on, and the connection stays open after. `requests` keeps each connection's first frame;
    /// `ended` counts the chat connections the phone closed.
    private final class FakeMac {
        let requests = Box<[(UInt8, Data)]>([])
        let ended = Box(0)
        var transport: ProsperTransport!
        var listener: NWListener!
        var chats: [NSDictionary] {
            requests.v.filter { $0.0 == 0x1f }.compactMap { (try? JSONSerialization.jsonObject(with: $0.1)) as? NSDictionary }
        }
    }

    private var macs: [FakeMac] = []

    override func tearDown() {
        macs.forEach { $0.listener.cancel() }
        super.tearDown()
    }

    private func fakeMac(models: String = #"[{"id":"local-1","name":"Local Model 7B","loaded":true}]"#,
                         reply: [(UInt8, String)], later: [(UInt8, String)] = []) async throws -> FakeMac {
        let mac = FakeMac()
        let requests = mac.requests, ended = mac.ended
        let p = NWParameters.tcp
        p.requiredInterfaceType = .loopback
        let listener = try NWListener(using: p, on: .any)
        listener.newConnectionHandler = { c in
            c.start(queue: .main)
            let buf = Box(Data())
            let type = Box<UInt8?>(nil)
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                    if let d { buf.v.append(d) }
                    if type.v == nil, let frame = try? FrameCodec.pop(&buf.v) {
                        type.v = frame.0
                        requests.v.append(frame)
                        let frames = frame.0 == 0x1e ? [(UInt8(0x27), models)] : reply
                        for (t, s) in frames { c.send(content: FrameCodec.encode(t, Data(s.utf8)), completion: .idempotent) }
                        if frame.0 == 0x1f, !later.isEmpty {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                for (t, s) in later { c.send(content: FrameCodec.encode(t, Data(s.utf8)), completion: .idempotent) }
                            }
                        }
                    }
                    if done || err != nil {
                        if type.v == 0x1f { ended.v += 1 }
                        c.cancel()
                    } else { read() }
                }
            }
            read()
        }
        listener.start(queue: .main)
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

    private func delta(_ text: String) -> (UInt8, String) {
        (0x20, String(data: try! JSONSerialization.data(withJSONObject: ["text": text]), encoding: .utf8)!)
    }
    private let done: (UInt8, String) = (0x21, #"{"stop":"stop"}"#)
    private func error(_ message: String) -> (UInt8, String) { (0x13, #"{"message":"\#(message)"}"#) }

    // MARK: The wire

    func testTheRequestCarriesOnlyMessagesAndEndsWithTheUser() async throws {
        let mac = try await fakeMac(reply: [delta("one"), done])
        let chat = ChatSession(transport: mac.transport)
        XCTAssertTrue(chat.send("  first  "))
        try await waitUntil("the first reply") { chat.turns.last?.end == .done }
        XCTAssertTrue(chat.send("second"))
        try await waitUntil("the second reply") { chat.turns.last?.end == .done }

        XCTAssertEqual(mac.chats.count, 2, "a connection per chat")
        XCTAssertEqual(mac.chats[0], ["messages": [["role": "user", "content": "first"]]], "no model, no max_tokens, not even null")
        XCTAssertEqual(mac.chats[1], ["messages": [["role": "user", "content": "first"], ["role": "assistant", "content": "one"],
                                                   ["role": "user", "content": "second"]]])
        try await waitUntil("both chat connections closed") { mac.ended.v == 2 }
    }

    func testDeltasThenDoneAssembleTheReply() async throws {
        let mac = try await fakeMac(reply: [delta("**Hello**"), delta(", "), delta("world"), done])
        var chunks: [String] = []
        for try await text in mac.transport.chat([ChatMessage(role: .user, content: "hi")]) { chunks.append(text) }
        XCTAssertEqual(chunks, ["**Hello**", ", ", "world"], "in order, as sent")

        let chat = ChatSession(transport: mac.transport)
        chat.send("hi")
        try await waitUntil("the reply") { chat.turns.last?.end == .done }
        XCTAssertEqual(chat.turns.last?.reply, "**Hello**, world")
        XCTAssertEqual(chat.model?.name, "Local Model 7B", "the title")
    }

    func testADeltaThenAnErrorKeepsThePartialReplyAndRetryResends() async throws {
        let mac = try await fakeMac(reply: [delta("Part"), error("inference error: out of memory")])
        let chat = ChatSession(transport: mac.transport)
        chat.send("hi")
        try await waitUntil("the error") { chat.turns.last?.end != .streaming }
        XCTAssertEqual(chat.turns.last?.reply, "Part")
        XCTAssertEqual(chat.turns.last?.end, .failed("inference error: out of memory"), "as the Mac wrote it")

        chat.retry()
        XCTAssertEqual(chat.turns.count, 1, "the same turn again")
        try await waitUntil("the retry's error") { chat.turns.last?.end != .streaming }
        XCTAssertEqual(mac.chats.count, 2)
        XCTAssertEqual(mac.chats[1], mac.chats[0], "the same conversation")
        XCTAssertEqual(chat.turns.last?.reply, "Part", "the old partial was dropped, not doubled")
    }

    func testBusyRefusalsReadAsPlainCopy() async throws {
        XCTAssertEqual(ChatSession.copy("busy: another chat is running"), "Another chat is running on the Mac. Try again when it finishes.")
        XCTAssertEqual(ChatSession.copy("busy: the Mac's agent is running"), "The Mac's agent is working. Try again in a moment.")
        XCTAssertEqual(ChatSession.copy("inference error: agent prompt (9000 tokens) exceeds the context window (8192)"),
                       "This chat is too long for the Mac's model. Start a new chat.")
        XCTAssertEqual(ChatSession.copy("no local model"), "no local model", "the rest as written")

        let mac = try await fakeMac(reply: [error("busy: another chat is running")])
        let chat = ChatSession(transport: mac.transport)
        chat.send("hi")
        try await waitUntil("the refusal") { chat.turns.last?.end != .streaming }
        XCTAssertEqual(chat.turns.last?.end, .failed("Another chat is running on the Mac. Try again when it finishes."))
        XCTAssertEqual(chat.turns.last?.reply, "")
    }

    func testStopClosesTheConnectionAndKeepsThePartialReply() async throws {
        let mac = try await fakeMac(reply: [delta("Part")])   // and then nothing: still generating
        let chat = ChatSession(transport: mac.transport)
        chat.send("hi")
        try await waitUntil("the first delta") { chat.turns.last?.reply == "Part" }
        XCTAssertTrue(chat.generating)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mac.ended.v, 0, "open while generating")

        chat.stop()
        XCTAssertEqual(chat.turns.last?.end, .stopped)
        XCTAssertEqual(chat.turns.last?.reply, "Part")
        XCTAssertFalse(chat.generating)
        try await waitUntil("the Mac sees the connection end") { mac.ended.v == 1 }
        try await Task.sleep(nanoseconds: 300_000_000)   // the cancelled stream's own end lands
        XCTAssertEqual(chat.turns.last?.end, .stopped, "the stream ending after a Stop doesn't overwrite it")
        XCTAssertEqual(chat.turns.last?.reply, "Part")
    }

    func testNewChatMidReplyLeavesNothingBehind() async throws {
        let mac = try await fakeMac(reply: [delta("Part")], later: [delta(" late"), done])
        let chat = ChatSession(transport: mac.transport)
        chat.send("hi")
        try await waitUntil("the first delta") { chat.turns.last?.reply == "Part" }
        chat.clear()
        XCTAssertEqual(chat.turns, [])
        XCTAssertFalse(chat.generating)
        try await waitUntil("the Mac sees the connection end") { mac.ended.v == 1 }
        try await Task.sleep(nanoseconds: 600_000_000)   // past the Mac's late frames
        XCTAssertEqual(chat.turns, [], "no stale turn or delta comes back")
    }

    // MARK: Trimming

    func testTrimmingDropsTheOldestPairsAtTheByteEdge() {
        let pairs = [ChatMessage(role: .user, content: "é"), ChatMessage(role: .assistant, content: String(repeating: "a", count: 99)),
                     ChatMessage(role: .user, content: "b"), ChatMessage(role: .assistant, content: "c")]
        let edge = String(repeating: "x", count: ChatSession.limit - 101 - 2)   // é is 2 bytes
        XCTAssertEqual(ChatSession.fit(pairs, edge)?.count, 5, "exactly 262144 bytes go whole")
        XCTAssertEqual(ChatSession.fit(pairs, edge + "x"), Array(pairs.dropFirst(2)) + [ChatMessage(role: .user, content: edge + "x")],
                       "one byte over drops the oldest pair")
        let alone = String(repeating: "x", count: ChatSession.limit)
        XCTAssertEqual(ChatSession.fit(pairs, alone), [ChatMessage(role: .user, content: alone)], "every pair goes before the newest")
        XCTAssertNil(ChatSession.fit([], alone + "x"), "the newest alone over the cap")
    }

    func testAnOversizedMessageSendsNothing() async throws {
        let mac = try await fakeMac(reply: [done])
        let chat = ChatSession(transport: mac.transport)
        XCTAssertFalse(chat.send(String(repeating: "x", count: ChatSession.limit + 1)))
        XCTAssertTrue(chat.tooLong)
        XCTAssertEqual(chat.turns, [])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mac.chats.count, 0)
    }

    func testHistoryKeepsOnlyAnsweredTurns() {
        var answered = ChatSession.Turn(prompt: "q1"); answered.reply = "a1"; answered.end = .done
        var failed = ChatSession.Turn(prompt: "q2"); failed.end = .failed("no local model")
        XCTAssertEqual(ChatSession.history([answered, failed][...]),
                       [ChatMessage(role: .user, content: "q1"), ChatMessage(role: .assistant, content: "a1")], "roles alternate")
    }

    // MARK: Models and the gate

    func testModelsDecoding() async throws {
        XCTAssertEqual(try ProsperTransport.decodeModels(Data(#"[{"id":"m","name":"Model","loaded":false},{"name":"no id"}]"#.utf8)),
                       [LocalModel(id: "m", name: "Model", loaded: false)])
        XCTAssertEqual(try ProsperTransport.decodeModels(Data("[]".utf8)), [], "nothing on disk")
        XCTAssertThrowsError(try ProsperTransport.decodeModels(Data("{}".utf8)))

        let mac = try await fakeMac(models: #"[{"id":"m","name":"Model","loaded":true}]"#, reply: [])
        let models = try await mac.transport.models()
        XCTAssertEqual(models, [LocalModel(id: "m", name: "Model", loaded: true)])
        XCTAssertEqual(mac.requests.v.first?.0, 0x1e)
        XCTAssertEqual(mac.requests.v.first?.1, Data(), "an empty request")
    }

    func testTheMenuGate() {
        XCTAssertFalse(SessionVerb.offered(["history", "library"]).contains(.chat), "no chat, no Chat item")
        XCTAssertTrue(SessionVerb.offered(["chat"]).contains(.chat))
        XCTAssertTrue(SessionVerb.menuShown(SessionVerb.offered(["chat"])), "chat alone shows the menu")
        XCTAssertTrue(SessionVerb.menuShown([.chat, .library, .clipboard]))
        XCTAssertFalse(SessionVerb.menuShown([.library, .clipboard]))
        // #656: revive, pin and forget have no item in the menu: no empty ⋯.
        XCTAssertFalse(SessionVerb.menuShown([.revive, .pin, .forget, .library, .clipboard]))
        XCTAssertEqual(SessionVerb.chat.failTitle(all: false), "Chat")
    }
}
