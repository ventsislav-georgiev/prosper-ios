import XCTest
import UIKit
@testable import Prosper

/// Fix, Rewrite and Summarize in the keyboard (#612): the text a command takes (`Rewrite.plan`),
/// the write that reads the field again and refuses a changed one (`Rewrite.replace`), Insert
/// that never deletes, the tile's and the key's gating, and a cancel that writes nothing. The
/// model is a fake on the bar's seam (`SuggestionBar.rewrite`): the simulator has none.
@MainActor
final class RewriteTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy

    private var pb: UIPasteboard!
    private var suite = ""
    /// Each rig's keyboard, field and view: the bar holds the keyboard, and it the field, weakly.
    private var kept: [AnyObject] = []

    override func setUp() {
        super.setUp()
        pb = UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true)
        suite = "RewriteTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UIPasteboard.remove(withName: pb.name)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        kept = []
        super.tearDown()
    }

    /// The model: `reply` at once, or with `holds` only once the test resumes `pending`.
    final class FakeModel {
        var calls: [(Rewrite.Command, String)] = []
        var reply = "Fixed."
        var holds = false
        var pending: CheckedContinuation<String, Error>?
        func run(_ command: Rewrite.Command, _ text: String) async throws -> String {
            calls.append((command, text))
            guard holds else { return reply }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
    }

    /// A keyboard on a fake field, the bar hosted with the fake model, Full Access on a named
    /// pasteboard (or none), and the rewrite key on its toolbar.
    private func rig(_ text: String = "", after: String = "", model: FakeModel = FakeModel(), fullAccess: Bool = true,
                     availability: Rewrite.Availability = .available) -> (TerminalKeyboard, SuggestionBar, Proxy, UIView) {
        let doc = Proxy()
        doc.text = text
        doc.after = after
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: UserDefaults(suiteName: suite)!)))
        bar.rewrite = { try await model.run($0, $1) }
        bar.rewriteAvailability = { availability }
        let pb = self.pb
        if fullAccess { bar.suggestions.pasteboard = { pb } }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        bar.attach(kb)
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults + [Shortcuts.rewrite] }
        kept += [kb, doc, view]
        return (kb, bar, doc, view)
    }

    private static func caps(_ v: UIView) -> [KeyCapButton] {
        v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) }
    }

    private func plan(_ doc: Proxy) -> Rewrite.Source? {
        Rewrite.plan(before: doc.documentContextBeforeInput, after: doc.documentContextAfterInput, selected: doc.selectedText)
    }

    // MARK: - plan

    func testPlanTakesTheSelection() throws {
        let s = try XCTUnwrap(Rewrite.plan(before: "Hi ", after: " there", selected: "teh cat"))
        XCTAssertEqual(s, Rewrite.Source(text: "teh cat", selected: true, note: nil, before: "Hi ", after: " there"))
        XCTAssertNil(Rewrite.plan(before: "Hi", after: "", selected: " \n"), "blank: nothing to rewrite")
        let long = try XCTUnwrap(Rewrite.plan(before: "", after: "", selected: String(repeating: "a", count: 4001)))
        XCTAssertEqual(long.text.count, Rewrite.cap)
        XCTAssertEqual(long.note, Rewrite.tooLong, "over the cap: Insert only")
    }

    func testPlanTakesTheParagraphBeforeTheCaretWhereItsWhole() throws {
        let cases: [(before: String, after: String, want: String)] = [
            ("Dear Sam,\nteh report is late", "", "teh report is late"),
            ("Dear Sam,\nteh report is late", "\nBest", "teh report is late"),
            ("Intro\n teh para", "", "teh para"),   // Safari's space after a break, and a real one: left out
            ("Dear Sam,\n\n", "", ""),
            ("It is late. teh report", "", "It is late. teh report"),   // short, two sentences: the field's start
        ]
        for c in cases {
            let s = Rewrite.plan(before: c.before, after: c.after, selected: nil)
            if c.want.isEmpty { XCTAssertNil(s, c.before); continue }
            XCTAssertEqual(s, Rewrite.Source(text: c.want, selected: false, note: nil, before: c.before, after: c.after), c.before)
        }
    }

    /// Insert only, the model given what shows, where the paragraph's whole isn't proven: a
    /// window's cut (Safari's), a host showing only the caret's sentence, a lone sentence, text
    /// after the caret on its line. Nothing at all where the field shows no context.
    func testPlanRefusesAParagraphItCantProveWhole() throws {
        let doc = Proxy()
        doc.text = String(repeating: "This is fine. ", count: 30) + "teh end"
        doc.window = 300
        XCTAssertEqual(plan(doc)?.note, Rewrite.selectToReplace, "a window's cut")
        doc.window = nil
        XCTAssertEqual(plan(doc)?.note, Rewrite.selectToReplace, "a long context with no break")
        doc.text = "Dear Sam,\n" + String(repeating: "x", count: 400)
        doc.window = 300
        XCTAssertEqual(plan(doc)?.note, Rewrite.selectToReplace, "a window inside one paragraph")
        doc.text = String(repeating: "x", count: 400) + "\nteh end"
        XCTAssertEqual(plan(doc)?.note, nil, "the break inside the window: proven")
        doc.window = nil

        doc.text = "It is late. teh report"
        doc.sentenceBefore = true
        XCTAssertEqual(doc.documentContextBeforeInput, "teh report")
        XCTAssertEqual(plan(doc)?.note, Rewrite.selectToReplace, "the caret's sentence only")
        doc.sentenceBefore = false
        XCTAssertEqual(Rewrite.plan(before: "teh report", after: "", selected: nil)?.note, Rewrite.selectToReplace,
                       "a lone sentence reads the same")

        let mid = try XCTUnwrap(Rewrite.plan(before: "Dear Sam,\nteh report", after: " is late\nBest", selected: nil))
        XCTAssertEqual(mid.note, Rewrite.selectToReplace, "text after the caret on its line")
        XCTAssertEqual(mid.text, "teh report is late", "the model gets the line as shown")

        doc.text = "Dear Sam,\nteh report"
        doc.hidesContext = true
        XCTAssertNil(plan(doc), "no context: nothing")
        XCTAssertNil(Rewrite.plan(before: "", after: "", selected: ""))
    }

    // MARK: - The write

    func testReplaceTypesOverTheSelectionWithNoDelete() async throws {
        let model = FakeModel()
        model.reply = " The cat sat. "
        let (kb, bar, doc, _) = rig("Hi ", after: " there", model: model)
        doc.selectedText = "teh cat sat"
        bar.press(Shortcuts.rewrite)
        let panel = try XCTUnwrap(bar.rewritePanel)
        panel.run(.fix)
        await panel.task?.value
        XCTAssertEqual(model.calls.map(\.1), ["teh cat sat"])
        XCTAssertEqual(model.calls.map(\.0), [.fix])
        XCTAssertEqual(panel.preview.text, "The cat sat.")
        XCTAssertFalse(panel.replaceButton.isHidden)
        panel.replaceButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(doc.calls, ["The cat sat."], "typed over the selection, no ⌫")
        XCTAssertNil(bar.rewritePanel, "the keys back")
        withExtendedLifetime(kb) {}
    }

    func testReplaceDeletesTheParagraphsCharactersExactly() async throws {
        for para in ["teh report is late", "teh 👨‍👩‍👧 famly 🇧🇬", "cafe\u{301} teh na\u{308}ive"] {
            let model = FakeModel()
            model.reply = "Fixed."
            let (kb, bar, doc, _) = rig("Dear Sam,\n" + para, after: "\nBest", model: model)
            bar.showRewrite(true)
            let panel = try XCTUnwrap(bar.rewritePanel)
            panel.run(.rewrite)
            await panel.task?.value
            XCTAssertEqual(model.calls.map(\.1), [para])
            panel.replaceButton.sendActions(for: .touchUpInside)
            XCTAssertEqual(doc.calls.filter { $0 == "⌫" }.count, para.count, para)
            XCTAssertEqual(doc.calls.last, "Fixed.")
            XCTAssertEqual(doc.text, "Dear Sam,\nFixed.", para)
            XCTAssertEqual(doc.after, "\nBest", "the text after untouched")
            withExtendedLifetime(kb) {}
        }
    }

    /// The field read again at the write: a changed selection or context refuses Replace, the
    /// panel saying why and staying; nothing is written.
    func testReplaceRefusesAFieldThatChanged() throws {
        let selectionCases: [(Proxy) -> Void] = [
            { $0.selectedText = "teh dog" },
            { $0.selectedText = nil },
            { $0.text += "x" },
            { $0.after = " then" },
        ]
        for (i, change) in selectionCases.enumerated() {
            let doc = Proxy()
            doc.text = "Hi "; doc.after = " there"; doc.selectedText = "teh cat"
            let s = try XCTUnwrap(plan(doc))
            change(doc)
            XCTAssertFalse(Rewrite.replace(s, with: "The cat", in: doc), "selection case \(i)")
            XCTAssertEqual(doc.calls, [], "selection case \(i)")
        }
        let paragraphCases: [(Proxy) -> Void] = [
            { $0.text = "Dear Sam,\nteh repor" },
            { $0.text += "t" },
            { $0.after = " now\nBest" },
            { $0.selectedText = "report" },
            { $0.text = "Dear Sam,\nteh report is lat\u{E9}" },   // canonically equal, not unit for unit
            { $0.hidesContext = true },
        ]
        for (i, change) in paragraphCases.enumerated() {
            let doc = Proxy()
            doc.text = "Dear Sam,\nteh report is late\u{301}"; doc.after = "\nBest"
            let s = try XCTUnwrap(plan(doc))
            XCTAssertNil(s.note)
            change(doc)
            XCTAssertFalse(Rewrite.replace(s, with: "Fixed.", in: doc), "paragraph case \(i)")
            XCTAssertEqual(doc.calls, [], "paragraph case \(i)")
        }
        let refused = Proxy()
        refused.text = "teh report"
        let lone = try XCTUnwrap(plan(refused))
        XCTAssertFalse(Rewrite.replace(lone, with: "The report", in: refused), "Insert only")
        XCTAssertEqual(refused.calls, [])
    }

    func testTheBarRefusesAChangedFieldAndThePanelSaysSo() async throws {
        let (kb, bar, doc, _) = rig("Hi ", after: " there")
        doc.selectedText = "teh cat"
        bar.showRewrite(true)
        let panel = try XCTUnwrap(bar.rewritePanel)
        panel.run(.fix)
        await panel.task?.value
        doc.selectedText = "teh dog"
        panel.replaceButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(doc.calls, [])
        XCTAssertTrue(bar.rewritePanel === panel, "the panel stays")
        XCTAssertFalse(panel.note.isHidden)
        XCTAssertEqual(panel.note.text, "The text changed. Select it to replace it")
        withExtendedLifetime(kb) {}
    }

    /// Insert puts the result at the caret, spaced, and never deletes: with a selection it
    /// refuses, `insertText` would type over it. Where the paragraph isn't proven, Replace
    /// isn't offered at all.
    func testInsertNeverDeletes() async throws {
        let (kb, bar, doc, _) = rig("teh report", after: "")
        bar.showRewrite(true)
        let panel = try XCTUnwrap(bar.rewritePanel)
        panel.run(.summarize)
        await panel.task?.value
        XCTAssertTrue(panel.replaceButton.isHidden, "a lone sentence: Insert only")
        XCTAssertEqual(panel.note.text, Rewrite.selectToReplace)
        panel.insertButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(doc.calls, [" Fixed."])
        XCTAssertEqual(doc.text, "teh report Fixed.")

        let sel = Proxy()
        sel.text = "Hi "; sel.selectedText = "teh cat"
        XCTAssertFalse(Rewrite.insert("The cat", in: sel))
        XCTAssertEqual(sel.calls, [], "not over the selection")
        withExtendedLifetime(kb) {}
    }

    // MARK: - Gating

    /// The tile and the key with the model, Full Access, the English layout and an iPhone that
    /// has Apple Intelligence; where it's off or downloading the panel says so, with no rows.
    func testTheTileAndKeyNeedFullAccessEnglishAndTheModel() throws {
        func shows(_ bar: SuggestionBar) -> (tile: Bool, key: Bool) {
            (bar.menuItems.contains { $0.title == "Rewrite" },
             Self.caps(bar.toolbar!).contains { $0.accessibilityLabel == "rewrite" })
        }
        let (kb, bar, _, _) = rig()
        XCTAssertTrue(shows(bar) == (true, true))
        XCTAssertNotNil(UIImage(systemName: try XCTUnwrap(Shortcuts.rewrite.systemImage)))
        for command in Rewrite.Command.allCases { XCTAssertNotNil(UIImage(systemName: command.symbol), command.title) }
        kb.layout = .bulgarian
        XCTAssertTrue(shows(bar) == (false, false), "Bulgarian: the model has none")
        kb.layout = .english
        XCTAssertTrue(shows(bar) == (true, true))

        let (kb2, noAccess, _, _) = rig(fullAccess: false)
        XCTAssertTrue(shows(noAccess) == (false, false), "no Full Access")
        let (kb3, noModel, _, _) = rig()
        noModel.rewrite = nil
        noModel.toolbar?.reload()
        XCTAssertTrue(shows(noModel) == (false, false), "no model: iOS 16–25")
        noModel.showRewrite(true)
        XCTAssertNil(noModel.rewritePanel)
        let (kb4, ineligible, _, _) = rig(availability: .deviceNotEligible)
        XCTAssertTrue(shows(ineligible) == (false, false), "an iPhone without Apple Intelligence")

        for reason in [Rewrite.Availability.appleIntelligenceNotEnabled, .modelNotReady] {
            let model = FakeModel()
            let (kb5, off, _, _) = rig("Dear Sam,\nteh report", model: model, availability: reason)
            XCTAssertTrue(shows(off) == (true, true), "\(reason): it can be turned on")
            off.showRewrite(true)
            let panel = try XCTUnwrap(off.rewritePanel)
            XCTAssertEqual(panel.empty.text, reason.reason)
            XCTAssertFalse(panel.empty.isHidden)
            XCTAssertTrue(panel.table.isHidden, "no rows")
            panel.run(.fix)
            XCTAssertNil(panel.task)
            XCTAssertTrue(model.calls.isEmpty)
            withExtendedLifetime(kb5) {}
        }
        XCTAssertEqual(Rewrite.Availability.appleIntelligenceNotEnabled.reason, "Turn on Apple Intelligence in Settings")
        XCTAssertEqual(Rewrite.Availability.deviceNotEligible.reason, "This iPhone doesn't support Apple Intelligence")
        XCTAssertEqual(Rewrite.Availability.modelNotReady.reason, "The model is still downloading — try again soon")
        XCTAssertNil(Rewrite.Availability.available.reason)
        withExtendedLifetime((kb, kb2, kb3, kb4)) {}
    }

    func testTheKeyIsTheToolbarsOnlyAndAddedInTheEditor() {
        XCTAssertEqual(Shortcuts.hostKey("rewrite"), .rewrite)
        XCTAssertTrue(Shortcuts.Bar.toolbar.catalog.contains(Shortcuts.rewrite))
        XCTAssertFalse(Shortcuts.Bar.toolbar.defaults.contains(Shortcuts.rewrite), "added in the editor")
        XCTAssertFalse(Shortcuts.Bar.terminal.catalog.contains(Shortcuts.rewrite), "a shell's text isn't prose")
    }

    /// The key and the tile open the panel, the key again closes it.
    func testTheKeyAndTheTileOpenThePanel() throws {
        let (kb, bar, _, view) = rig("Dear Sam,\nteh report")
        bar.press(Shortcuts.rewrite)
        let panel = try XCTUnwrap(bar.rewritePanel)
        XCTAssertTrue(panel.superview === view, "over the keys")
        XCTAssertEqual(panel.table.numberOfRows(inSection: 0), 3)
        XCTAssertEqual((0..<3).map { panel.tableView(panel.table, cellForRowAt: IndexPath(row: $0, section: 0)).accessibilityLabel },
                       ["Fix", "Rewrite", "Summarize"])
        bar.press(Shortcuts.rewrite)
        XCTAssertNil(bar.rewritePanel)
        bar.showMenu(true)
        try XCTUnwrap(bar.menuPanel?.tiles.first { $0.accessibilityLabel == "Rewrite" }).sendActions(for: .touchUpInside)
        XCTAssertNotNil(bar.rewritePanel)
        withExtendedLifetime(kb) {}
    }

    // MARK: - Cancel

    /// Closing the panel, ✕, or the keyboard going while the model works: its answer writes
    /// nothing and shows nowhere.
    func testCancelWhileTheModelWorksWritesNothing() async throws {
        for way in ["close", "✕", "disappear"] {
            let model = FakeModel()
            model.holds = true
            let (kb, bar, doc, _) = rig("Dear Sam,\nteh report", model: model)
            bar.showRewrite(true)
            let panel = try XCTUnwrap(bar.rewritePanel)
            panel.run(.fix)
            while model.pending == nil { await Task.yield() }
            XCTAssertFalse(panel.cancelButton.isHidden, way)
            XCTAssertTrue(panel.spinner.isAnimating, way)
            let task = try XCTUnwrap(panel.task)
            switch way {
            case "close": panel.onClose?()
            case "✕": panel.cancelButton.sendActions(for: .touchUpInside)
            default: bar.disappear()
            }
            model.pending?.resume(returning: "Fixed.")
            await task.value
            XCTAssertNil(panel.result, way)
            XCTAssertTrue(panel.resultView.isHidden, way)
            XCTAssertEqual(doc.calls, [], way)
            XCTAssertEqual(doc.text, "Dear Sam,\nteh report", way)
            if way == "✕" { XCTAssertTrue(bar.rewritePanel === panel, "✕ keeps the panel, the rows back") } else { XCTAssertNil(bar.rewritePanel, way) }
            withExtendedLifetime(kb) {}
        }
    }

    /// A model error is the panel's one line, the rows under it again (#612): the controller's
    /// named line (`Rewrite.Failure`, #660), else the generic one, over the three rows. The rows
    /// still run.
    func testAModelErrorIsOneLine() async throws {
        struct Failed: Error {}
        let model = FakeModel()
        let (kb, bar, doc, _) = rig("Dear Sam,\nteh report", model: model)
        var thrown: Error?
        bar.rewrite = { if let e = thrown { throw e }; return try await model.run($0, $1) }
        for (error, line) in [(Rewrite.Failure(line: "Too long for the model. Select less") as Error, "Too long for the model. Select less"),
                              (Failed(), Rewrite.failed)] {
            bar.showRewrite(true)
            let panel = try XCTUnwrap(bar.rewritePanel)
            thrown = error
            panel.run(.fix)
            await panel.task?.value
            XCTAssertEqual(panel.line, line)
            XCTAssertFalse(panel.table.isHidden, "the rows, to try again")
            XCTAssertTrue(panel.empty.isHidden)
            XCTAssertNil(panel.result)
            XCTAssertEqual(panel.table.numberOfRows(inSection: 0), 3, "the rows only")
            XCTAssertTrue(panel.table.tableHeaderView?.subviews.contains(panel.lineLabel) == true)
            XCTAssertEqual(panel.lineLabel.text, line)
            thrown = nil
            panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 2, section: 0))
            await panel.task?.value
            XCTAssertEqual(panel.result?.text, "Fixed.", "a row still runs after the line")
            XCTAssertEqual(model.calls.last?.0, .summarize)
            bar.showRewrite(false)
        }
        XCTAssertEqual(doc.calls, [])
        withExtendedLifetime(kb) {}
    }

    /// The simulator's bridged error (#660 QA u): GenerationError's domain, code -1, over a
    /// ModelManagerError 1026 in the multiple-underlying list; a UnifiedAssetFramework error
    /// under `NSUnderlyingErrorKey`, deeper; neither, or deeper than the bound, is not missing assets.
    func testAssetsMissingWalksTheUnderlyingChain() {
        let top = "FoundationModels.LanguageModelSession.GenerationError"
        func e(_ domain: String, _ code: Int = -1, under: Error? = nil, many: [Error]? = nil) -> NSError {
            var info: [String: Any] = [:]
            info[NSUnderlyingErrorKey] = under
            info[NSMultipleUnderlyingErrorsKey] = many
            return NSError(domain: domain, code: code, userInfo: info)
        }
        XCTAssertTrue(Rewrite.assetsMissing(e(top, many: [e("ModelManagerServices.ModelManagerError", 1026)])))
        XCTAssertTrue(Rewrite.assetsMissing(e(top, under: e("x", under: e("com.apple.UnifiedAssetFramework", 5000)))))
        XCTAssertTrue(Rewrite.assetsMissing(e("com.apple.UnifiedAssetFramework", 5000)))
        XCTAssertFalse(Rewrite.assetsMissing(e(top, many: [e("ModelManagerServices.ModelManagerError", 1000)])), "another code")
        XCTAssertFalse(Rewrite.assetsMissing(e(top, under: e(NSCocoaErrorDomain, 4))))
        var deep = e("com.apple.UnifiedAssetFramework", 5000)
        for _ in 0..<5 { deep = e("x", under: deep) }
        XCTAssertFalse(Rewrite.assetsMissing(deep), "past the bound")
        struct Plain: Error {}
        XCTAssertFalse(Rewrite.assetsMissing(Plain()))
    }

    /// QA H (#660): the line has its own room over the rows, at the top with Fix in view, at
    /// every Key Size and in landscape. A plain table's section footer floated over the last
    /// rows. No line, no header.
    func testTheLineNeverCoversTheRows() {
        for compact in [false, true] {
            for size in KeyboardSettings.KeySize.allCases {
                let note = "\(compact ? "landscape" : "portrait") \(size)"
                let panel = AIPanel(availability: .available) { _, _ in "" }
                panel.frame = CGRect(x: 0, y: 0, width: compact ? 750 : 375,
                                     height: TerminalKeyboard.keysHeight(compact: compact, size: size) + TerminalKeyboard.extensionBottomInset)
                panel.layoutIfNeeded()
                panel.showList(Rewrite.failed)
                panel.layoutIfNeeded()
                let table = panel.table
                guard let header = table.tableHeaderView else { XCTFail("\(note): the line"); continue }
                let shown = CGRect(origin: table.contentOffset, size: table.bounds.size)
                XCTAssertGreaterThan(header.frame.height, 20, note)
                XCTAssertTrue(shown.insetBy(dx: 0, dy: -0.5).contains(header.frame), "\(note): the line whole in view")
                XCTAssertFalse(table.visibleCells.isEmpty, note)
                for cell in table.visibleCells { XCTAssertFalse(header.frame.intersects(cell.frame), "\(note): \(cell.accessibilityLabel ?? "")") }
                XCTAssertTrue(shown.intersects(table.rectForRow(at: IndexPath(row: 0, section: 0))), "\(note): Fix in view")
                XCTAssertTrue(panel.lineLabel.frame.width > 200 && panel.lineLabel.frame.minX > 0, "\(note): the rows' insets")
                let rows = (0..<3).map { IndexPath(row: $0, section: 0) }
                func details() -> [String?] {
                    rows.map { (panel.tableView(table, cellForRowAt: $0).contentConfiguration as? UIListContentConfiguration)?.secondaryText }
                }
                XCTAssertEqual(details().compactMap { $0 }, [], "\(note): no subtitles under a line")
                if !compact {
                    for row in rows {
                        XCTAssertTrue(shown.insetBy(dx: 0, dy: -0.5).contains(table.rectForRow(at: row)), "\(note): row \(row.row) whole in view")
                    }
                }
                panel.showList()
                panel.layoutIfNeeded()
                XCTAssertNil(table.tableHeaderView, "\(note): no line, no header")
                XCTAssertEqual(details(), Rewrite.Command.allCases.map(\.detail), "\(note): the subtitles back")
            }
        }
    }
}
