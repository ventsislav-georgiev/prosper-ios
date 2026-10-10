import XCTest
import Network
@testable import Prosper

/// Every key the user presses must reach the pty exactly once and in order, whatever
/// the link does in between: typed while stalled, while reattaching, while the queue
/// is still flushing, or handed back by a transport that couldn't put it on the wire.
@MainActor
final class SessionConnectionDeliveryTests: XCTestCase {

    private func make() -> (SessionConnection, DeliveryTransport) {
        let t = DeliveryTransport()
        let conn = SessionConnection(transport: t, session: DchSession(name: "t", alias: nil))
        conn.onBytes = { _ in }
        return (conn, t)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3,
                           _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Start and bring the first stream live (its first output opens it to input).
    private func startLive(_ conn: SessionConnection, _ t: DeliveryTransport) async throws -> DeliveryStream {
        conn.start(cols: 80, rows: 24)
        try await waitUntil("first attach") { t.streams.count == 1 }
        let s = t.streams[0]
        s.emit("$ ")
        try await waitUntil("connected") { conn.state == .connected }
        try await Task.sleep(nanoseconds: 50_000_000)   // let the loop consume that output
        return s
    }

    /// Drop the link and park the reattach, so the connection sits in `.stalled`.
    private func stall(_ s: DeliveryStream, _ conn: SessionConnection, _ t: DeliveryTransport) async throws {
        t.hold = true
        s.drop()
        try await waitUntil("stalled with the attach parked") { conn.state == .stalled && t.parked }
    }

    private func reattachLive(_ conn: SessionConnection, _ t: DeliveryTransport, index: Int) async throws -> DeliveryStream {
        t.release()
        try await waitUntil("reattach") { t.streams.count == index + 1 }
        let s = t.streams[index]
        s.emit("$ ")
        return s
    }

    func testBytesTypedWhileStalledArriveInOrderAfterReconnect() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        conn.send(Array("a".utf8)[...])
        XCTAssertEqual(s1.text, "a", "a live stream with nothing queued takes input directly")

        try await stall(s1, conn, t)
        conn.send(Array("b".utf8)[...])
        conn.send(Array("c".utf8)[...])
        XCTAssertEqual(conn.queuedByteCount, 2, "typed while stalled must be held, not dropped")

        t.release()
        try await waitUntil("reattach") { t.streams.count == 2 }
        let s2 = t.streams[1]
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(s2.text, "", "flushed before the new dch client showed it was in raw mode")

        conn.send(Array("d".utf8)[...])   // typed after reattach, before the flush
        s2.emit("$ ")
        try await waitUntil("flush") { s2.text == "bcd" }
        conn.send(Array("e".utf8)[...])
        XCTAssertEqual(s2.text, "bcde")
        XCTAssertEqual(s1.text, "a", "nothing may be written twice")
        XCTAssertEqual(conn.queuedByteCount, 0)
    }

    /// A stream that stops taking input part-way through the flush: what it refused and
    /// everything typed after stays in line, in order, for the next stream.
    func testSendsDuringAnInterruptedFlushKeepOrder() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        try await stall(s1, conn, t)
        for c in ["1", "2", "3"] { conn.send(Array(c.utf8)[...]) }

        t.release()
        try await waitUntil("reattach") { t.streams.count == 2 }
        let s2 = t.streams[1]
        s2.acceptLimit = 1
        s2.emit("$ ")
        try await waitUntil("partial flush") { s2.text == "1" }
        conn.send(Array("4".utf8)[...])
        XCTAssertEqual(s2.text, "1", "a send must not jump the queue")

