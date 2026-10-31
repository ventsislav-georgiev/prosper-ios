import XCTest
import Network
@testable import Prosper

/// #590: history, revive, restart and stop on the wire, against a loopback fake of the
/// Mac's session server, and the machineInfo `ops` gate that shows their controls.
@MainActor
final class SessionVerbTests: XCTestCase {

    /// A loopback server that reads one frame into `got` and answers `reply` after `delay`.
    private func fakeMac(_ type: UInt8, _ reply: String, delay: TimeInterval = 0) async throws
        -> (ProsperTransport, Box<(UInt8, Data)?>, NWListener) {
        let got = Box<(UInt8, Data)?>(nil)
        let p = NWParameters.tcp
        p.requiredInterfaceType = .loopback
        let listener = try NWListener(using: p, on: .any)
        listener.newConnectionHandler = { c in
            c.start(queue: .main)
            let buf = Box(Data())
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                    if let d { buf.v.append(d) }
                    if let frame = try? FrameCodec.pop(&buf.v) {
                        got.v = frame
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            c.send(content: FrameCodec.encode(type, Data(reply.utf8)), completion: .idempotent)
                        }
                    } else if !done, err == nil { read() }
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
        return (ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue), got, listener)
    }

    private func sent(_ got: Box<(UInt8, Data)?>) -> (UInt8, NSDictionary?) {
        guard let (t, p) = got.v else { return (0, nil) }
        return (t, (try? JSONSerialization.jsonObject(with: p)) as? NSDictionary)
    }

    func testHistoryDecodesRowsWithAndWithoutOptionals() async throws {
        let (mac, got, l) = try await fakeMac(0x1b, """
            [{"name":"api-main-2","alias":"API","end":"signal 9","last_seen":1700000300,"started":1700000000,
              "runtime":300,"cwd":"/work/api","command":["claude","--model","x"],"takes":true},
             {"name":"docs","end":"exit 0","last_seen":2,"started":1,"runtime":1,"takes":false}]
            """)
        defer { l.cancel() }
        let rows = try await mac.history()
        XCTAssertEqual(got.v?.0, 0x0b)
        XCTAssertEqual(got.v?.1, Data(), "history's request is empty")
        XCTAssertEqual(rows, [
            DchHistoryRow(name: "api-main-2", alias: "API", agentName: nil, end: "signal 9", lastSeen: 1700000300, started: 1700000000,
                          runtime: 300, cwd: "/work/api", command: ["claude", "--model", "x"], takes: true),
            DchHistoryRow(name: "docs", alias: nil, agentName: nil, end: "exit 0", lastSeen: 2, started: 1, runtime: 1,
                          cwd: nil, command: nil, takes: false),
        ])
        XCTAssertThrowsError(try ProsperTransport.decodeHistory(Data("{}".utf8)))
    }

    func testReviveOneAndAll() async throws {
        let (one, got1, l1) = try await fakeMac(0x14, #"{"names":["docs-2"]}"#)
        defer { l1.cancel() }
        let revived = try await one.revive(name: "docs")
        XCTAssertEqual(revived, ["docs-2"], "a live name comes back under its free -N")
        XCTAssertEqual(sent(got1).0, 0x0c)
        XCTAssertEqual(sent(got1).1, ["name": "docs"])

        let (all, got2, l2) = try await fakeMac(0x14, #"{"names":[]}"#)
        defer { l2.cancel() }
        let none = try await all.revive(name: nil)
        XCTAssertEqual(none, [], "nothing to take is an ok with no names")
        XCTAssertEqual(sent(got2).1, ["all": true])
    }

    func testRestartNamesAndAll() async throws {
        let (one, got1, l1) = try await fakeMac(0x14, #"{"names":["api-main-2"]}"#)
        defer { l1.cancel() }
        let restarted = try await one.restart(names: ["api-main-2"])
        XCTAssertEqual(restarted, ["api-main-2"])
        XCTAssertEqual(sent(got1).0, 0x0d)
        XCTAssertEqual(sent(got1).1, ["names": ["api-main-2"]])

        let (all, got2, l2) = try await fakeMac(0x14, #"{"names":["api-main-2","docs"]}"#)
        defer { l2.cancel() }
        let every = try await all.restart(names: nil)
        XCTAssertEqual(every, ["api-main-2", "docs"])
        XCTAssertEqual(sent(got2).1, ["all": true])
    }

    func testStopSendsTheNames() async throws {
        let (mac, got, l) = try await fakeMac(0x14, #"{"names":["docs","api-main-2"]}"#)
        defer { l.cancel() }
        let stopped = try await mac.stop(names: ["docs", "api-main-2"])
        XCTAssertEqual(stopped, ["docs", "api-main-2"])
        XCTAssertEqual(sent(got).0, 0x0e)
        XCTAssertEqual(sent(got).1, ["names": ["docs", "api-main-2"]])
    }

    /// Error 0x13's message is shown as written, with no "Protocol error:" in front.
    func testErrorMessageComesThroughAsWritten() async throws {
        let msg = "api-main-2: no live session of that name"
        let (mac, _, l) = try await fakeMac(0x13, #"{"message":"\#(msg)"}"#)
        defer { l.cancel() }
        do {
            _ = try await mac.stop(names: ["api-main-2"])
            XCTFail("an error reply must throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, msg)
        }
        XCTAssertEqual(ProsperTransport.decodeMessage(Data(#"{"message":"dch: busy with an earlier request"}"#.utf8)),
                       "dch: busy with an earlier request")
        XCTAssertThrowsError(try ProsperTransport.decodeNames(Data()), "an ok without names is unreadable")
    }

    /// kill still takes the empty ok it always got.
    func testKillStillTakesAnEmptyOk() async throws {
        let (mac, got, l) = try await fakeMac(0x14, "")
        defer { l.cancel() }
        try await mac.kill(name: "docs")
        XCTAssertEqual(sent(got).0, 0x04)
    }

    /// A restart or stop can take minutes: the reply landing well past the 6 s connect timer
    /// and the 5 s address deadline still comes back.
    func testLongWaitStillReturnsTheReply() async throws {
        let (mac, _, l) = try await fakeMac(0x14, #"{"names":["api-main-2"]}"#, delay: 8)
        defer { l.cancel() }
        let start = Date()
        let names = try await mac.restart(names: ["api-main-2"])
        XCTAssertEqual(names, ["api-main-2"])
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 7.5)
    }

    /// No `ops` (an older Mac) means no controls; a subset means only those.
    func testOpsGate() {
        func ops(_ json: String) -> Set<SessionVerb>? {
            ProsperTransport.decodeMachineInfo(Data(json.utf8))?.ops
        }
        XCTAssertEqual(ops(#"{"device_id":"d"}"#), [])
        XCTAssertEqual(ops(#"{"device_id":"d","ops":["stop"]}"#), [.stop])
        XCTAssertEqual(ops(#"{"device_id":"d","ops":["restart","fly"]}"#), [.restart], "unknown ops are ignored")
        XCTAssertEqual(ops(#"{"device_id":"d","ops":["history","revive","restart","stop"]}"#),
                       [.history, .revive, .restart, .stop])
        XCTAssertEqual(ops(#"{"device_id":"d","ops":"stop"}"#), [], "a malformed ops offers nothing")
        XCTAssertEqual(ops(#"{"device_id":"d","ops":["history","library"]}"#), [.history, .library], "#614")
        XCTAssertEqual(ops(#"{"device_id":"d","ops":["history"]}"#)?.contains(.library), false, "an older Mac: hidden")
    }

    /// The demo and stubs answer no verb; their machine has no ops, so nothing asks.
    func testDemoRefusesTheVerbs() async {
        do { _ = try await DemoTransport().stop(names: ["docs"]); XCTFail("demo must refuse") } catch {}
        do { _ = try await DemoTransport().library(etag: nil); XCTFail("demo must refuse") } catch {
            XCTAssertEqual(error.localizedDescription, "Not supported here.")
        }
    }

    // MARK: - #614 Library

    /// No etag: an empty request; a full reply, a file's error and a null file decode.
    func testLibraryFullReply() async throws {
        let (mac, got, l) = try await fakeMac(0x1c, """
            {"etag":"ab12","snippets":{"version":1,"collections":[],"snippets":[{"name":"Sign","text":"— me"}]},
             "quicklinks":null,"errors":{"quicklinks":"too large (over 3 MB)"}}
            """)
        defer { l.cancel() }
        let r = try await mac.library(etag: nil)
        XCTAssertEqual(got.v?.0, 0x0f)
        XCTAssertEqual(got.v?.1, Data(), "no etag: an empty request")
        XCTAssertEqual(r.etag, "ab12")
        XCTAssertFalse(r.unchanged)
        XCTAssertEqual(SnippetStore.decode(try XCTUnwrap(r.snippets))?.snippets.map(\.text), ["— me"])
        XCTAssertNil(r.quicklinks)
        XCTAssertEqual(r.errors, ["quicklinks": "too large (over 3 MB)"])

        let none = try ProsperTransport.decodeLibrary(Data(#"{"etag":"e3","snippets":null,"quicklinks":null}"#.utf8))
        XCTAssertEqual(none, LibraryReply(etag: "e3"), "missing files: null, no errors")
        let links = try ProsperTransport.decodeLibrary(Data(#"{"etag":"e4","snippets":null,"quicklinks":{"version":1,"quicklinks":[{"name":"notes","url":"~/notes"}]}}"#.utf8))
        XCTAssertEqual(QuicklinkStore.decode(try XCTUnwrap(links.quicklinks))?.quicklinks, [.init(name: "notes", url: "~/notes")])
        XCTAssertThrowsError(try ProsperTransport.decodeLibrary(Data("{}".utf8)), "no etag is unreadable")
    }

    /// The stored etag goes back; `unchanged` carries no files.
    func testLibraryUnchanged() async throws {
        let (mac, got, l) = try await fakeMac(0x1c, #"{"etag":"ab12","unchanged":true}"#)
        defer { l.cancel() }
        let r = try await mac.library(etag: "ab12")
        XCTAssertEqual(sent(got).0, 0x0f)
        XCTAssertEqual(sent(got).1, ["etag": "ab12"])
        XCTAssertEqual(r, LibraryReply(etag: "ab12", unchanged: true))
    }

    func testLibraryRefusalComesThroughAsWritten() async throws {
        let (mac, _, l) = try await fakeMac(0x13, #"{"message":"malformed library request"}"#)
        defer { l.cancel() }
        do { _ = try await mac.library(etag: nil); XCTFail("an error reply must throw") } catch {
            XCTAssertEqual(error.localizedDescription, "malformed library request")
        }
    }

    // MARK: - #589 History and Resume

    func testEndLabelsMatchTheIsland() {
        let cases = [
            "": "vanished", "vanished": "vanished", "killed": "closed", "exit 0": "exited",
            "signal 15": "ended (signal 15)", "signal 1": "ended (signal 1)", "signal 2": "ended (signal 2)",
            "signal 9": "crashed (signal 9)", "signal 11": "crashed (signal 11)",
            "exit 1": "exited (1)", "exit 137": "exited (137)", "stopped": "stopped",
        ]
        for (end, label) in cases { XCTAssertEqual(DchHistoryRow.endLabel(end), label, end) }
    }

    /// #593: agent_name decodes, "" as nil; the title is alias, then agent name, then dch name.
    func testHistoryAgentNameIsTheTitle() throws {
        let rows = try ProsperTransport.decodeHistory(Data("""
            [{"name":"api-main-2","agent_name":"harness","end":"exit 0"},
             {"name":"docs","agent_name":"","end":"exit 0"}]
            """.utf8))
        XCTAssertEqual(rows.map(\.agentName), ["harness", nil])
        XCTAssertEqual(rows.map(\.title), ["harness", "docs"])
        var r = rows[0]
        r.alias = "API"
        XCTAssertEqual(r.title, "API", "the alias outranks the agent name")
    }

    /// #593: the dch name shows only with Session name on and when it isn't the title.
    func testHistoryDchNameGate() {
        let r = DchHistoryRow(name: "api-main-2", alias: nil, agentName: "harness", end: "exit 0", lastSeen: 2,
                              started: 1, runtime: 1, cwd: nil, command: nil, takes: false)
        XCTAssertNil(DchHistoryRow.dchName(r, shown: false), "toggle off hides it")
        XCTAssertEqual(DchHistoryRow.dchName(r, shown: true), "api-main-2")
        var plain = r
        plain.agentName = nil
        XCTAssertNil(DchHistoryRow.dchName(plain, shown: true), "the name equal to the title hides it")
    }

    func testResumeInterruptedCountsOnlyTakes() {
        func row(_ name: String, _ takes: Bool) -> DchHistoryRow {
            DchHistoryRow(name: name, alias: nil, agentName: nil, end: "signal 9", lastSeen: 2, started: 1, runtime: 1,
                          cwd: nil, command: nil, takes: takes)
        }
        XCTAssertNil(DchHistoryRow.resumeAllLabel([]), "nothing to take hides the button")
        XCTAssertNil(DchHistoryRow.resumeAllLabel([row("docs", false)]), "no record dch takes hides it too")
        XCTAssertEqual(DchHistoryRow.resumeAllLabel([row("api-main-2", true), row("docs", false), row("web", true)]),
                       "Resume interrupted (2)")
    }

    func testResumeSendsTheNameAndResumeAllSendsAll() async throws {
        let (one, got1, l1) = try await fakeMac(0x14, #"{"names":["docs-2"]}"#)
        defer { l1.cancel() }
        let ok = await HistorySheet.resume("docs", on: one)
        XCTAssertNil(ok, "an ok raises no alert")
        XCTAssertEqual(sent(got1).0, 0x0c)
        XCTAssertEqual(sent(got1).1, ["name": "docs"])

        let (all, got2, l2) = try await fakeMac(0x14, #"{"names":[]}"#)
        defer { l2.cancel() }
        let none = await HistorySheet.resume(nil, on: all)
        XCTAssertNil(none)
        XCTAssertEqual(sent(got2).1, ["all": true])
    }

    func testResumeErrorsKeepTheMacsWordsUnderTheirTitle() async throws {
        let (all, _, l1) = try await fakeMac(0x13, #"{"message":"2 resumed, 1 failed"}"#)
        defer { l1.cancel() }
        let summary = await HistorySheet.resume(nil, on: all)
        XCTAssertEqual(summary?.title, "Resume interrupted", "an all-run's alert is named after the action")
        XCTAssertEqual(summary?.message, "2 resumed, 1 failed")

        let (one, _, l2) = try await fakeMac(0x13, #"{"message":"docs: no history record of that name"}"#)
        defer { l2.cancel() }
        let named = await HistorySheet.resume("docs", on: one)
        XCTAssertEqual(named?.title, "Resume failed")
        XCTAssertEqual(named?.message, "docs: no history record of that name")
    }

    func testRestartAllErrorIsTitledRestartAll() async throws {
        let (mac, got, l) = try await fakeMac(0x13, #"{"message":"1 restarted, 1 failed"}"#)
        defer { l.cancel() }
        let f = await SessionListView.attempt(SessionVerb.restart.failTitle(all: true), on: mac) { try await $0.restart(names: nil) }
        XCTAssertEqual(f?.title, "Restart all")
        XCTAssertEqual(f?.message, "1 restarted, 1 failed")
        XCTAssertEqual(sent(got).1, ["all": true])
        XCTAssertEqual(SessionVerb.restart.failTitle(all: false), "Restart failed")
        XCTAssertEqual(SessionVerb.stop.failTitle(all: false), "Stop failed")
        XCTAssertEqual(SessionVerb.revive.failTitle(all: false), "Resume failed")
    }
}
