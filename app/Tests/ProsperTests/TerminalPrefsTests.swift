import XCTest
@testable import Prosper

/// The text size is persisted user state — a bad clamp bricks the terminal grid
/// (a 0 pt font means zero cols/rows), so the store keeps it inside the range.
final class TerminalPrefsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: TerminalPrefs.sizeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TerminalPrefs.sizeKey)
        super.tearDown()
    }

    func testDefaultIsTenPercentBelowThirteen() {
        XCTAssertEqual(TerminalPrefs.fontSize, 11.7, accuracy: 0.001)
    }

    func testStoresAndReadsBack() {
        TerminalPrefs.fontSize = 14
        XCTAssertEqual(TerminalPrefs.fontSize, 14, accuracy: 0.001)
    }

    func testClampsOutOfRange() {
        TerminalPrefs.fontSize = 100
        XCTAssertEqual(TerminalPrefs.fontSize, TerminalPrefs.range.upperBound, accuracy: 0.001)
        TerminalPrefs.fontSize = 1
        XCTAssertEqual(TerminalPrefs.fontSize, TerminalPrefs.range.lowerBound, accuracy: 0.001)
    }

    /// The size is stored as a plain Double under the documented key: the editor's
    /// stepper and the terminal's font both go through here, and a type/key drift would
    /// silently reset the size on every launch.
    func testStoresAPlainDoubleUnderTheSharedKey() {
        TerminalPrefs.fontSize = 13
        XCTAssertEqual(UserDefaults.standard.double(forKey: TerminalPrefs.sizeKey), 13, accuracy: 0.001)
        XCTAssertEqual(TerminalPrefs.sizeKey, "terminalFontSize", "the key is the persisted contract")
    }

    /// A zero/garbage value (never written, or cleared) must fall back, not through.
    func testZeroFallsBackToDefault() {
        UserDefaults.standard.set(0.0, forKey: TerminalPrefs.sizeKey)
        XCTAssertEqual(TerminalPrefs.fontSize, TerminalPrefs.defaultSize, accuracy: 0.001)
    }
}

/// The agent command reaches dch as argv, never spliced into a shell script: what the
/// user typed is the last argument, byte for byte, and the script around it is fixed.
final class AgentCommandTests: XCTestCase {

    private let script = #"exec "${SHELL:-/bin/zsh}" -lic 'cd; trap : INT; eval "$1"; exec "$0" -l' "${SHELL:-/bin/zsh}" "$1""#

    func testDefault() {
        XCTAssertEqual(AgentCommand.argv(AgentCommand.defaultCommand),
                       ["/bin/sh", "-c", script, "sh", "headroom wrap claude --chrome"])
    }

    func testEmptyOrBlankFallsBackToDefault() {
        XCTAssertEqual(AgentCommand.argv("").last, AgentCommand.defaultCommand)
        XCTAssertEqual(AgentCommand.argv("  \n").last, AgentCommand.defaultCommand)
    }

    /// Quotes, `$` and `;` would break or inject if quoted into the script; as `$1` they
    /// reach `eval` untouched, so the login shell parses them exactly as typed.
    func testShellMetacharactersPassVerbatim() {
        let typed = #"claude --append-system-prompt "it's $HOME"; echo 'done'"#
        XCTAssertEqual(AgentCommand.argv(typed), ["/bin/sh", "-c", script, "sh", typed])
        XCTAssertEqual(AgentCommand.argv("  \(typed) ").last, typed, "only the edges are trimmed")
    }

    /// The iOS keyboard's smart punctuation, which `.autocorrectionDisabled()` doesn't stop.
    func testSmartPunctuationIsUndone() {
        XCTAssertEqual(AgentCommand.argv("claude \u{2014}chrome \u{201C}a\u{201D} \u{201E}b\u{201C} \u{2018}c\u{2019}").last,
                       #"claude --chrome "a" "b" 'c'"#)
    }

    /// The create client is closed only once the session drew: dch's master exists from
    /// the first output on, and closing sooner leaves no session.
    @MainActor
    func testStartClosesOnlyAfterFirstOutput() async throws {
        let transport = CreateSpy()
        let started = Task { try await AgentCommand.start("my agent", name: "work", on: transport) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(transport.stream.closed, "closed before the session showed output")
        transport.stream.emit("\u{1b}[H\u{1b}[2J")
        let name = try await started.value
        XCTAssertTrue(transport.stream.closed)
        XCTAssertEqual(name, "work")
        XCTAssertEqual(transport.created?.name, "work")
        XCTAssertEqual(transport.created?.command, AgentCommand.argv("my agent"))
    }
}

/// Records the one create and hands back a stream the test drives.
private final class CreateSpy: SessionTransport {
    let stream = DeliveryStream()
    var created: (name: String?, command: [String])?
    func listSessions() async throws -> [DchSession] { [] }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream { stream }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
        created = (name, command)
        return stream
    }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}
