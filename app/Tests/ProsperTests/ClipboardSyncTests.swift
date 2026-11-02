import XCTest
import Network
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import Prosper

/// #621: the clipboard history both ways with the Mac: paging the Mac's list, its watermark,
/// pulls (cut text whole, images sha-checked), what is skipped, dedupe, the phone's clips up
/// in batches and images one per connection, the gate, and an index from before. A fake Mac
/// in memory for the sync, a loopback one for the wire; a throwaway store and defaults.
@MainActor
final class ClipboardSyncTests: XCTestCase {
    private var dir: URL!
    private var pb: UIPasteboard!
    private var suite = ""
    private var defaults: UserDefaults!
    private let machine = "machine-a"
    /// A recent minute: well inside the store's `maxAge`.
    private let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 - 3600)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardSyncTests-\(UUID())")
        pb = UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true)
        suite = "ClipboardSyncTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        UIPasteboard.remove(withName: pb.name)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func sync(_ fake: ClipFake, _ h: ClipboardHistory) async throws {
        try await ClipboardSync.sync(over: fake, machine: machine, history: h, defaults: defaults)
    }

    /// A Mac text row `ago` seconds before `base`, its list text cut at 2000 as the Mac's.
    private func macText(_ text: String, ago: TimeInterval, source: String = "Mac") -> ClipFake.Item {
        ClipFake.Item(row: ClipboardRow(id: UUID().uuidString, date: ClipboardRow.wire(base - ago), kind: "text", source: source,
                                        text: String(text.prefix(2000)), size: text.utf8.count), data: Data(text.utf8))
    }

    private func png(_ w: CGFloat, _ h: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).pngData { c in
            UIColor.systemOrange.setFill()
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            UIColor.systemBlue.setFill()
            c.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 3))
        }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Mac to phone

    func testListPagesUntilEmptyAndTheWatermarkStopsARepull() async throws {
        let h = ClipboardHistory(dir: dir)
        let fake = ClipFake()
        fake.pageMax = 2   // the Mac halves a page past 8 MB: short pages aren't the end
        fake.items = (0..<5).map { macText("mac \($0)", ago: Double($0) * 60) }
        try await sync(fake, h)
        let ids = fake.items.map(\.row.id)
        XCTAssertEqual(fake.lists.map(\.before), [nil, ids[1], ids[3], ids[4]], "on with `before` until []")
        XCTAssertEqual(fake.lists.map(\.since), [nil, nil, nil, nil], "the first sync has no watermark")
        XCTAssertEqual(h.clips.map(\.text), ["mac 0", "mac 1", "mac 2", "mac 3", "mac 4"])
        XCTAssertEqual(Set(h.clips.map(\.source)), [ClipboardHistory.mac])
        XCTAssertEqual(h.clips[0].date.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 0.001, "at the Mac's date")
        XCTAssertEqual(fake.pulls, [], "whole text comes with the list")
        XCTAssertEqual(fake.batches, [], "the Mac's clips never go back")

        h.clear()
        try await sync(fake, h)
        XCTAssertEqual(fake.lists.last?.since, fake.items[0].row.date, "the newest row seen is the next `since`")
        XCTAssertEqual(h.clips, [], "what the phone deleted doesn't come again")

        fake.items.insert(macText("mac new", ago: -30), at: 0)
        try await sync(fake, h)
        XCTAssertEqual(h.clips.map(\.text), ["mac new"])
        XCTAssertEqual(fake.lists.last?.since, fake.items[1].row.date)
    }

    func testFirstSyncReadsAStoresWorthOnly() async throws {
        let h = ClipboardHistory(dir: dir, cap: 3)
        let fake = ClipFake()
        fake.pageMax = 2
        fake.items = (0..<10).map { macText("mac \($0)", ago: Double($0) * 60) }
        try await sync(fake, h)
        XCTAssertEqual(fake.lists.count, 2, "4 rows cover a cap of 3")
        XCTAssertEqual(h.clips.map(\.text), ["mac 0", "mac 1", "mac 2"])
    }

    func testCutTextIsPulledWholeAndFilesLongTextAndPhoneRowsAreSkipped() async throws {
        let h = ClipboardHistory(dir: dir)
        let fake = ClipFake()
        let cut = String(repeating: "lorem ipsum ", count: 500)            // 6000 chars: the list has 2000
        let long = String(repeating: "x", count: ClipboardHistory.textLimit + 1)   // pulled, then over the limit
        let huge = String(repeating: "y", count: 3 * ClipboardHistory.textLimit + 1)   // never pulled
        fake.items = [macText(cut, ago: 0), macText(long, ago: 10), macText(huge, ago: 20),
                      ClipFake.Item(row: ClipboardRow(id: UUID().uuidString, date: ClipboardRow.wire(base - 30), kind: "file",
                                                      text: nil, size: 10), data: Data(count: 10)),
                      macText("sent from a phone", ago: 40, source: "iPhone")]
        try await sync(fake, h)
        XCTAssertEqual(fake.pulls, [fake.items[0].row.id, fake.items[1].row.id])
        XCTAssertEqual(h.clips.map(\.text), [cut])
        try await sync(fake, h)
        XCTAssertEqual(fake.lists.last?.since, fake.items[0].row.date, "skipped rows don't hold the watermark")
        XCTAssertEqual(fake.pulls.count, 2, "nor are they pulled again")
    }

    func testImagesArePulledShaCheckedAndDownsampled() async throws {
        let h = ClipboardHistory(dir: dir)
        let fake = ClipFake()
        let data = png(2000, 1000)
        func image(_ ago: TimeInterval, size: Int? = nil) -> ClipFake.Item {
            ClipFake.Item(row: ClipboardRow(id: UUID().uuidString, date: ClipboardRow.wire(base - ago), kind: "image",
                                            size: size ?? data.count), data: data)
        }
        fake.items = [image(0), image(10), image(20, size: ClipboardSync.imageMax + 1)]
        fake.badSha = [fake.items[1].row.id]
        try await sync(fake, h)
        XCTAssertEqual(fake.pulls, [fake.items[0].row.id, fake.items[1].row.id], "none over imageMax")
        XCTAssertEqual(h.clips.count, 1, "a sha mismatch is rejected")
        let clip = try XCTUnwrap(h.clips.first)
        XCTAssertEqual(clip.source, ClipboardHistory.mac)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(h.url(try XCTUnwrap(clip.image)) as CFURL, nil))
        let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 1024, "downsampled as the store keeps images")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(files, [clip.image!, "index.json"].sorted(), "no stray file")
    }

    /// About 900 KB of noise as a PNG: a downsampled reply, still a real image.
    private func noisePNG(_ side: Int = 560) -> Data {
        var bytes = (0..<side * side * 4).map { _ in UInt8.random(in: 0...255) }
        let ctx = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return UIImage(cgImage: ctx.makeImage()!).pngData()!
    }

    /// #712: a 35 MB original over `imageMax` is pulled once the Mac sends it smaller; without
    /// max_side it is skipped unpulled, as before.
    func testAnImageOverImageMaxIsPulledOnlyWithMaxSide() async throws {
        let reply = noisePNG()
        XCTAssertTrue((500_000...ClipboardSync.imageMax).contains(reply.count), "\(reply.count)")
        func run(_ maxSide: Int?) async throws -> (ClipFake, ClipboardHistory) {
            let h = ClipboardHistory(dir: dir.appendingPathComponent("\(maxSide ?? 0)"))
            let fake = ClipFake()
            fake.items = [ClipFake.Item(row: ClipboardRow(id: UUID().uuidString, date: ClipboardRow.wire(base), kind: "image",
                                                          size: 35 << 20), data: reply)]
            try await ClipboardSync.sync(over: fake, machine: "m\(maxSide ?? 0)", history: h, maxSide: maxSide, defaults: defaults)
            return (fake, h)
        }
        let (with, h1) = try await run(ClipboardSync.sideMax)
        XCTAssertEqual(with.maxSides, [1024])
        XCTAssertEqual(h1.clips.count, 1, "the smaller reply lands")
        XCTAssertEqual(h1.clips.first?.source, ClipboardHistory.mac)
        let (without, h2) = try await run(nil)
        XCTAssertEqual(without.pulls, [], "an older Mac: over imageMax, never pulled")
        XCTAssertEqual(h2.clips.count, 0)
    }

    /// #712: an original the Mac couldn't re-encode comes back whole; a header over `imageMax`
    /// skips that row only: the rest are pulled, the sync ends and `since` moves.
    func testAReplyOverImageMaxIsASkipNotAStop() async throws {
        let h = ClipboardHistory(dir: dir)
        let fake = ClipFake()
        let gif = Data(count: ClipboardSync.imageMax + 1)
        fake.items = [ClipFake.Item(row: ClipboardRow(id: UUID().uuidString, date: ClipboardRow.wire(base), kind: "image",
                                                      size: gif.count), data: gif),
                      ClipFake.Item(row: ClipboardRow(id: UUID().uuidString, date: ClipboardRow.wire(base - 10), kind: "image",
                                                      size: 1 << 20), data: png(2000, 1000))]
        try await ClipboardSync.sync(over: fake, machine: machine, history: h, maxSide: ClipboardSync.sideMax, defaults: defaults)
        XCTAssertEqual(fake.pulls, fake.items.map(\.row.id), "the later row still pulled")
        XCTAssertEqual(h.clips.count, 1, "only the one that fit")
        XCTAssertEqual(try state().since, fake.items[0].row.date, "the sync got to the end")
        XCTAssertEqual(try state().pulled, [])
        try await ClipboardSync.sync(over: fake, machine: machine, history: h, maxSide: ClipboardSync.sideMax, defaults: defaults)
        XCTAssertEqual(fake.pulls.count, 2, "not pulled again")
    }

    func testSameContentIsOneRowTakingTheNewerDate() async throws {
        let h = ClipboardHistory(dir: dir)
        h.now = { self.base - 600 }
        pb.string = "alpha"
        h.record("alpha", from: pb)
        h.now = { self.base }
        let fake = ClipFake()
        fake.items = [macText("gamma", ago: -3600), macText("alpha", ago: 60), macText("beta", ago: 1200)]
        try await sync(fake, h)
        XCTAssertEqual(h.clips.map(\.text), ["gamma", "alpha", "beta"])
        XCTAssertEqual(h.clips.map(\.source), [ClipboardHistory.mac, nil, ClipboardHistory.mac], "alpha stays the phone's")
        XCTAssertEqual(h.clips[0].date, base, "a date ahead of the phone's clock is now")
        XCTAssertEqual(h.clips[1].date.timeIntervalSince1970, (base - 60).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(fake.batches.map { $0.map(\.text) }, [["alpha"]], "only the phone's own goes up")
    }

    // MARK: Phone to Mac

    func testPhoneTextGoesUpInBatchesAndASkippedDuplicateIsDone() async throws {
        let h = ClipboardHistory(dir: dir, cap: 200)
        h.merge((0..<150).map { ClipboardHistory.Clip(text: "clip \($0)", date: base - Double($0)) })
        let fake = ClipFake()
        fake.reasons = ["clip 0": "duplicate", "clip 1": "write_failed"]
        try await sync(fake, h)
        XCTAssertEqual(fake.batches.map(\.count), [100, 50])
        XCTAssertEqual(fake.batches[0][0], ClipboardText(id: h.clips[0].id, date: base, text: "clip 0"))
        try await sync(fake, h)
        XCTAssertEqual(fake.batches.count, 3)
        XCTAssertEqual(fake.batches[2].map(\.text), ["clip 1"], "a failed write goes again; a duplicate is done")
        fake.reasons = [:]
        try await sync(fake, h)
        try await sync(fake, h)
        XCTAssertEqual(fake.batches.count, 4, "sent once taken")
    }

    func testAnImageGoesUpOnceAndNoSpaceAgain() async throws {
        let h = ClipboardHistory(dir: dir)
        let name = try XCTUnwrap(h.storeImage(data: png(300, 200)))
        h.merge([ClipboardHistory.Clip(image: name, date: base)])
        let fake = ClipFake()
        let id = h.clips[0].id
        fake.uploadReply = ClipboardSent(skipped: [id.uuidString: "no_space"])
        try await sync(fake, h)
        fake.uploadReply = nil
        try await sync(fake, h)
        try await sync(fake, h)
        XCTAssertEqual(fake.uploads.count, 2, "no_space again, then taken once")
        XCTAssertEqual(fake.uploads[1], ClipboardUpload(id: id, date: base, data: try Data(contentsOf: h.url(name)), mime: "image/jpeg"))
        XCTAssertEqual(fake.batches, [])
    }

    func testConcealedClipsNeverReachTheMac() async throws {
        let h = ClipboardHistory(dir: dir)
        pb.setItems([[UTType.utf8PlainText.identifier: "s3cret", "org.nspasteboard.ConcealedType": Data()]])
        h.record("s3cret", from: pb)
        pb.setItems([[UTType.utf8PlainText.identifier: "0tp", "org.nspasteboard.TransientType": Data()]])
        h.save(pb)
        let fake = ClipFake()
        try await sync(fake, h)
        XCTAssertEqual(h.clips, [])
        XCTAssertEqual(fake.batches, [])
        XCTAssertEqual(fake.uploads, [])
    }

    func testAnIndexFromBeforeTheSourceStillReadsAndGoesUp() async throws {
        let id = UUID()
        let date = (base - 60).timeIntervalSinceReferenceDate
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"clips":[{"id":"\#(id.uuidString)","text":"old","date":\#(date),"pinned":true}],"change":7}"#.utf8)
            .write(to: dir.appendingPathComponent("index.json"))
        let h = ClipboardHistory(dir: dir)
        XCTAssertEqual(h.clips, [ClipboardHistory.Clip(id: id, text: "old", date: Date(timeIntervalSinceReferenceDate: date), pinned: true)])
        let fake = ClipFake()
        try await sync(fake, h)
        XCTAssertEqual(fake.batches.map { $0.map(\.text) }, [["old"]])
    }

    // MARK: The gate

    func testNothingWithTheToggleOffOrWithoutTheOp() async throws {
        let saved = KeyboardSettings.store
        KeyboardSettings.store = { self.defaults }
        let h = ClipboardHistory(dir: dir)
        ClipboardSync.history = { h }
        defer {
            ClipboardSync.offer([], over: ClipFake(), machine: machine)
            ClipboardSync.history = { ClipboardHistory.shared() }
            KeyboardSettings.store = saved
        }
        pb.string = "alpha"
        h.record("alpha", from: pb)
        let fake = ClipFake()

        ClipboardSync.offer([.library, .history], over: fake, machine: machine)
        XCTAssertNil(ClipboardSync.mac, "no clipboard op: no Mac to sync with")
        ClipboardSync.kick()
        defaults.set(false, forKey: ClipboardSync.key)
        ClipboardSync.offer([.clipboard], over: fake, machine: machine)
        try await sync(fake, h)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.calls, 0, "toggle off")

        defaults.set(true, forKey: ClipboardSync.key)
        ClipboardSync.kick()
        try await waitUntil("synced") { !ClipboardSync.running && fake.calls > 0 }
        XCTAssertEqual(fake.batches.map { $0.map(\.text) }, [["alpha"]])
    }

    /// #712: max_side 1024 on each pull only while the Mac lists clipboard_max_side, and that
    /// only with clipboard; an older Mac's pull is as before.
    func testMaxSideOnlyWhenTheMacListsItWithClipboard() async throws {
        let saved = KeyboardSettings.store
        KeyboardSettings.store = { self.defaults }
        let h = ClipboardHistory(dir: dir)
        ClipboardSync.history = { h }
        defer {
            ClipboardSync.offer([], over: ClipFake(), machine: machine)
            ClipboardSync.history = { ClipboardHistory.shared() }
            KeyboardSettings.store = saved
        }
        func pulled(_ ops: [String], _ m: String) async throws -> [Int?] {
            let fake = ClipFake()
            let data = png(2000, 1000)
            fake.items = [ClipFake.Item(row: ClipboardRow(id: UUID().uuidString, date: ClipboardRow.wire(base), kind: "image",
                                                          size: data.count), data: data)]
            ClipboardSync.offer(SessionVerb.offered(ops), over: fake, machine: m)
            try await waitUntil("synced \(ops)") { !ClipboardSync.running && !fake.pulls.isEmpty }
            return fake.maxSides
        }
        let old = try await pulled(["clipboard"], "older")
        XCTAssertEqual(old, [nil], "an older Mac: no max_side")
        let new = try await pulled(["clipboard", "clipboard_max_side"], "newer")
        XCTAssertEqual(new, [1024], "the store's long side")
        ClipboardSync.offer(SessionVerb.offered(["clipboard_max_side"]), over: ClipFake(), machine: machine)
        XCTAssertNil(ClipboardSync.mac, "clipboard_max_side alone syncs nothing")
    }

    // MARK: The wire

    /// A loopback Mac: `answer` sees each connection's frames as they arrive, with that
    /// connection's raw send.
    private func state() throws -> ClipboardSync.State {
        try JSONDecoder().decode(ClipboardSync.State.self, from: try XCTUnwrap(defaults.data(forKey: "clipboard.sync." + machine)))
    }

    /// #705: switching away cut every run mid-pull, so nothing landed, nothing went up and each
    /// run started over. The phone's go first, each pull lands as it comes, and the next run
    /// goes on past them; `since` moves only at the end.
    func testACutRunKeepsItsPullsHasSentThePhonesAndTheNextGoesOn() async throws {
        let h = ClipboardHistory(dir: dir)
        h.merge([ClipboardHistory.Clip(text: "phone 0", date: base - 7200), ClipboardHistory.Clip(text: "phone 1", date: base - 7260)])
        let fake = ClipFake()
        let texts = (0..<4).map { String(repeating: "mac \($0) ", count: 400) }   // over the list's 2000: each one pulled
        fake.items = texts.enumerated().map { macText($1, ago: Double($0) * 60) }
        let ids = fake.items.map(\.row.id)
        fake.onPull = { if $0 == 3 { throw TransportError.hostUnreachable("mac") } }
        do { try await sync(fake, h); XCTFail("the third pull's error ends the run") } catch {}
        XCTAssertEqual(fake.batches.map { $0.map(\.text) }, [["phone 0", "phone 1"]], "the phone's went up before any pull")
        XCTAssertEqual(fake.pulls, Array(ids.prefix(3)))
        XCTAssertEqual(h.clips.compactMap(\.text), [texts[0], texts[1], "phone 0", "phone 1"], "the first two pulls stay")
        XCTAssertNil(try state().since, "a cut run doesn't move the watermark")
        XCTAssertEqual(try state().pulled, Array(ids.prefix(2)))

        fake.onPull = nil
        defaults = UserDefaults(suiteName: suite)   // a fresh read: only what was saved goes on
        try await sync(fake, h)
        XCTAssertEqual(fake.pulls, Array(ids.prefix(3)) + Array(ids.suffix(2)), "the two that landed aren't pulled again")
        XCTAssertEqual(h.clips.compactMap(\.text), texts + ["phone 0", "phone 1"])
        XCTAssertEqual(fake.batches.count, 1, "nor are the phone's sent again")
        XCTAssertEqual(try state(), ClipboardSync.State(since: fake.items[0].row.date, sent: h.clips.suffix(2).map(\.id)), "at the end: `since`, no pulled")

        try await sync(fake, h)
        XCTAssertEqual(fake.lists.last?.since, fake.items[0].row.date)
        XCTAssertEqual(fake.pulls.count, 5)
    }

    func testTheStateRoundTripsAndOneSavedBeforePulledStillReads() throws {
        let state = ClipboardSync.State(since: "2026-11-02T10:00:00.000Z", sent: [UUID()], pulled: ["A", "B"])
        XCTAssertEqual(try JSONDecoder().decode(ClipboardSync.State.self, from: JSONEncoder().encode(state)), state)
        let id = UUID()
        let old = Data(#"{"since":"2026-11-02T10:00:00.000Z","sent":["\#(id.uuidString)"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ClipboardSync.State.self, from: old),
                       ClipboardSync.State(since: "2026-11-02T10:00:00.000Z", sent: [id]), "keeps its watermark and sent")
    }

    /// #705: a run asks iOS for its grace and gives it back once: at its end, or when it expires.
    func testASyncHoldsABackgroundTaskEndedOnce() async throws {
        let saved = (KeyboardSettings.store, ClipboardSync.beginBackground, ClipboardSync.endBackground)
        KeyboardSettings.store = { self.defaults }
        let h = ClipboardHistory(dir: dir)
        ClipboardSync.history = { h }
        var expire: (() -> Void)?
        var begun = 0, ended: [Int] = []
        ClipboardSync.beginBackground = { expire = $0; begun += 1; return UIBackgroundTaskIdentifier(rawValue: begun) }
        ClipboardSync.endBackground = { ended.append($0.rawValue) }
        defer {
            ClipboardSync.offer([], over: ClipFake(), machine: machine)
            ClipboardSync.history = { ClipboardHistory.shared() }
            (KeyboardSettings.store, ClipboardSync.beginBackground, ClipboardSync.endBackground) = saved
        }
        let fake = ClipFake()
        fake.items = [macText(String(repeating: "cut ", count: 600), ago: 0)]
        ClipboardSync.offer([.clipboard], over: fake, machine: machine)
        try await waitUntil("synced") { !ClipboardSync.running }
        XCTAssertEqual([begun] + ended, [1, 1], "ended at the run's end")

        fake.items = [macText(String(repeating: "expires ", count: 300), ago: -30)]
        ClipboardSync.kick()
        expire?()   // iOS's time runs out before the run gets to its end
        try await waitUntil("synced") { !ClipboardSync.running }
        XCTAssertEqual([begun] + ended, [2, 1, 2], "ended by the expiry, not again at the end")
        XCTAssertEqual(h.clips.count, 2, "the run itself goes on")
    }

    private func loopMac(_ answer: @escaping ((UInt8, Data), @escaping (Data) -> Void) -> Void) async throws
        -> (ProsperTransport, Box<[[(UInt8, Data)]]>, NWListener) {
        let got = Box<[[(UInt8, Data)]]>([])
        let listener = try loopbackServer { c in
            let n = got.v.count
            got.v.append([])
            let buf = Box(Data())
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, done, err in
                    if let d { buf.v.append(d) }
                    while let frame = try? FrameCodec.pop(&buf.v) {
                        got.v[n].append(frame)
                        answer(frame) { c.send(content: $0, completion: .idempotent) }
                    }
                    if !done, err == nil { read() }
                }
            }
            read()
        }
        try await waitUntil("listener") { (listener.port?.rawValue ?? 0) != 0 }
        return (ProsperTransport(host: "127.0.0.1", port: listener.port!.rawValue), got, listener)
    }

    private func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    private func obj(_ d: Data) -> NSDictionary? { (try? JSONSerialization.jsonObject(with: d)) as? NSDictionary }
    private func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func testListAndItemOnTheWire() async throws {
        let blob = Data((0..<2_500_000).map { UInt8($0 % 251) })
        let (mac, got, l) = try await loopMac { [self] frame, send in
            switch (frame.0, obj(frame.1)?["id"] as? String) {
            case (0x15, _):
                send(FrameCodec.encode(0x1d, json([
                    ["id": "A", "date": "2026-10-31T10:00:00.123Z", "kind": "text", "source": "Mac", "text": "hi", "size": 2],
                    ["id": "B", "date": "2026-10-31T09:00:00Z", "kind": "image", "size": blob.count, "thumb": "AA=="],
                    ["kind": "text"]])))
            case (0x16, "B"):
                // Header, data frames and ok in one burst: the reader keeps what comes past a frame.
                var burst = FrameCodec.encode(0x1a, json(["id": "B", "size": blob.count, "sha256": hex(blob), "kind": "image"]))
                for at in stride(from: 0, to: blob.count, by: 1 << 20) {
                    burst += FrameCodec.encode(0x10, blob.subdata(in: at..<min(at + (1 << 20), blob.count)))
                }
                send(burst + FrameCodec.encode(0x14, Data()))
            case (0x16, "C"):
                send(FrameCodec.encode(0x1a, json(["id": "C", "size": 3, "sha256": hex(Data("abc".utf8))]))
                     + FrameCodec.encode(0x10, Data("ab".utf8)) + FrameCodec.encode(0x14, Data()))
            default:
                send(FrameCodec.encode(0x13, json(["message": "gone"])))
            }
        }
        defer { l.cancel() }
        let rows = try await mac.clipboardList(limit: 100, before: "Z", since: "2026-10-31T08:00:00.000Z")
        XCTAssertEqual(rows, [ClipboardRow(id: "A", date: "2026-10-31T10:00:00.123Z", kind: "text", source: "Mac", text: "hi", size: 2),
                              ClipboardRow(id: "B", date: "2026-10-31T09:00:00Z", kind: "image", source: "Mac", text: nil, size: blob.count)],
                       "a row without its id is left out")
        XCTAssertEqual(got.v[0][0].0, 0x15)
        XCTAssertEqual(obj(got.v[0][0].1), ["limit": 100, "before": "Z", "since": "2026-10-31T08:00:00.000Z"])
        XCTAssertEqual(ClipboardRow.date("2026-10-31T09:00:00Z"), ClipboardRow.date("2026-10-31T09:00:00.000Z"), "with or without ms")

        let (sha, data) = try await mac.clipboardItem(id: "B", max: ClipboardSync.imageMax, maxSide: nil)
        XCTAssertEqual(sha, hex(blob))
        XCTAssertEqual(data, blob)
        XCTAssertEqual(got.v[1][0].1, json(["id": "B"]), "#712: without max_side, #621's bytes")
        _ = try await mac.clipboardItem(id: "B", max: ClipboardSync.imageMax, maxSide: 1024)
        XCTAssertEqual(obj(got.v[2][0].1), ["id": "B", "max_side": 1024], "#712: an integer, the long side")
        do { _ = try await mac.clipboardItem(id: "B", max: 1000, maxSide: nil); XCTFail("over max") } catch {}
        do { _ = try await mac.clipboardItem(id: "C", max: 1000, maxSide: nil); XCTFail("short") } catch {}
        do { _ = try await mac.clipboardItem(id: "D", max: 1000, maxSide: nil); XCTFail("refused") } catch {
            XCTAssertEqual((error as? TransportError)?.errorDescription, "gone", "the Mac's error as written")
        }
    }

    func testAddHistoryOnTheWire() async throws {
        let (mac, got, l) = try await loopMac { [self] _, send in
            send(FrameCodec.encode(0x14, json(["added": ["X"], "skipped": [["id": "Y", "reason": "duplicate"]]])))
        }
        defer { l.cancel() }
        let id = UUID()
        let sent = try await mac.addClipboardHistory([ClipboardText(id: id, date: Date(timeIntervalSince1970: 1_793_440_800.25), text: "hi")])
        XCTAssertEqual(sent, ClipboardSent(added: ["X"], skipped: ["Y": "duplicate"]))
        XCTAssertEqual(got.v[0][0].0, 0x22)
        XCTAssertEqual(obj(got.v[0][0].1), ["items": [["id": id.uuidString, "date": "2026-10-31T10:00:00.250Z", "kind": "text", "text": "hi"]]])
    }

    /// Each upload on a fresh connection; a reply right after the header means no bytes go, and
    /// the bytes go in frames of at most 1 MB, checked by the Mac.
    func testUploadOnItsOwnConnectionReadsTheEarlyReply() async throws {
        let small = Data("a duplicate".utf8)
        let (mac, got, l) = try await loopMac { [self] frame, send in
            if frame.0 == 0x23, let o = obj(frame.1), o["size"] as? Int == small.count {
                send(FrameCodec.encode(0x14, json(["skipped": [["id": o["id"]!, "reason": "duplicate"]]])))
            }
        }
        defer { l.cancel() }
        let dup = ClipboardUpload(id: UUID(), date: Date(), data: small, mime: "image/png")
        let early = try await mac.clipboardUpload(dup)
        XCTAssertEqual(early, ClipboardSent(skipped: [dup.id.uuidString: "duplicate"]))
        XCTAssertEqual(got.v[0].map(\.0), [0x23], "no bytes after an early reply")
        let header = try XCTUnwrap(obj(got.v[0][0].1))
        XCTAssertEqual(header["kind"] as? String, "image")
        XCTAssertEqual(header["source"] as? String, "iPhone")
        XCTAssertEqual(header["sha256"] as? String, hex(small))
        XCTAssertEqual(header["mime"] as? String, "image/png")
        XCTAssertNil(header["live"], "history only")

        let big = Data((0..<2_500_000).map { UInt8($0 % 13) })
        let acc = Box(Data())
        let (mac2, got2, l2) = try await loopMac { [self] frame, send in
            if frame.0 == 0x23 { acc.v = Data(); return }
            acc.v += frame.1
            if acc.v.count == big.count {
                send(FrameCodec.encode(0x14, json(["added": [hex(acc.v) == hex(big) ? "ok" : "mismatch"]])))
            }
        }
        defer { l2.cancel() }
        let item = ClipboardUpload(id: UUID(), date: Date(), data: big, mime: nil)
        let first = try await mac2.clipboardUpload(item), second = try await mac2.clipboardUpload(item)
        XCTAssertEqual([first, second], [ClipboardSent(added: ["ok"]), ClipboardSent(added: ["ok"])], "the bytes arrive whole")
        XCTAssertEqual(got2.v.count, 2, "a fresh connection per upload")
        XCTAssertEqual(got2.v[0].map(\.0), [0x23, 0x10, 0x10, 0x10])
        XCTAssertTrue(got2.v[0].dropFirst().allSatisfy { $0.1.count <= 1 << 20 })
    }
}

