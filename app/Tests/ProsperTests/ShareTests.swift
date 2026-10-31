import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Prosper

/// Share › Prosper (#610): what was shared reaches the session as the terminal's own paste
/// keys send it, never with a Return, through an App Group handoff the app takes once.
@MainActor
final class ShareTests: XCTestCase {
    private let mac = UUID()
    private var dir: URL!
    private var suite: String!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "share-tests-\(UUID().uuidString)"
        let (d, s) = (dir, suite!)
        ShareInbox.dir = { d }
        ShareInbox.defaults = { UserDefaults(suiteName: s) }
        ShareInbox.pending = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults().removePersistentDomain(forName: suite)
        ShareInbox.dir = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareInbox.group) }
        ShareInbox.defaults = { UserDefaults(suiteName: ShareInbox.group) }
        ShareInbox.pending = nil
        super.tearDown()
    }

    private func item(text: String? = nil, image: Data? = nil, session: String = "main") -> ShareItem {
        ShareItem(target: ShareTarget(machine: mac, session: session), text: text, image: image)
    }

    private static let open = Array("\u{1b}[200~".utf8), close = Array("\u{1b}[201~".utf8)

    /// A JPEG `width`×`height`, no alpha.
    private func jpeg(_ width: Int, _ height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .jpegData(withCompressionQuality: 0.8) { c in
                UIColor.systemTeal.setFill()
                c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }

    // MARK: - Payload → bytes

    func testTextIsOneBracketedPasteWithItsNewlineInsideAndNoReturn() {
        let out = item(text: "echo one\nrm -rf x").outbound
        XCTAssertEqual(out, [.bytes(Self.open + Array("echo one\nrm -rf x".utf8) + Self.close)],
                       "one paste, the newline inside it")
        guard case .bytes(let b) = out.last else { return XCTFail("no bytes") }
        XCTAssertEqual(Array(b.suffix(Self.close.count)), Self.close, "nothing after the closer: no Return, nothing runs")
    }

    /// The pasted text is sanitized as every paste is: a shared closer can't end it early.
    func testAnInjectedCloserCannotEndThePaste() {
        guard case .bytes(let b) = item(text: "a\u{1b}[201~\rrm -rf x").outbound.first else { return XCTFail("no bytes") }
        XCTAssertEqual(b.count(where: { $0 == 0x1b }), 2, "only the paste's own opener and closer keep ESC")
        XCTAssertNotEqual(b.last, 0x0d)
    }

    func testLinkGoesAsItsText() async throws {
        let model = ShareModel(machines: [])
        await model.load([NSItemProvider(object: URL(string: "https://example.com/a?b=1")! as NSURL)])
        XCTAssertEqual(model.text, "https://example.com/a?b=1")
        XCTAssertEqual(item(text: model.text).outbound, [.bytes(Self.open + Array("https://example.com/a?b=1".utf8) + Self.close)])
    }

    func testTextsAndLinksJoinALineApartAndAFileIsRefused() async throws {
        let model = ShareModel(machines: [])
        await model.load([NSItemProvider(object: "look" as NSString),
                          NSItemProvider(object: URL(string: "https://example.com")! as NSURL)])
        XCTAssertEqual(model.text, "look\nhttps://example.com")
        XCTAssertFalse(model.unusable)

        let file = ShareModel(machines: [])
        await file.load([NSItemProvider(object: dir.appendingPathComponent("x.pdf") as NSURL)])
        XCTAssertNil(file.text)
        XCTAssertTrue(file.unusable, "a file is not text: the sheet says what it takes")
    }

    /// A provider registered by type, as a share sheet's text arrives cross-process (#610 QA):
    /// an attributed string, UTF-8 data, or a string under public.utf8-plain-text, all as "look".
    func testTextRegisteredByTypeIsRead() async throws {
        func registered(_ value: NSSecureCoding) -> NSItemProvider {
            let p = NSItemProvider()
            p.registerItem(forTypeIdentifier: UTType.plainText.identifier) { completion, _, _ in completion?(value, nil) }
            return p
        }
        let cases: [(String, NSItemProvider)] = [
            ("attributed", registered(NSAttributedString(string: "look"))),
            ("data", registered(Data("look".utf8) as NSData)),
            ("utf8 item", NSItemProvider(item: "look" as NSString, typeIdentifier: UTType.utf8PlainText.identifier)),
        ]
        for (name, p) in cases {
            let model = ShareModel(machines: [])
            await model.load([p])
            XCTAssertEqual(model.text, "look", name)
            XCTAssertFalse(model.unusable, name)
        }

        let joined = ShareModel(machines: [])
        await joined.load([registered(NSAttributedString(string: "text")),
                           NSItemProvider(object: URL(string: "https://example.com")! as NSURL)])
        XCTAssertEqual(joined.text, "text\nhttps://example.com")

        let rtf = NSItemProvider()
        let rtfData = Data(#"{\rtf1\ansi look}"#.utf8)
        rtf.registerItem(forTypeIdentifier: UTType.rtf.identifier) { completion, _, _ in completion?(rtfData as NSData, nil) }
        let rich = ShareModel(machines: [])
        await rich.load([rtf])
        XCTAssertFalse(rich.text?.contains("rtf1") ?? false, "no RTF markup is pasted")

        let file = ShareModel(machines: [])
        await file.load([NSItemProvider(object: dir.appendingPathComponent("x.pdf") as NSURL)])
        XCTAssertTrue(file.unusable)
    }

    /// The extension item's own text stands in only when no provider gave text or an image.
    func testExtensionItemTextIsTheLastFallback() async throws {
        let empty = NSItemProvider()
        empty.registerItem(forTypeIdentifier: UTType.plainText.identifier) { completion, _, _ in completion?(nil, nil) }
        let model = ShareModel(machines: [])
        await model.load([empty], fallback: "one\ntwo")
        XCTAssertEqual(model.text, "one\ntwo")
        XCTAssertFalse(model.unusable)

        let both = ShareModel(machines: [])
        await both.load([NSItemProvider(item: "look" as NSString, typeIdentifier: UTType.utf8PlainText.identifier)], fallback: "look")
        XCTAssertEqual(both.text, "look", "not appended twice")

        let none = ShareModel(machines: [])
        await none.load([empty], fallback: "")
        XCTAssertTrue(none.unusable)
    }

    // MARK: - Image

    /// The paste img key's path: the Mac's clipboard, then ^V; any text after, as its paste.
    func testImageGoesToTheClipboardThenCtrlVThenTheText() {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        XCTAssertEqual(item(text: "see", image: png).outbound,
                       [.clipboard(png), .bytes([0x16]), .bytes(Self.open + Array("see".utf8) + Self.close)])
    }

    func testImageIsCutToItsSideAsPNG() async throws {
        let model = ShareModel(machines: [])
        await model.load([NSItemProvider(item: jpeg(3000, 1000) as NSData, typeIdentifier: UTType.jpeg.identifier)])
        let png = try XCTUnwrap(model.image, "a shared JPEG gave no image")
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4e, 0x47], "the Mac's clipboard is read as PNG")
        let size = try XCTUnwrap(UIImage(data: png)).size
        XCTAssertEqual(size.width, ShareInbox.imageSide)
        XCTAssertEqual(size.height, (ShareInbox.imageSide / 3).rounded(), accuracy: 1)
        XCTAssertNil(ShareInbox.png(Data("not an image".utf8)))
    }

    /// Delivered before the session is live, the image and its ^V still land, in order, once it is.
    func testDeliveryWaitsForTheSessionAndKeepsOrder() async throws {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport, session: DchSession(name: "main"))
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        conn.deliver(item(text: "hi", image: png))
        conn.start(cols: 80, rows: 24)
        try await Task.sleep(nanoseconds: 200_000_000)
        transport.stream.emit("$ ")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.stream.clipboards, [png])
        XCTAssertEqual(transport.stream.sent, [[0x16], Self.open + Array("hi".utf8) + Self.close])
    }

    // MARK: - Preselection

    func testLastSessionIsPreselectedOnlyOnItsMacAndWhenListed() {
        let sessions = [DchSession(name: "a"), DchSession(name: "b")]
        XCTAssertNil(ShareInbox.preselect(sessions, on: mac), "nothing used yet: the user picks")
        ShareInbox.last = ShareTarget(machine: mac, session: "b")
        XCTAssertEqual(ShareInbox.preselect(sessions, on: mac), "b")
        XCTAssertNil(ShareInbox.preselect(sessions, on: UUID()), "another Mac's b is not this one")
        XCTAssertNil(ShareInbox.preselect([DchSession(name: "a"), DchSession(name: "c")], on: mac), "gone")
        XCTAssertEqual(ShareInbox.preselect([DchSession(name: "only")], on: mac), "only")
    }

    func testSheetListsTheLastMacAndPreselectsItsSession() async {
        let a = Machine(name: "Studio", addresses: ["studio"]), b = Machine(name: "Laptop", addresses: ["laptop"])
        ShareInbox.last = ShareTarget(machine: b.id, session: "two")
        let model = ShareModel(machines: [a, b])
        XCTAssertEqual(model.machine, b.id)
        var dialed: [String] = []
        model.list = { dialed.append($0.name); return [DchSession(name: "one"), DchSession(name: "two")] }
        model.text = "x"
        await model.load()
        XCTAssertEqual(dialed, ["Laptop"])
        XCTAssertEqual(model.selected, "two")
        XCTAssertEqual(model.item?.target, ShareTarget(machine: b.id, session: "two"))
        XCTAssertEqual(model.item?.text, "x")
    }

    func testNoMacAndUnreachableMacSayWhy() async {
        let none = ShareModel(machines: [])
        await none.load()
        XCTAssertEqual(none.note, "Add your Mac in Prosper first.")

        let model = ShareModel(machines: [Machine(name: "Studio", addresses: ["studio"])])
        model.list = { _ in throw TransportError.hostUnreachable("timed out") }
        await model.load()
        XCTAssertEqual(model.note, "Can't reach Studio — check Tailscale.")
        XCTAssertNil(model.item)
    }

    // MARK: - Handoff

    func testHandoffRoundTripsOnceAndOnlyForItsLink() throws {
        let sent = item(text: "hello", image: Data([1, 2, 3]))
        let url = try XCTUnwrap(ShareInbox.post(sent))
        XCTAssertEqual(url.absoluteString, "prosper://share?id=\(sent.id.uuidString)")
        XCTAssertNil(ShareInbox.open(URL(string: "prosper://share?id=\(UUID().uuidString)")!), "a stale link")
        XCTAssertNil(ShareInbox.open(URL(string: "prosper://sessions?mac=x")!))
        XCTAssertEqual(ShareInbox.open(url), sent)
        XCTAssertNil(ShareInbox.open(url), "taken: a replayed link pastes nothing")
    }

    func testPendingGoesToItsSessionsTerminalOnly() {
        ShareInbox.pending = item(text: "x", session: "main")
        XCTAssertNil(ShareInbox.take(for: "other"))
        XCTAssertNil(ShareInbox.take(for: "main"), "the first terminal after a share takes it, or drops it")
        ShareInbox.pending = item(text: "x", session: "main")
        XCTAssertEqual(ShareInbox.take(for: "main")?.text, "x")
        XCTAssertNil(ShareInbox.pending)
    }

    func testMachinesMirrorAndTheSameGroupAsTheKeyboards() {
        let m = Machine(name: "Studio", addresses: ["100.1.2.3", "studio.ts.net"])
        ShareInbox.save(machines: [m])
        XCTAssertEqual(ShareInbox.machines(), [m])
        XCTAssertEqual(ShareInbox.group, KeyboardSettings.suiteName)
    }
}
