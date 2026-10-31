import XCTest
import SwiftUI
import UIKit
import SwiftTerm
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

    /// #607 QA, on the system keyboard: the frame posted for a turn came out short by the
    /// new orientation's bottom safe inset, so the bar sat that much low (19 pt landscape,
    /// 34 portrait) until the keyboard rose again, whose frame was right. Emulates that
    /// system around a real turn of the app's own host: the turn posts the short frame,
    /// a fresh placement (`replaceKeyboard`) the true one.
    func testBarRidesTheSystemKeyboardThroughATurn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        guard #available(iOS 16, *) else { throw XCTSkip("requestGeometryUpdate is iOS 16") }
        let saved = TerminalKeyboard.hardwareKeyboardConnected
        TerminalKeyboard.hardwareKeyboardConnected = { true }   // the system keyboard's path
        defer { TerminalKeyboard.hardwareKeyboardConnected = saved }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack {
            TerminalScreen(transport: SpyTransport(), session: DchSession(name: "t", alias: nil))
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        spin(0.5)
        func find(_ vc: UIViewController) -> TerminalHostVC? {
            vc as? TerminalHostVC ?? vc.children.lazy.compactMap(find).first
        }
        let vc = try XCTUnwrap(find(host), "no host VC under the navigation stack")
        XCTAssertNil(vc.keyboardInputView, "the system keyboard's path")
        let bar = try XCTUnwrap(vc.view.subviews.first { $0 is ShortcutBar })

        /// The keyboard as it sits, its bottom inset under the keys; `short` drops the inset.
        func frame(short: Bool = false) -> CGRect {
            let b = window.bounds
            let h: CGFloat = (b.width > b.height ? 200 : 300) - (short ? window.safeAreaInsets.bottom : 0)
            return CGRect(x: 0, y: b.maxY - h, width: b.width, height: h)
        }
        func post(_ r: CGRect) {
            NotificationCenter.default.post(
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: r)])
        }
        vc.replaceKeyboard = { post(frame()) }
        func turn(_ o: UIInterfaceOrientationMask) {
            let wide = o == .landscapeRight
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: o)) { XCTFail("rotation: \($0)") }
            let started = Date().addingTimeInterval(2)
            while (window.bounds.width > window.bounds.height) != wide, Date() < started { spin(0.01) }
            post(frame(short: true))   // the turn's own frame
            spin(1.5)
        }
        defer { turn(.portrait) }
        func check(_ what: String, line: UInt = #line) {
            let top = frame().minY
            let barBottom = bar.convert(bar.bounds, to: window).maxY
            XCTAssertEqual(barBottom, top, accuracy: 0.5,
                           "\(what): bar bottom \(barBottom), keyboard top \(top), inset \(window.safeAreaInsets.bottom)",
                           line: line)
        }
        post(frame())
        spin(0.5)
        check("portrait")
        turn(.landscapeRight)
        check("turned to landscape")
        turn(.portrait)
        check("turned back")
        post(CGRect(x: 0, y: window.bounds.maxY, width: window.bounds.width, height: 300))
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

    /// UIKit reads the optional `keyboardType` trait by selector (absent → `.default`),
    /// so read it the same way — a Swift call would dispatch statically to
    /// SwiftTerm's `.default` and prove nothing.
    func testTerminalAsksForAnASCIIKeyboard() throws {
        let (vc, _) = makeVC(CGSize(width: 390, height: 700))
        let tv = try XCTUnwrap(vc.view.subviews.first { $0 is TerminalView }, "no terminal view")
        let plain = TerminalView(frame: .zero, font: TerminalFont.mono(size: 12))
        func objcKeyboardType(_ v: UIView) -> Int? {
            guard v.responds(to: NSSelectorFromString("keyboardType")) else { return UIKeyboardType.default.rawValue }
            return (v.value(forKey: "keyboardType") as? NSNumber)?.intValue
        }
        XCTAssertEqual(objcKeyboardType(tv), UIKeyboardType.asciiCapable.rawValue,
            "the terminal must ask UIKit for an ASCII keyboard (no globe/emoji)")
        XCTAssertEqual(objcKeyboardType(plain), UIKeyboardType.default.rawValue,
            "only our subclass changes — SwiftTerm's own view keeps .default")
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

    var onUnsent: ((Outbound) -> Void)?
    func send(_ bytes: ArraySlice<UInt8>) -> Bool { sent.append(Array(bytes)); return true }
    func resize(cols: Int, rows: Int) { resizes.append((cols, rows)) }
    func requestRedraw() { redraws += 1 }
    func requestSnapshot() { snapshots += 1 }
    func putClipboard(_ image: Data) -> Bool { clipboards.append(image); return true }
    func close() { cont?.finish() }

    /// Feed bytes as if the remote wrote them.
    func emit(_ text: String) { cont?.yield(ArraySlice(Array(text.utf8))) }
}