        s2.drop()   // not held: reattaches straight away
        try await waitUntil("third attach") { t.streams.count == 3 }
        let s3 = t.streams[2]
        s3.emit("$ ")
        try await waitUntil("rest flushed") { s3.text == "234" }
    }

    /// The transport took the bytes, then reported they never reached the socket. They
    /// go back in line ahead of anything typed after them.
    func testBytesTheTransportCouldNotSendAreRequeuedFirst() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        conn.send(Array("a".utf8)[...])
        XCTAssertEqual(s1.text, "a")

        s1.accepting = false
        s1.bounce(.bytes(Array("a".utf8)))   // NWConnection: send failed before the kernel
        conn.send(Array("b".utf8)[...])      // refused by the dead stream → queued
        t.hold = true
        s1.drop()
        try await waitUntil("stalled") { t.parked }
        XCTAssertEqual(conn.queuedByteCount, 2)

        let s2 = try await reattachLive(conn, t, index: 1)
        try await waitUntil("flush") { s2.text == "ab" }
    }

    func testQueueClearsOnClose() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        try await stall(s1, conn, t)
        conn.send(Array("x".utf8)[...])
        XCTAssertEqual(conn.queuedByteCount, 1)

        conn.close()
        XCTAssertEqual(conn.queuedByteCount, 0)
        conn.send(Array("y".utf8)[...])
        XCTAssertEqual(conn.queuedByteCount, 0, "a closed session queues nothing")

        // The attach that was in flight must not come back to life.
        t.release()
        try await waitUntil("parked attach returned") { t.streams.count == 2 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(t.streams[1].closed, "attach finished after close left a live connection")
        XCTAssertEqual(t.streams[1].sent, [])
    }

    func testQueueClearsWhenTheSessionEnds() async throws {
        let (conn, t) = make()
        conn.start(cols: 80, rows: 24)
        try await waitUntil("attach") { t.streams.count == 1 }
        conn.send(Array("x".utf8)[...])   // before the session showed output: held
        XCTAssertEqual(conn.queuedByteCount, 1)

        t.streams[0].exit()
        try await waitUntil("ended") { conn.state == .ended }
        XCTAssertEqual(conn.queuedByteCount, 0)
        conn.send(Array("z".utf8)[...])
        XCTAssertEqual(conn.queuedByteCount, 0)
    }

    /// #223: once the backoff gives up, `retry()` runs the attach loop again and the
    /// session comes back live; in any other state it does nothing.
    func testRetryAfterFailedReattaches() async throws {
        let t = DeliveryTransport()
        let conn = SessionConnection(transport: t, session: DchSession(name: "t", alias: nil),
                                     backoff: BackoffPolicy(maxAttempts: 0))
        conn.onBytes = { _ in }
        let s1 = try await startLive(conn, t)
        conn.retry()
        XCTAssertEqual(t.streams.count, 1, "retry while connected must not attach again")

        s1.drop()
        try await waitUntil("failed") { if case .failed = conn.state { true } else { false } }
        XCTAssertEqual(t.streams.count, 1)

        conn.retry()
        try await waitUntil("reattach") { t.streams.count == 2 }
        let s2 = t.streams[1]
        s2.emit("$ ")
        try await waitUntil("connected") { conn.state == .connected }
        conn.send(Array("a".utf8)[...])
        try await waitUntil("live input") { s2.text == "a" }

        conn.close()
        conn.retry()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(t.streams.count, 2, "retry after close must stay closed")
    }

    func testRetryAfterCloseWhileFailedStaysFailed() async throws {
        let t = DeliveryTransport()
        let conn = SessionConnection(transport: t, session: DchSession(name: "t", alias: nil),
                                     backoff: BackoffPolicy(maxAttempts: 0))
        conn.onBytes = { _ in }
        let s1 = try await startLive(conn, t)
        s1.drop()
        try await waitUntil("failed") { if case .failed = conn.state { true } else { false } }

        conn.close()
        conn.retry()
        if case .failed = conn.state {} else { XCTFail("retry after close moved the state to \(conn.state)") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.streams.count, 1, "closed session must not reattach")
    }

    func testRetryRestartsTheBackoffCount() async throws {
        let t = DeliveryTransport()
        let conn = SessionConnection(transport: t, session: DchSession(name: "t", alias: nil),
                                     backoff: BackoffPolicy(base: [0], cap: 0, maxAttempts: 2))
        conn.onBytes = { _ in }
        let s1 = try await startLive(conn, t)
        t.failAttaches = true
        s1.drop()
        try await waitUntil("failed") { if case .failed = conn.state { true } else { false } }
        XCTAssertEqual(t.calls, 3, "first attach + maxAttempts failing reattaches")

        conn.retry()
        try await waitUntil("failed again") { t.calls == 6 && { if case .failed = conn.state { true } else { false } }() }
        XCTAssertEqual(t.calls, 6, "retry gets the full 1 + maxAttempts again, no attach succeeding in between")
    }

    /// Past the cap the OLDEST whole frames go; the frames that fit arrive intact, none cut.
    func testCapDropsTheOldestWholeFrames() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        try await stall(s1, conn, t)
        let all = (0..<70_000).map { UInt8($0 % 251) }
        stride(from: 0, to: all.count, by: 1000).forEach {
            conn.send(all[$0..<min($0 + 1000, all.count)])
        }
        let kept = SessionConnection.outboxCap / 1000 * 1000   // 65 whole frames
        XCTAssertEqual(conn.queuedByteCount, kept)

        let s2 = try await reattachLive(conn, t, index: 1)
        try await waitUntil("flush") { s2.bytes.count == kept }
        XCTAssertEqual(s2.bytes, Array(all.suffix(kept)))
        XCTAssertTrue(s2.sent.allSatisfy { if case .bytes(let b) = $0 { b.count == 1000 } else { false } },
                      "a frame was cut")
    }

    /// #229: a paste over the cap, sent while offline, is refused up front with a notice.
    /// Queued, it could only survive until the next frame behind it, then vanish silently.
    func testPasteOverTheCapWhileOfflineIsRefusedWithANotice() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        try await stall(s1, conn, t)
        conn.send(Array("x".utf8)[...])
        let paste = TerminalMath.pasteBytes(String(repeating: "echo hi\n", count: 9000))
        XCTAssertGreaterThan(paste.count, SessionConnection.outboxCap)
        conn.send(paste[...])
        XCTAssertEqual(conn.queuedByteCount, 1, "over-cap paste was queued (or evicted what was)")
        XCTAssertEqual(conn.notice, "Paste too large to send while offline (71 KB)")

        conn.send(Array("y".utf8)[...])
        XCTAssertNil(conn.notice, "the next accepted write clears the notice")
        let s2 = try await reattachLive(conn, t, index: 1)
        try await waitUntil("flush") { s2.text == "xy" }
    }

    /// A paste just under the cap, queued during a stall, arrives whole with its brackets.
    func testPasteJustUnderTheCapArrivesWholeWithItsBrackets() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        try await stall(s1, conn, t)
        let wrap = TerminalMath.pasteBytes("").count
        let paste = TerminalMath.pasteBytes(String(repeating: "a", count: SessionConnection.outboxCap - wrap))
        XCTAssertEqual(paste.count, SessionConnection.outboxCap)
        conn.send(paste[...])
        XCTAssertEqual(conn.queuedByteCount, paste.count)
        XCTAssertNil(conn.notice)

        let s2 = try await reattachLive(conn, t, index: 1)
        try await waitUntil("flush") { s2.bytes.count == paste.count }
        XCTAssertEqual(Array(s2.bytes.prefix(6)), Array("\u{1b}[200~".utf8), "paste opener lost")
        XCTAssertEqual(s2.bytes, paste)
    }

    /// Live with nothing queued, the cap does not apply: an over-cap paste streams.
    func testPasteOverTheCapStreamsWhenLive() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        let paste = TerminalMath.pasteBytes(String(repeating: "echo hi\n", count: 9000))
        conn.send(paste[...])
        XCTAssertEqual(s1.bytes, paste)
        XCTAssertNil(conn.notice)
    }

    /// QA #9: the link flaps twice. Stream A hands back a and b; stream B takes a, dies
    /// before b and hands a back. a must go back ahead of b: the next stream sees "ab".
    func testHandBackAfterAPartialFlushGoesToTheFront() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        conn.send(Array("a".utf8)[...]); conn.send(Array("b".utf8)[...])
        XCTAssertEqual(s1.text, "ab")

        s1.accepting = false
        s1.bounce(.bytes(Array("a".utf8))); s1.bounce(.bytes(Array("b".utf8)))
        try await stall(s1, conn, t)
        try await waitUntil("both handed back") { conn.queuedByteCount == 2 }

        t.release()
        try await waitUntil("reattach") { t.streams.count == 2 }
        let s2 = t.streams[1]
        s2.acceptLimit = 1
        s2.emit("$ ")
        try await waitUntil("partial flush") { s2.text == "a" }
        s2.bounce(.bytes(Array("a".utf8)))   // B never got "a" onto the wire
        try await waitUntil("a handed back") { conn.queuedByteCount == 2 }
        s2.drop()

        try await waitUntil("third attach") { t.streams.count == 3 }
        let s3 = t.streams[2]
        s3.emit("$ ")
        try await waitUntil("flush") { s3.text.count == 2 }
        XCTAssertEqual(s3.text, "ab", "handed-back frames reordered")
    }

    /// #230: ProsperStream's 1 s close failsafe can end stream A before its hand-back
    /// arrives. Once stream B has taken the user's next key, A's late hand-back can't go
    /// ahead of it any more; sent behind it the host would see "ka". It is dropped — a
    /// keystroke silently, a paste with a notice.
    func testLateHandBackFromAnOlderStreamIsDroppedOnceTheNextStreamSent() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        conn.send(Array("a".utf8)[...])
        XCTAssertEqual(s1.text, "a")
        try await stall(s1, conn, t)          // A ends with "a"'s completion still pending
        let s2 = try await reattachLive(conn, t, index: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        conn.send(Array("k".utf8)[...])
        XCTAssertEqual(s2.text, "k")

        s1.bounce(.bytes(Array("a".utf8)))   // A's late hand-back
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(s2.text, "k", "late hand-back sent behind newer input")
        XCTAssertEqual(conn.queuedByteCount, 0)
        XCTAssertNil(conn.notice, "a dropped keystroke is silent")

        let paste = TerminalMath.pasteBytes("echo hi\n")
        s1.bounce(.bytes(paste))
        try await waitUntil("paste notice") { conn.notice != nil }
        XCTAssertEqual(conn.notice, "Paste lost in reconnect, paste again")
        conn.send(Array("l".utf8)[...])
        XCTAssertEqual(s2.text, "kl")
        XCTAssertEqual(conn.notice, "Paste lost in reconnect, paste again",
                       "typing on cleared the lost-paste notice before the user could read it")
    }

    /// #241 L2: a dropped hand-back is a paste by its ESC[200~ opener, not by its size.
    func testLateHandBackIsClassifiedByThePasteOpenerNotSize() async throws {
        let keys = Array("\u{1b}[A\u{1b}[A\u{1b}[A\u{1b}[Aabcd".utf8)   // 16 bytes, no opener
        let paste = TerminalMath.pasteBytes("abc")                           // 15 bytes framed
        for (frame, expected) in [(keys, nil), (paste, "Paste lost in reconnect, paste again")] {
            let (conn, t) = make()
            let s1 = try await startLive(conn, t)
            try await stall(s1, conn, t)
            let s2 = try await reattachLive(conn, t, index: 1)
            try await Task.sleep(nanoseconds: 50_000_000)
            conn.send(Array("k".utf8)[...])
            XCTAssertEqual(s2.text, "k")

            s1.bounce(.bytes(frame))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(conn.notice, expected, "\(frame.count)-byte frame misclassified")
            conn.close()
        }
    }

    /// #241 QA: unwrapped text (SwiftTerm paste with stale bracketed mode, dictation, IME,
    /// scroll burst) over 16 bytes gets its own notice; a key sequence stays silent.
    func testLostNoticeClassifiesByOpenerThenSize() {
        let plain = { (n: Int) in Outbound.bytes(Array(repeating: UInt8(ascii: "x"), count: n)) }
        XCTAssertEqual(SessionConnection.lostNotice(for: .bytes(TerminalMath.pasteBytes("abc"))),
                       "Paste lost in reconnect, paste again")
        XCTAssertEqual(SessionConnection.lostNotice(for: plain(40)), "Typed text lost in reconnect, type it again")
        XCTAssertEqual(SessionConnection.lostNotice(for: plain(17)), "Typed text lost in reconnect, type it again")
        XCTAssertNil(SessionConnection.lostNotice(for: plain(16)))
        let arrows = Array(String(repeating: "\u{1b}[A", count: 10).utf8)          // 30 bytes
        let mouse = Array(String(repeating: "\u{1b}[<64;1;1M", count: 10).utf8)    // 100 bytes
        XCTAssertEqual(arrows.count, 30); XCTAssertEqual(mouse.count, 100)
        XCTAssertNil(SessionConnection.lostNotice(for: .bytes(arrows)), "a scroll burst of arrows is not typed text")
        XCTAssertNil(SessionConnection.lostNotice(for: .bytes(mouse)), "an SGR mouse burst is not typed text")
        XCTAssertEqual(SessionConnection.lostNotice(for: .clipboard(Data([1]))), "Image paste lost in reconnect, paste again")
    }

    /// #241 (f): a late clipboard hand-back is an image paste lost: notice, sticky past typing.
    func testLateClipboardHandBackShowsTheImageNotice() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        conn.putClipboard(png)
        XCTAssertEqual(s1.sent, [.clipboard(png)])
        try await stall(s1, conn, t)
        let s2 = try await reattachLive(conn, t, index: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        conn.send(Array("k".utf8)[...])
        XCTAssertEqual(s2.text, "k")

        s1.bounce(.clipboard(png))
        try await waitUntil("image notice") { conn.notice != nil }
        XCTAssertEqual(conn.notice, "Image paste lost in reconnect, paste again")
        XCTAssertEqual(s2.sent, [.bytes(Array("k".utf8))], "late clipboard sent behind newer input")
        conn.send(Array("l".utf8)[...])
        XCTAssertEqual(conn.notice, "Image paste lost in reconnect, paste again", "typing cleared the image notice")
    }

    /// #241: an accepted LIVE write clears the refusal notice, not just a queued one.
    func testAcceptedLiveWriteClearsTheRefusalNotice() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        try await stall(s1, conn, t)
        conn.send(TerminalMath.pasteBytes(String(repeating: "a", count: SessionConnection.outboxCap))[...])
        XCTAssertNotNil(conn.notice)
        let s2 = try await reattachLive(conn, t, index: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        conn.send(Array("y".utf8)[...])
        XCTAssertEqual(s2.text, "y", "went out live")
        XCTAssertNil(conn.notice, "an accepted live write left the refusal notice up")
    }

    /// #241: a second refusal restarts the notice's life instead of inheriting the first one's.
    func testASecondRefusalRestartsTheNoticeTimer() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        try await stall(s1, conn, t)
        let paste = TerminalMath.pasteBytes(String(repeating: "a", count: SessionConnection.outboxCap))
        conn.send(paste[...])
        try await Task.sleep(for: .milliseconds(2500))
        conn.send(paste[...])
        try await Task.sleep(for: .milliseconds(2500))   // 5 s after the first, 2.5 s after the second
        XCTAssertNotNil(conn.notice, "the first refusal's timer cleared the second notice early")
        try await waitUntil("expiry", timeout: 3) { conn.notice == nil }
    }

    /// #241: the backoff giving up while a notice is up clears it, so the tappable retry
    /// capsule (statusChip prefers the notice) is never hidden.
    func testEnteringFailedClearsTheNotice() async throws {
        let t = DeliveryTransport()
        let conn = SessionConnection(transport: t, session: DchSession(name: "t", alias: nil),
                                     backoff: BackoffPolicy(base: [0], cap: 0, maxAttempts: 1))
        conn.onBytes = { _ in }
        let s1 = try await startLive(conn, t)
        try await stall(s1, conn, t)
        conn.send(TerminalMath.pasteBytes(String(repeating: "a", count: SessionConnection.outboxCap))[...])
        XCTAssertNotNil(conn.notice)
        t.failAttaches = true
        t.release()
        try await waitUntil("failed") { if case .failed = conn.state { true } else { false } }
        XCTAssertNil(conn.notice, "a notice is hiding the Tap-to-retry capsule")
    }

    /// Image paste during a drop: the clipboard must still land before the ctrl-V.
    func testClipboardStaysAheadOfItsKeystrokeAcrossADrop() async throws {
        let (conn, t) = make()
        let s1 = try await startLive(conn, t)
        try await stall(s1, conn, t)
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        conn.putClipboard(png)
        conn.send([0x16][...])

        let s2 = try await reattachLive(conn, t, index: 1)
        try await waitUntil("flush") { s2.sent.count == 2 }
        XCTAssertEqual(s2.sent, [.clipboard(png), .bytes([0x16])])
    }

    /// A session that never writes still gets its input, after the fallback.
    func testSilentSessionGetsInputAfterTheFallback() async throws {
        let (conn, t) = make()
        conn.start(cols: 80, rows: 24)
        try await waitUntil("attach") { t.streams.count == 1 }
        conn.send(Array("q".utf8)[...])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(t.streams[0].text, "")
        try await waitUntil("fallback flush") { t.streams[0].text == "q" }
    }

    func testDemoSessionStillEchoesTyping() async throws {
        let conn = SessionConnection(transport: DemoTransport(),
                                     session: DchSession(name: "demo", alias: nil))
        var out = [UInt8]()
        conn.onBytes = { out.append(contentsOf: $0) }
        conn.start(cols: 80, rows: 24)
        conn.send(Array("hi\r".utf8)[...])   // typed before the demo's first output
        try await waitUntil("demo reply") {
            String(decoding: out, as: UTF8.self).contains("\u{2018}hi\u{2019}")
        }
        conn.close()
    }

    /// The real stream: once the server hangs up, input is refused (so the caller keeps
    /// it) instead of vanishing into a cancelled NWConnection.
    func testProsperStreamRefusesInputOnceTheLinkIsGone() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { c in
            c.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { c.cancel() }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }
        try await waitUntil("listener") { (listener.port?.rawValue ?? 0) != 0 }

        let stream = try await ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue)
            .attach(name: "t", cols: 80, rows: 24)
        XCTAssertTrue(stream.send([0x61][...]), "a live stream must take input")
        for await _ in stream.output {}   // ends when the server hangs up
        XCTAssertFalse(stream.send([0x62][...]), "a dead stream swallowed input")
        XCTAssertFalse(stream.putClipboard(Data([1])))
    }
}

