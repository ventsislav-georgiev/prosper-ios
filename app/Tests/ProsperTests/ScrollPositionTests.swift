import XCTest
@testable import Prosper

/// The scroll pill showed at the top while the user sat at the bottom of a
/// full-screen TUI. SwiftTerm's `scrollPosition` is defined as 0 for the alternate
/// screen — which is where every full-screen TUI (Claude Code included) lives — and
/// it reports that on every chunk of output. So the host must ask "is there an
/// absolute position at all?" instead of trusting the number.
@MainActor
final class ScrollPositionTests: XCTestCase {

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

    /// Normal buffer, parked at the newest line: that IS an absolute position, and
    /// it's the bottom.
    func testScrollbackAtTheBottomReportsTheBottom() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit(String(repeating: "line\r\n", count: 200))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vc.absoluteScrollFraction(), 1,
            "200 lines of scrollback, viewport at the end — the pill belongs at the bottom")
    }

    /// Alternate screen: no scrollback, no position. nil keeps the pill where the
    /// user left it instead of slamming it to the top on every repaint.
    func testAlternateScreenReportsNoAbsolutePosition() async throws {
        let (vc, spy) = try await makeVC()
        spy.emit(String(repeating: "line\r\n", count: 200))
        spy.emit("\u{1b}[?1049h")          // what a full-screen TUI sends on startup
        spy.emit("prompt row\r\n")         // …and keeps writing
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vc.absoluteScrollFraction(),
            "alt screen has no absolute scroll position — reporting one puts the pill at the top")
    }
}