/// The Mac's clipboard history in memory, answering as the wire does. `items` newest first.
final class ClipFake: SessionTransport {
    struct Item { var row: ClipboardRow; var data: Data }
    var items: [Item] = []
    /// The Mac shortens a page past its frame bound.
    var pageMax = 100
    var lists: [(before: String?, since: String?)] = []
    var pulls: [String] = []
    /// Each pull's `maxSide`, as `pulls`.
    var maxSides: [Int?] = []
    var badSha: Set<String> = []
    var batches: [[ClipboardText]] = []
    var uploads: [ClipboardUpload] = []
    /// Text → its skipped reason in addClipboardHistory.
    var reasons: [String: String] = [:]
    /// nil: added.
    var uploadReply: ClipboardSent?
    /// Before each pull, with the pulls so far counting this one: throw to cut the run there.
    var onPull: ((Int) throws -> Void)?
    var calls: Int { lists.count + pulls.count + batches.count + uploads.count }

    func clipboardList(limit: Int, before: String?, since: String?) async throws -> [ClipboardRow] {
        lists.append((before, since))
        var rows = items.map(\.row)
        if let since = since.flatMap(ClipboardRow.date) {
            rows = rows.filter { ClipboardRow.date($0.date)!.timeIntervalSince(since) >= 0.001 }   // exclusive at ms
        }
        if let before {
            guard let i = rows.firstIndex(where: { $0.id == before }) else { throw TransportError.server("before: no such item") }
            rows = Array(rows[(i + 1)...])
        }
        return Array(rows.prefix(min(limit, pageMax)))
    }

    func clipboardItem(id: String, max: Int, maxSide: Int?) async throws -> (sha256: String, data: Data) {
        pulls.append(id)
        maxSides.append(maxSide)
        try onPull?(pulls.count)
        guard let it = items.first(where: { $0.row.id == id }) else { throw TransportError.server("gone") }
        guard it.data.count <= max else { throw TransportError.protocolError(ProsperTransport.itemTooLarge) }
        let sha = badSha.contains(id) ? String(repeating: "0", count: 64) : SHA256.hash(data: it.data).map { String(format: "%02x", $0) }.joined()
        return (sha, it.data)
    }

    func addClipboardHistory(_ items: [ClipboardText]) async throws -> ClipboardSent {
        batches.append(items)
        var sent = ClipboardSent()
        for i in items {
            if let r = reasons[i.text] { sent.skipped[i.id.uuidString] = r } else { sent.added.append(i.id.uuidString) }
        }
        return sent
    }

    func clipboardUpload(_ item: ClipboardUpload) async throws -> ClipboardSent {
        uploads.append(item)
        return uploadReply ?? ClipboardSent(added: [item.id.uuidString])
    }

    func listSessions() async throws -> [DchSession] { [] }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream { throw TransportError.notConnected }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}
