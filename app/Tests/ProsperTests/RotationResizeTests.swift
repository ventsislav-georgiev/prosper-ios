import XCTest
import SwiftUI
import UIKit
@testable import Prosper

/// Rotation has to reach the pty: a wider view means more columns, and the remote
/// program only reflows if we tell it. These drive the real host VC through a
/// portrait→landscape bounds change and watch what the transport was asked to do.
@MainActor
final class RotationResizeTests: XCTestCase {

    private func makeVC(_ size: CGSize) -> (TerminalHostVC, SpyStream) {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport,
                                     session: DchSession(name: "t", alias: nil))
        let vc = TerminalHostVC(conn: conn, handle: TermHandle())
        vc.view.frame = CGRect(origin: .zero, size: size)
        vc.view.layoutIfNeeded()
        return (vc, transport.stream)
    }

    /// The whole point of landscape: more columns. If the view widens and the grid
    /// doesn't, the remote program keeps rendering at the old width.
    func testRotationWidensTheGrid() {
        let (vc, _) = makeVC(CGSize(width: 390, height: 700))
        let portraitCols = vc.terminalSize.cols
        vc.view.frame = CGRect(x: 0, y: 0, width: 700, height: 390)
        vc.view.layoutIfNeeded()
        let landscape = vc.terminalSize
        XCTAssertGreaterThan(landscape.cols, portraitCols,
            "landscape must add columns (portrait \(portraitCols) → landscape \(landscape.cols))")
        XCTAssertLessThan(landscape.rows, 100)
    }

    /// …and the new size must be pushed to the session, or the pty never sees a
    /// SIGWINCH and the TUI reflows to nothing.
    func testRotationPushesNewSizeToTheSession() async throws {
        let (vc, spy) = makeVC(CGSize(width: 390, height: 700))
        let size = vc.terminalSize
        vc.startIfNeeded()
        // Let the attach loop hand us the stream before we judge what it received.
        try await Task.sleep(nanoseconds: 200_000_000)

        vc.view.frame = CGRect(x: 0, y: 0, width: 700, height: 390)
        vc.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)

        let wide = vc.terminalSize
        XCTAssertTrue(spy.resizes.contains { $0.cols == wide.cols && $0.rows == wide.rows },
            "no resize with the landscape grid \(wide) — pty stays at \(size); got \(spy.resizes)")
    }

    /// A snapshot painted while the remote is still repainting freezes the pre-reflow
    /// screen on top of the correct one — that is what kept the terminal narrow after
    /// rotating. So the request must wait for quiet, and be dropped if output never
    /// stops.
    /// A dch session has one size and the last client to report wins, so another
    /// client (or one left behind by a dropped connection) can narrow it under us
    /// without our grid changing. Every repair therefore re-states our size, or the
    /// remote keeps wrapping to a width we don't have and the redraw button repaints
    /// the same garbled screen.
    func testRepairRestatesOurSize() async throws {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport,
                                     session: DchSession(name: "t", alias: nil))
        conn.onBytes = { _ in }
        conn.start(cols: 120, rows: 30)
        try await Task.sleep(nanoseconds: 200_000_000)
        let spy = transport.stream
        spy.resizes.removeAll()

        conn.redraw()
        XCTAssertEqual(spy.resizes.map(\.cols), [120], "redraw went out without our width")

        conn.resync()
        XCTAssertEqual(spy.resizes.count, 2, "resync went out without our width")
        XCTAssertEqual(spy.resizes.last?.rows, 30)
    }

    /// After a grid change the repair must state the new size and must NOT paint dch's
    /// mirror: the mirror was captured at the old width, and painting it over the
    /// reflowed screen is what left landscape with a black right half. The pty jiggle
    /// (`requestRedraw`) is the half that still has to go out.
    func testRepairAfterRotationStatesTheSizeAndSkipsTheMirror() async throws {
        let (vc, spy) = makeVC(CGSize(width: 390, height: 700))
        vc.startIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        vc.view.frame = CGRect(x: 0, y: 0, width: 700, height: 390)
        vc.view.layoutIfNeeded()

        spy.resizes.removeAll()
        spy.redraws = 0
        spy.snapshots = 0
        vc.repairAfterSizeChange()

        let grid = vc.terminalSize
        XCTAssertEqual(spy.resizes.last?.cols, grid.cols, "the repair must state the measured width")
        XCTAssertEqual(spy.resizes.last?.rows, grid.rows)
        XCTAssertGreaterThan(spy.redraws, 0, "the pty jiggle is what makes the TUI reflow")

        // Past the snapshot deadline with a quiet session — the greediest case for a
        // mirror request. None may appear.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(spy.snapshots, 0, "painted a mirror captured at the old grid width")
    }

    /// The tests above drive the VC's frame directly. On the device nobody does that:
    /// SwiftUI owns the frame, and the terminal only gets the width SwiftUI proposes to
    /// the representable. So host the real `TerminalScreen` in a real window and rotate
    /// the window — the path the phone actually takes.
    func testRotatingTheHostedScreenReachesTheSession() async throws {
        let transport = SpyTransport()
        let host = UIHostingController(
            rootView: NavigationStack {
                TerminalScreen(transport: transport, session: DchSession(name: "t", alias: nil))
            })
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        win.rootViewController = host
        win.isHidden = false
        win.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)   // attach + first layout
        let spy = transport.stream
        let portraitCols = spy.resizes.last?.cols ?? 0
        XCTAssertGreaterThan(portraitCols, 0, "never attached")

        win.frame = CGRect(x: 0, y: 0, width: 700, height: 390)
        win.setNeedsLayout()
        win.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertGreaterThan(spy.resizes.last?.cols ?? 0, portraitCols,
            "landscape never reached the pty: \(spy.resizes)")
    }

    func testSnapshotWaitsForOutputToGoQuiet() async throws {
        let transport = SpyTransport()
        let conn = SessionConnection(transport: transport,
                                     session: DchSession(name: "t", alias: nil))
        conn.onBytes = { _ in }
        conn.start(cols: 80, rows: 24)
        try await Task.sleep(nanoseconds: 200_000_000)
        let spy = transport.stream

        conn.resync()
        XCTAssertEqual(spy.redraws, 2, "the repaint nudge is immediate (attach + resync)")

        // Keep writing for a second: no snapshot may be requested mid-repaint.
        for _ in 0..<7 {
            spy.emit("output\r\n")
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertEqual(spy.snapshots, 0, "snapshot fired while the screen was still being written")

        // Go quiet — now the mirror is worth trusting.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(spy.snapshots, 1, "no snapshot after the session went quiet")
    }
}

