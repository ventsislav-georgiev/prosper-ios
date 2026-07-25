import XCTest
import UIKit
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
