import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Prosper

/// The image button only ever sent ctrl-V, which makes Claude Code read the clipboard
/// of the MACHINE IT RUNS ON. The phone's copied image gets there only if Universal
/// Clipboard happens to sync it — so the button did nothing most of the time. Now the
/// bytes travel with the request.
@MainActor
final class ImagePasteTests: XCTestCase {

    /// 1×1 transparent PNG.
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    override func tearDown() {
        UIPasteboard.general.items = []
        UserDefaults.standard.removeObject(forKey: Shortcuts.storageKey)
        super.tearDown()
    }

    private func makeVC() async throws -> (TerminalHostVC, SpyStream) {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport,
                                     session: DchSession(name: "t", alias: nil))
        let vc = TerminalHostVC(conn: conn, handle: TermHandle())
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        vc.view.layoutIfNeeded()
        vc.startIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        return (vc, transport.stream)
    }

    func testImagePasteShipsTheImageAndTheKeystroke() async throws {
        let (vc, spy) = try await makeVC()
        UIPasteboard.general.setData(png, forPasteboardType: "public.png")

        vc.pasteImage(then: [0x16])

        XCTAssertEqual(spy.clipboards, [png], "the copied image never reached the remote clipboard")
        XCTAssertEqual(spy.sent, [[0x16]], "ctrl-V must follow, or nothing pastes")
    }

    /// Photos hands over HEIC/JPEG as readily as PNG, and the far end reads the
    /// clipboard as PNG — so anything else has to be converted before it ships.
    func testNonPNGImageIsConvertedBeforeSending() async throws {
        let (vc, spy) = try await makeVC()
        let jpeg = UIImage(data: png)!.jpegData(compressionQuality: 0.9)!
        UIPasteboard.general.setData(jpeg, forPasteboardType: UTType.jpeg.identifier)

        vc.pasteImage(then: [0x16])

        XCTAssertEqual(spy.clipboards.count, 1, "a JPEG on the pasteboard shipped nothing")
        XCTAssertEqual(spy.clipboards.first?.prefix(4).map { $0 }, [0x89, 0x50, 0x4e, 0x47],
            "shipped bytes must be PNG — Claude Code asks the clipboard for «class PNGf»")
    }

    /// Text on the clipboard must not be read or shipped (and must not trigger iOS's
    /// paste prompt).
    func testTextOnTheClipboardShipsNoImage() async throws {
        let (vc, spy) = try await makeVC()
        UIPasteboard.general.string = "not an image"

        vc.pasteImage(then: [0x16])

        XCTAssertEqual(spy.clipboards, [])
        XCTAssertEqual(spy.sent, [[0x16]])
    }

    /// Nothing image-shaped on the pasteboard: still send the keystroke — the remote
    /// clipboard may already hold the image.
    func testKeystrokeGoesOutEvenWithNoImageCopied() async throws {
        let (vc, spy) = try await makeVC()
        UIPasteboard.general.items = []

        vc.pasteImage(then: [0x16])

        XCTAssertEqual(spy.clipboards, [])
        XCTAssertEqual(spy.sent, [[0x16]])
    }

    /// A bar saved by an older build pinned `pasteImg` to plain ctrl-V forever, so the
    /// fix would never reach anyone who had touched their shortcuts.
    func testSavedBarPicksUpNewKeyDefinitions() {
        let stale = ShortcutKey(id: "pasteImg", label: "paste img", kind: .bytes,
                                bytes: [0x16], systemImage: "photo")
        Shortcuts.save([stale, ShortcutKey(id: "esc", label: "esc", kind: .bytes, bytes: [0x1b])])

        let loaded = Shortcuts.load()

        XCTAssertEqual(loaded.map(\.id), ["pasteImg", "esc"], "the user's set and order must survive")
        XCTAssertEqual(loaded.first?.kind, .pasteImage, "stale kind kept the image paste broken")
    }
}