// MARK: - Spies

final class SpyTransport: SessionTransport {
    let stream = SpyStream()
    func listSessions() async throws -> [DchSession] { [] }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream {
        stream.resizes.append((cols, rows))
        return stream
    }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
        stream
    }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}

/// Records what the terminal asked of the session and never ends its output stream
/// (so the reconnect loop stays parked instead of spinning).
final class SpyStream: TerminalStream {
    var resizes: [(cols: Int, rows: Int)] = []
    var redraws = 0
    var snapshots = 0
    var clipboards: [Data] = []
    var sent: [[UInt8]] = []
    var onScreen: ((ArraySlice<UInt8>) -> Void)?
    let exited = false
    private var cont: AsyncStream<ArraySlice<UInt8>>.Continuation!
    lazy var output: AsyncStream<ArraySlice<UInt8>> = {
        AsyncStream { self.cont = $0 }
    }()

    func send(_ bytes: ArraySlice<UInt8>) { sent.append(Array(bytes)) }
    func resize(cols: Int, rows: Int) { resizes.append((cols, rows)) }
    func requestRedraw() { redraws += 1 }
    func requestSnapshot() { snapshots += 1 }
    func putClipboard(_ image: Data) { clipboards.append(image) }
    func close() { cont?.finish() }

    /// Feed bytes as if the remote wrote them.
    func emit(_ text: String) { cont?.yield(ArraySlice(Array(text.utf8))) }
}
