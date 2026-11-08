import XCTest
import Network
@testable import Prosper

/// #779: remote frames protocol 1.0 on the phone: the 0x18 keys `server`, `os`, `name` and
/// `proto`, the version refusal, and what a host that isn't Prosper (`dch serve`) gets.
/// Payloads are concrete frames matching the spec's golden shapes (docs/protocol/golden).
@MainActor
final class RemoteHostTests: XCTestCase {

    /// golden/01-machine-info, as Prosper answers it.
    private let prosper = #"{"device_id":"3f9a0c","hostname":"Studio","ops":["history","revive","restart","stop","library","pin","forget","snippets_put","sidekick","watch"],"server":"prosper","os":"macOS 27.0","name":"Studio","proto":"1.0","wakeId":"w-1"}"#
    /// golden/01-machine-info, as `dch serve` answers it: no wakeId, no Mac-only ops.
    private let dch = #"{"device_id":"77e1","hostname":"linux-box","ops":["watch"],"server":"dch","os":"Linux 6.8","name":"Build box","proto":"1.0"}"#

    private func info(_ json: String) throws -> MachineInfo {
        try XCTUnwrap(ProsperTransport.decodeMachineInfo(Data(json.utf8)))
    }

    /// `json` framed as a server sends it, then read back as one whole frame.
    private func frame(_ type: UInt8, _ json: String) throws -> (UInt8, Data) {
        var buf = FrameCodec.encode(type, Data(json.utf8))
        return try XCTUnwrap(try FrameCodec.pop(&buf))
    }

    // MARK: - 0x18

    func testProsperMachineInfoDecodes() throws {
        let (t, p) = try frame(0x18, prosper)
        XCTAssertEqual(t, 0x18)
        let i = try XCTUnwrap(ProsperTransport.decodeMachineInfo(p))
        XCTAssertEqual(i.deviceId, "3f9a0c")
        XCTAssertEqual(i.server, "prosper")
        XCTAssertEqual(i.os, "macOS 27.0")
        XCTAssertEqual(i.name, "Studio")
        XCTAssertEqual(i.proto, "1.0")
        XCTAssertEqual(i.wakeId, "w-1")
        XCTAssertTrue(i.ops.isSuperset(of: [.history, .watch, .sidekick]))
    }

    func testDchMachineInfoDecodes() throws {
        let i = try info(dch)
        XCTAssertEqual(i.server, "dch")
        XCTAssertEqual(i.os, "Linux 6.8")
        XCTAssertEqual(i.name, "Build box")
        XCTAssertEqual(i.hostname, "linux-box")
        XCTAssertNil(i.wakeId)
        XCTAssertEqual(i.ops, [.watch])
    }

