import XCTest
import UIKit
@testable import Prosper

/// Numbers: Key (#625): the system keyboard's digit row as a 123 key that swaps the letters
/// for a numpad, the row's height the toolbar's second row, the keyboard's height the same,
/// and Hide Toolbar on the Numpad lending the numpad the bar's height. Driven as the
/// extension's controller wires it: a fake field, the bar attached and hosted, its toolbar.
@MainActor
final class NumbersKeyTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy
    typealias Key = TerminalKeyboard.Key

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "NumbersKeyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The extension's keyboard, its bar and toolbar, hosted in a 402 pt wide view in a window.
    /// Keep all four: the keyboard holds the proxy and the bar weakly.
    private func rig(_ layout: TerminalKeyboard.Layout = .english,
                     numbers: KeyboardSettings.Numbers = .key) -> (TerminalKeyboard, SuggestionBar, Proxy, UIView) {
        let doc = Proxy()
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard(layout: layout)
        kb.target = doc
        kb.bottomInset = TerminalKeyboard.extensionBottomInset
        kb.offersEmoji = false
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults), layout: layout))
        bar.attach(kb)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        // A window with no scene takes its size class from its own size; the phone's is regular.
        if #available(iOS 17, *) { window.traitOverrides.verticalSizeClass = .regular }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        window.addSubview(view)
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults }
        kb.allowsNumbersKey = true
        kb.settings.numbers = numbers
        fit(view)
        return (kb, bar, doc, view)
    }

    /// The view at the height its bar and keys add up to, laid out; that height.
    @discardableResult
    private func fit(_ view: UIView) -> CGFloat {
        let h = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required,
                                             verticalFittingPriority: .fittingSizeLevel).height
        view.frame.size.height = h
        view.layoutIfNeeded()
        return h
    }

    private func chars(_ keys: [Key]) -> String {
        keys.map { if case .char(let c) = $0 { return c } else { return "|" } }.joined()
    }

    /// The cap showing `title` (its accessibility label for a glyph cap).
    private func cap(_ kb: TerminalKeyboard, _ title: String) throws -> UIButton {
        try XCTUnwrap(kb.subviews.compactMap { $0 as? UIButton }
            .first { !$0.isHidden && ($0.title(for: .normal) ?? $0.accessibilityLabel) == title }, title)
    }

    /// A finger down and up on `title`'s cap.
    private func tap(_ kb: TerminalKeyboard, _ title: String) throws {
        kb.superview?.layoutIfNeeded()   // a swap lays out before the next touch
        let f = try cap(kb, title).frame
        kb.track(.began, id: 1, at: CGPoint(x: f.midX, y: f.midY))
        kb.track(.ended, id: 1, at: CGPoint(x: f.midX, y: f.midY))
    }

    /// The toolbar's shown rows: the stacks holding its caps, less a hidden one.
    private func toolbarRows(_ bar: SuggestionBar) throws -> Int {
        func caps(_ v: UIView) -> [KeyCapButton] { v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) } }
        let toolbar = try XCTUnwrap(bar.toolbar)
        return Set(caps(toolbar).compactMap { $0.superview }.filter { !$0.isHidden }.map(ObjectIdentifier.init)).count
    }

    // MARK: Setting

    func testNumbersSettingDecodesWithRowAndShownToolbarByDefault() {
        let fresh = KeyboardSettings()
        XCTAssertEqual(fresh.numbers, .row, "nobody's keys change unasked")
        XCTAssertFalse(fresh.numpadHidesToolbar)
        XCTAssertEqual(KeyboardSettings(defaults).numbers, .row, "unset is Row")
        defaults.set("key", forKey: KeyboardSettings.Key.numbers)
        defaults.set(true, forKey: KeyboardSettings.Key.numpadHidesToolbar)
        let set = KeyboardSettings(defaults)
        XCTAssertEqual(set.numbers, .key)
        XCTAssertTrue(set.numpadHidesToolbar)
        defaults.set("pad", forKey: KeyboardSettings.Key.numbers)
        XCTAssertEqual(KeyboardSettings(defaults).numbers, .row, "an unknown value is Row")
        XCTAssertEqual(KeyboardSettings.current(fullAccess: false).numbers, .row, "no Full Access: defaults")
    }

    // MARK: Row and Key

    func testRowKeepsTheDigitRowAndTheAppsKeyboardAlwaysDoes() {
        let (kb, bar, _, _) = rig(numbers: .row)
        XCTAssertEqual(kb.shownKeys.map(chars), ["1234567890", "qwertyuiop", "asdfghjkl", "|zxcvbnm|", ".,/|?|"])
        XCTAssertFalse(kb.shownKeys.joined().contains(.numbers))
        XCTAssertEqual(kb.numberRowHeight, 0)
        bar.showsToolbar = true
        XCTAssertFalse(try XCTUnwrap(bar.toolbar).twoRows)

        let app = TerminalKeyboard()   // the terminal's: no toolbar, `allowsNumbersKey` never set
        app.settings.numbers = .key
        XCTAssertEqual(app.shownKeys.first.map(chars), "1234567890", "the app's keyboard keeps its digits")
        XCTAssertFalse(app.shownKeys.joined().contains(.numbers))
    }

    func testKeyDropsTheDigitRowForA123KeyAndTheToolbarTakesItsHeight() throws {
        for size in KeyboardSettings.KeySize.allCases {
            let (kb, bar, _, view) = rig(numbers: .row)
            kb.settings.keySize = size
            let rowTotal = fit(view), rowBar = bar.frame.height
            kb.settings.numbers = .key
            XCTAssertEqual(fit(view), rowTotal, accuracy: 1, "\(size): the same keyboard height")
            let m = TerminalKeyboard.metrics(compact: false, size: size)
            XCTAssertEqual(bar.frame.height, rowBar + m.row + m.gap, accuracy: 0.5, "\(size): the bar has the row's")
            XCTAssertEqual(kb.shownKeys.map(chars), ["qwertyuiop", "asdfghjkl", "|zxcvbnm|", "|.,/|?|"])
            XCTAssertEqual(kb.shownKeys.last?.first, .numbers, "123 leads the bottom row, as on iOS")
            XCTAssertEqual(try cap(kb, "123").frame.minY, try cap(kb, "space").frame.minY)
        }

        let (kb, bar, _, view) = rig()
        kb.settings.bottomHidden = "/?"
        kb.showsGlobe = true
        XCTAssertEqual(kb.shownKeys.last, [.numbers, .globe, .char("."), .char(","), .space, .ret],
                       "Keys Beside Space still applies; 123 before the globe")
        kb.settings.bottomOrder = " .,/?"
        XCTAssertEqual(kb.shownKeys.last, [.numbers, .globe, .space, .char("."), .char(","), .ret])

        bar.showsToolbar = true
        fit(view)
        XCTAssertTrue(try XCTUnwrap(bar.toolbar).twoRows)
        XCTAssertEqual(try toolbarRows(bar), 2, "the toolbar in two rows")
        XCTAssertEqual(try XCTUnwrap(bar.toolbar).frame.height, bar.frame.height)
        bar.showsToolbar = false
        fit(view)
        XCTAssertEqual(try toolbarRows(bar), 1, "one toolbar row over the suggestions")
        XCTAssertFalse(try XCTUnwrap(bar.toolbar).isHidden)
        XCTAssertFalse(bar.slotButtons[0].isHidden)
        XCTAssertGreaterThanOrEqual(bar.slotButtons[0].frame.minY, try XCTUnwrap(bar.toolbar).frame.maxY,
                                    "the slots under the toolbar's row")
        XCTAssertEqual(ShortcutBar.balancedSplit([40, 40, 40, 40, 100], spacing: 6), 3, "the longer row is shortest")
        XCTAssertEqual(ShortcutBar.balancedSplit([50, 50], spacing: 6), 1)
    }

    // MARK: Numpad

    func testThe123KeyOpensTheNumpadWhoseDigitsTypeUncorrected() throws {
        let (kb, _, doc, _) = rig()
        for c in "teh" { kb.press(.char(String(c))) }
        try tap(kb, "123")
        XCTAssertTrue(kb.showsNumpad)
        XCTAssertEqual(kb.shownKeys, TerminalKeyboard.numpadRows)
        kb.superview?.layoutIfNeeded()   // as the next frame does
        let seven = try cap(kb, "7").frame, q = TerminalKeyboard.keyGap
        XCTAssertGreaterThan(seven.width, 1.5 * (402 - 6 - 9 * q) / 10, "a numpad key is wider than a letter key")
        XCTAssertGreaterThanOrEqual(seven.height, TerminalKeyboard.rowHeight - 0.5)
        try tap(kb, ",")
        XCTAssertEqual(doc.text, "teh,", "the numpad never autocorrects")
        try tap(kb, "7")
        try tap(kb, "space")
        try tap(kb, "1")
        XCTAssertEqual(doc.text, "teh,7 1", "the digits and the space as typed")
        let one = try cap(kb, "1")
        XCTAssertEqual(one.subviews.compactMap { $0 === one.titleLabel ? nil : ($0 as? UILabel)?.text ?? nil }.filter { !$0.isEmpty }, [],
                       "no hold symbols on the numpad")
        XCTAssertNil(kb.previewText, "nor previews")
    }

    func testABCGoesBackToTheLetters() throws {
        let (kb, _, doc, _) = rig()
        kb.press(.numbers)
        XCTAssertEqual(try cap(kb, "ABC").accessibilityLabel, "letters")
        try tap(kb, "ABC")
        XCTAssertFalse(kb.showsNumpad)
        XCTAssertEqual(kb.shownKeys.first.map(chars), "qwertyuiop")
        try tap(kb, "q")
        XCTAssertEqual(doc.text, "q")
        kb.press(.numbers)
        kb.settings.numbers = .row
        XCTAssertFalse(kb.showsNumpad, "Row puts the numpad away")
        XCTAssertEqual(kb.shownKeys.first.map(chars), "1234567890")
    }

    func testHideToolbarGivesTheNumpadTheBarsHeightAndTakesItBack() throws {
        let (kb, bar, _, view) = rig()
        let total = fit(view), barHeight = bar.frame.height, keys = kb.frame.height
        kb.press(.numbers)
        XCTAssertEqual(fit(view), total, accuracy: 0.5)
        XCTAssertEqual(bar.frame.height, barHeight, "off: the bar stays on the numpad")
        XCTAssertFalse(bar.isHidden)

        kb.settings.numpadHidesToolbar = true
        XCTAssertEqual(fit(view), total, accuracy: 1, "the same keyboard height")
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(bar.frame.height, 0, accuracy: 0.5)
        XCTAssertEqual(kb.frame.height, keys + barHeight, accuracy: 0.5, "the numpad has the bar's height")
        let seven = try cap(kb, "7").frame.height
        XCTAssertGreaterThan(seven, TerminalKeyboard.rowHeight + 10, "its keys grow into it")

        kb.press(.numbers)
        XCTAssertEqual(fit(view), total, accuracy: 0.5)
        XCTAssertFalse(bar.isHidden, "the letters get the bar back")
        XCTAssertEqual(bar.frame.height, barHeight, accuracy: 0.5)
        XCTAssertEqual(kb.frame.height, keys, accuracy: 0.5)
    }

    // MARK: Bulgarian

    func testBulgarianHasTheKeyTooAndTheSameNumpad() throws {
        let (kb, _, doc, view) = rig(.bulgarian, numbers: .row)
        let total = fit(view)
        kb.settings.numbers = .key
        XCTAssertEqual(fit(view), total, accuracy: 1)
        XCTAssertEqual(kb.shownKeys.map(chars), ["явертъуиопю", "асдфгхйклшщ", "|зьцжбнмч|", "|.,/|?|"])
        try tap(kb, "123")
        XCTAssertEqual(kb.shownKeys, TerminalKeyboard.numpadRows)
        try tap(kb, "5")
        try tap(kb, "ABC")
        try tap(kb, "я")
        XCTAssertEqual(doc.text, "5я")
    }
}