// MARK: - Fakes

/// Hands out a fresh stream per attach; `hold` parks the next attach until `release`;
/// `failAttaches` makes every attach throw (a parked one once released). `calls` counts attach attempts.
@MainActor
final class DeliveryTransport: SessionTransport {
    var streams: [DeliveryStream] = []
    var hold = false
    var failAttaches = false
    private(set) var calls = 0
    private(set) var parked = false
    private var gate: CheckedContinuation<Void, Never>?

    func listSessions() async throws -> [DchSession] { [] }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream {
        calls += 1
        if hold {
            parked = true
            await withCheckedContinuation { gate = $0 }
            parked = false
        }
        if failAttaches { throw TransportError.notConnected }   // after the hold: a parked attach can fail
        let s = DeliveryStream()
        streams.append(s)
        return s
    }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
        try await attach(name: name ?? "", cols: cols, rows: rows)
    }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}

    func release() {
        hold = false
        gate?.resume()
        gate = nil
    }
}

final class DeliveryStream: TerminalStream {
    let output: AsyncStream<ArraySlice<UInt8>>
    private let cont: AsyncStream<ArraySlice<UInt8>>.Continuation
    private(set) var exited = false
    private(set) var closed = false
    var accepting = true
    /// Refuse input after this many accepted writes (a link dying mid-flush).
    var acceptLimit = Int.max
    private(set) var sent: [Outbound] = []
    var onScreen: ((ArraySlice<UInt8>) -> Void)?
    var onUnsent: ((Outbound) -> Void)?

    init() {
        var c: AsyncStream<ArraySlice<UInt8>>.Continuation!
        output = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        cont = c
    }

    private func take(_ out: Outbound) -> Bool {
        guard accepting, !closed, sent.count < acceptLimit else { return false }
        sent.append(out)
        return true
    }
    func send(_ bytes: ArraySlice<UInt8>) -> Bool { take(.bytes(Array(bytes))) }
    func putClipboard(_ image: Data) -> Bool { take(.clipboard(image)) }
    func resize(cols: Int, rows: Int) {}
    func requestRedraw() {}
    func requestSnapshot() {}
    func close() { closed = true; cont.finish() }

    func emit(_ text: String) { cont.yield(ArraySlice(Array(text.utf8))) }
    func drop() { accepting = false; cont.finish() }
    func exit() { exited = true; drop() }
    func bounce(_ out: Outbound) { onUnsent?(out) }

    var bytes: [UInt8] {
        sent.flatMap { if case .bytes(let b) = $0 { return b } else { return [] } }
    }
    var text: String { String(decoding: bytes, as: UTF8.self) }
}
