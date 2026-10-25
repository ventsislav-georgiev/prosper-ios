import XCTest
@testable import Prosper

/// The sessions list's Sessions / Sidekicks split, by the real name containing a pattern.
final class SidekickSplitTests: XCTestCase {

    private func names(_ l: [DchSession]) -> [String] { l.map(\.name) }
    private func s(_ name: String, alias: String? = nil) -> DchSession { DchSession(name: name, alias: alias) }

    func testDefaultPattern() {
        let r = DchSession.split([s("build"), s("build-qa"), s("notes")], pattern: DchSession.sidekickDefault)
        XCTAssertEqual(names(r.primary), ["build", "notes"])
        XCTAssertEqual(names(r.sidekicks), ["build-qa"])
    }

    func testCaseInsensitive() {
        let r = DchSession.split([s("build-QA"), s("notes")], pattern: "-Qa")
        XCTAssertEqual(names(r.sidekicks), ["build-QA"])
        XCTAssertEqual(names(r.primary), ["notes"])
    }

    func testEmptyPatternMeansNoSplit() {
        let list = [s("build"), s("build-qa")]
        for p in ["", "   ", "\n\t"] {
            let r = DchSession.split(list, pattern: p)
            XCTAssertEqual(names(r.primary), ["build", "build-qa"])
            XCTAssertTrue(r.sidekicks.isEmpty)
        }
    }

    /// The alias is a display label only: neither a matching alias nor a plain one moves a session.
    func testAliasIgnored() {
        let r = DchSession.split([s("build", alias: "build-qa"), s("notes-qa", alias: "notes")], pattern: "-qa")
        XCTAssertEqual(names(r.primary), ["build"])
        XCTAssertEqual(names(r.sidekicks), ["notes-qa"])
    }

    func testOrderKept() {
        let r = DchSession.split([s("z-qa"), s("b"), s("a-qa"), s("a")], pattern: "-qa")
        XCTAssertEqual(names(r.primary), ["b", "a"])
        XCTAssertEqual(names(r.sidekicks), ["z-qa", "a-qa"])
    }

    func testAllSidekicksShowsSidekicks() {
        let r = DchSession.split([s("a-qa"), s("b-qa")], pattern: "-qa")
        XCTAssertTrue(DchSession.showsSidekicks(r, tab: false))
        XCTAssertTrue(DchSession.showsSidekicks(r, tab: true))
    }

    func testChosenTabShowsWhenBothHaveSessions() {
        let r = DchSession.split([s("a"), s("a-qa")], pattern: "-qa")
        XCTAssertFalse(DchSession.showsSidekicks(r, tab: false))
        XCTAssertTrue(DchSession.showsSidekicks(r, tab: true))
    }

    func testNoSidekicksShowsPrimary() {
        let r = DchSession.split([s("a"), s("b")], pattern: "-qa")
        XCTAssertFalse(DchSession.showsSidekicks(r, tab: false))
        XCTAssertFalse(DchSession.showsSidekicks(r, tab: true))
        XCTAssertFalse(DchSession.showsSidekicks(DchSession.split([], pattern: "-qa"), tab: true))
    }
}
