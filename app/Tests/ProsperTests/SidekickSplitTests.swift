import XCTest
@testable import Prosper

/// The sessions list's Sessions / Sidekicks split, by the name or alias containing a pattern.
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

    /// A renamed session counts by its alias; a matching name still counts under a plain alias.
    func testAliasOrNameMatches() {
        let r = DchSession.split([s("build", alias: "build-qa"), s("notes-qa", alias: "notes"),
                                  s("web", alias: "site"), s("api")], pattern: "-qa")
        XCTAssertEqual(names(r.primary), ["web", "api"])
        XCTAssertEqual(names(r.sidekicks), ["build", "notes-qa"])
    }

    func testAliasCaseInsensitive() {
        let r = DchSession.split([s("build", alias: "Build-QA"), s("notes")], pattern: "-qa")
        XCTAssertEqual(names(r.sidekicks), ["build"])
        XCTAssertEqual(names(r.primary), ["notes"])
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