    /// A pre-#776 Prosper: none of the new keys, still a Mac. device_id stays required.
    func testOlderProsperHasNoNewKeys() throws {
        let i = try info(#"{"device_id":"d","hostname":"Mac","ops":["stop"]}"#)
        XCTAssertNil(i.server)
        XCTAssertNil(i.os)
        XCTAssertNil(i.name)
        XCTAssertNil(i.proto)
        XCTAssertTrue(MachineInfo.supports(i.proto), "no proto is 1.0")
        XCTAssertNil(ProsperTransport.decodeMachineInfo(Data(#"{"hostname":"x","server":"dch","proto":"1.0"}"#.utf8)))
    }

    // MARK: - proto

    func testProtoMajor() {
        XCTAssertTrue(MachineInfo.supports("1.0"))
        XCTAssertTrue(MachineInfo.supports("1.7"), "a minor bump only adds")
        XCTAssertTrue(MachineInfo.supports("1.10"))
        XCTAssertFalse(MachineInfo.supports("2.0"))
        XCTAssertFalse(MachineInfo.supports("10.1"))
        XCTAssertTrue(MachineInfo.supports(nil), "missing is 1.0")
        for garbage in ["", "x", "2", "2.", ".1", "2.0.1", "2.x", "-2.0", " 2.0", "２.0", "99999999999999999999.0"] {
            XCTAssertNil(MachineInfo.major(garbage), garbage)
            XCTAssertTrue(MachineInfo.supports(garbage), "garbage \(garbage) is 1.0")
        }
        XCTAssertEqual(MachineInfo.major("1.7"), 1)
        XCTAssertEqual(MachineInfo.major("2.0"), 2)
    }

    /// The 0x08 request is `{"proto":"1.0"}`; a 2.0 reply is read and refused, and that one
    /// frame on one connection is all the host got.
    func testMachineInfoSendsProtoAndANewerMajorIsRefused() async throws {
        let frames = Box<[(UInt8, Data)]>([])
        let conns = Box(0)
        let reply = #"{"device_id":"d","hostname":"h","ops":["watch","create"],"server":"dch","os":"Linux 7.0","name":"n","proto":"2.0"}"#
        let listener = try loopbackServer { c in
            conns.v += 1
            let buf = Box(Data())
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                    if let d { buf.v.append(d) }
                    while let f = try? FrameCodec.pop(&buf.v) {
                        frames.v.append(f)
                        c.send(content: FrameCodec.encode(0x18, Data(reply.utf8)), completion: .idempotent)
                    }
                    if !done, err == nil { read() }
                }
            }
            read()
        }
        defer { listener.cancel() }
        let end = Date().addingTimeInterval(3)
        while (listener.port?.rawValue ?? 0) == 0 {
            if Date() > end { throw XCTSkip("loopback listener never came up") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let t = ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue)
        let got = try await t.machineInfo()
        let i = try XCTUnwrap(got)
        XCTAssertEqual(i.proto, "2.0")
        XCTAssertFalse(MachineInfo.supports(i.proto))
        var m = Machine(name: "typed", addresses: ["127.0.0.1"], offersLibrary: true)
        m.adopt(i)
        XCTAssertEqual(m.offersLibrary, false, "a refused host offers no library to Settings")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(conns.v, 1)
        XCTAssertEqual(frames.v.map(\.0), [0x08])
        XCTAssertEqual(frames.v.first?.1, Data(#"{"proto":"1.0"}"#.utf8))
        XCTAssertEqual(SessionListView.newerProtocol, "This host needs a newer Prosper. Update the app.")
        XCTAssertEqual(ProsperTransport.decodeMessage(Data("{}".utf8)), "The host refused the request.")
    }

    // MARK: - The stored machine

    func testDchHostLabelAndNoWake() throws {
        var m = Machine(name: "typed", addresses: ["100.64.0.9"], wakeId: "old",
                        cachedWake: WakeInfo(enabled: true, intervalAC: nil, intervalBatt: 300))
        XCTAssertEqual(m.label, "typed", "before a handshake: what the user typed")
        XCTAssertNil(m.osLine)
        m.adopt(try info(dch))
        XCTAssertEqual(m.label, "typed", "the user's own name wins (#628)")
        XCTAssertEqual(m.osLine, "Linux 6.8 · dch")
        XCTAssertNil(m.wakeId, "a dch host has no wake")
        XCTAssertNil(m.cachedWake, "so no Wake badge, Sleep or Wake card")
        XCTAssertEqual(m.offersLibrary, false)

        var blank = Machine(name: "", addresses: ["100.64.0.9"])
        blank.adopt(try info(dch))
        XCTAssertEqual(blank.label, "Build box", "no name given: the host's name")

        var migrated = Machine(name: "box.ts.net", addresses: ["100.64.0.9", "box.ts.net"])
        XCTAssertEqual(migrated.label, "box.ts.net", "before a handshake: the address it was saved as")
        migrated.adopt(try info(dch))
        XCTAssertEqual(migrated.label, "Build box", "a name that is one of its addresses is no real name")

        var noName = Machine(name: "x", addresses: ["x"])
        noName.adopt(try info(#"{"device_id":"d","hostname":"linux-box","server":"dch"}"#))
        XCTAssertEqual(noName.label, "linux-box", "no name key: the hostname")
        XCTAssertEqual(noName.osLine, "dch")

        var bare = Machine(name: "x", addresses: ["x"])
        bare.adopt(try info(#"{"device_id":"d"}"#))
        XCTAssertEqual(bare.label, "x", "nothing from the host: what the user typed")

        var mac = Machine(name: "typed", addresses: ["x"], wakeId: "kept")
        mac.adopt(try info(#"{"device_id":"d","hostname":"Studio"}"#))
        XCTAssertEqual(mac.wakeId, "kept", "an older Prosper with wake off keeps its id")
        XCTAssertNil(mac.osLine, "no subtitle for Prosper")
        mac.adopt(try info(prosper))
        XCTAssertNil(mac.osLine)
        XCTAssertEqual(mac.offersLibrary, true)
    }

    /// The new fields survive the store, and machines saved before them still load.
    func testMachineCodable() throws {
        var m = Machine(name: "typed", addresses: ["a"])
        m.adopt(try info(dch))
        let back = try JSONDecoder().decode([Machine].self, from: JSONEncoder().encode([m]))
        XCTAssertEqual(back, [m])
        let old = try JSONDecoder().decode(Machine.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Mac","addresses":["a"]}"#.utf8))
        XCTAssertNil(old.server)
        XCTAssertEqual(old.label, "Mac")
    }

    // MARK: - Gating

    func testCreateAndImagePasteGates() throws {
        let dchOps = try info(dch).ops
        for verb in [SessionVerb.create, .pasteImage] {
            XCTAssertFalse(verb.allowed(server: "dch", ops: dchOps), "\(verb): hidden on dch without its op")
            XCTAssertTrue(verb.allowed(server: "dch", ops: dchOps.union([verb])), "\(verb): offered once dch lists it")
            XCTAssertTrue(verb.allowed(server: nil, ops: []), "\(verb): an older Prosper serves it unlisted")
            XCTAssertTrue(verb.allowed(server: "prosper", ops: []), "\(verb): Prosper serves it unlisted")
        }
        XCTAssertEqual(SessionVerb.offered(["create", "paste_image"]), [.create, .pasteImage])
        XCTAssertFalse(SessionVerb.commands.allowed(server: "dch", ops: dchOps), "no keyboard Commands tile for dch")
    }

    /// None of the Mac-only verbs is offered by a dch host listing only core ops.
    func testDchOffersNoMacOnlyControls() throws {
        let ops = try info(dch).ops
        XCTAssertFalse(SessionVerb.menuShown(ops), "no ⋯ menu")
        let row = DchHistoryRow(name: "a", alias: nil, agentName: nil, end: "", lastSeen: 0, started: 0,
                                runtime: 0, cwd: nil, command: nil, takes: true)
        XCTAssertEqual(DchHistoryRow.actions(row, ops: ops), [])
        XCTAssertFalse(DchHistoryRow.noMessageShown(ops))
        XCTAssertTrue(ops.isDisjoint(with: [.history, .revive, .restart, .stop, .library, .pin, .forget,
                                            .clipboard, .chat, .commands, .snippetsPut, .sidekick]))
        XCTAssertTrue(SessionWatch.wanted(ops, .live), "watch is core")
    }

    /// No 0x0a to a host without paste_image: not from a share, not from the paste img key's path.
    /// Share › image: neither the 0x0a nor its ctrl-V; the text still goes.
    func testNoImagePasteFrameWithoutTheOp() async throws {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport, session: DchSession(name: "main"), pastesImages: false)
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        conn.deliver(ShareItem(target: ShareTarget(machine: UUID(), session: "main"), text: "hi", image: png))
        XCTAssertEqual(conn.notice, SessionConnection.noImagePaste)
        conn.start(cols: 80, rows: 24)
        try await Task.sleep(nanoseconds: 200_000_000)
        transport.stream.emit("$ ")
        try await Task.sleep(nanoseconds: 100_000_000)
        conn.putClipboard(png)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.stream.clipboards, [], "no 0x0a")
        XCTAssertEqual(transport.stream.sent, [Array("\u{1b}[200~hi\u{1b}[201~".utf8)], "the text alone, no ctrl-V")
    }

    /// The paste img key: neither the 0x0a nor a lone ctrl-V, and the pasteboard is never read.
    func testPasteImageKeySendsNothingWithoutTheOp() async throws {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport, session: DchSession(name: "t"), pastesImages: false)
        let vc = TerminalHostVC(conn: conn, handle: TermHandle())
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        vc.view.layoutIfNeeded()
        vc.startIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        transport.stream.emit("$ ")
        try await Task.sleep(nanoseconds: 50_000_000)
        vc.pasteImage(then: [0x16])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.stream.clipboards, [], "no 0x0a")
        XCTAssertEqual(transport.stream.sent, [], "no ctrl-V")
        XCTAssertEqual(conn.notice, SessionConnection.noImagePaste)
    }

    // MARK: - 0x11

    /// golden/02-04: a list frame, one split across reads, two in one read; rows in any order.
    func testListFramesDecodeAndSort() throws {
        let rows = #"[{"name":"s10","state":"idle"},{"agents":2,"alias":"API","meta":{"prs":{"open":[]}},"meta_epoch":1700000000,"name":"api","state":"working"},{"name":"s2"}]"#
        let bytes = FrameCodec.encode(0x11, Data(rows.utf8))
        var buf = Data(bytes.prefix(3))
        XCTAssertNil(try FrameCodec.pop(&buf), "half a header is no frame")
        buf.append(bytes.dropFirst(3))
        let (t, p) = try XCTUnwrap(try FrameCodec.pop(&buf))
        XCTAssertEqual(t, 0x11)
        XCTAssertTrue(buf.isEmpty)
        let list = try ProsperTransport.decodeList(p)
        XCTAssertEqual(list.map(\.name), ["s10", "api", "s2"], "decoded in server order")
        XCTAssertEqual(list[1].agents, 2)
        XCTAssertEqual(list[1].state, "working")
        XCTAssertEqual(DchSession.ordered(list).map(\.title), ["API", "s2", "s10"], "the phone sorts")

        var two = bytes + bytes
        XCTAssertEqual(try FrameCodec.pop(&two)?.1, p)
        XCTAssertEqual(try FrameCodec.pop(&two)?.1, p)
        XCTAssertNil(try FrameCodec.pop(&two))

        XCTAssertEqual(try ProsperTransport.decodeList(Data("[]".utf8)), [])
        XCTAssertThrowsError(try ProsperTransport.decodeList(Data(#"{"name":"x"}"#.utf8)), "not an array: the rows stay")
    }
}
