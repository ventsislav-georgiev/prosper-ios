import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Prosper

/// The keyboards' clipboard history (#597): the store (dedupe, cap, age-out, pins, images
/// downsampled), what it keeps (a fresh changeCount, never a concealed clip), a pick from
/// its panel, and its toolbar key. A named pasteboard and a throwaway directory throughout.
@MainActor
final class ClipboardHistoryTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy

    private var dir: URL!
    private var pb: UIPasteboard!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardHistoryTests-\(UUID())")
        pb = UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true)
        suite = "ClipboardHistoryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        UIPasteboard.remove(withName: pb.name)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// `s` copied, then pasted through the keyboard.
    private func paste(_ s: String, into h: ClipboardHistory) {
        pb.string = s
        h.record(s, from: pb)
    }

    /// A `width`×`height` JPEG on disk.
    private func jpeg(_ width: CGFloat, _ height: CGFloat) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { c in
            UIColor.systemTeal.setFill()
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("source-\(UUID()).jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }

    private static func pixels(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? CGFloat, let h = p[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// The image at `url` kept as the panel's Paste would keep it.
    private func captureImage(_ url: URL, into h: ClipboardHistory) throws {
        pb.setData(try Data(contentsOf: url), forPasteboardType: UTType.jpeg.identifier)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))
        let done = expectation(description: "kept")
        h.capture([provider], from: pb) { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testSameTextMovesUpNewestFirst() {
        let h = ClipboardHistory(dir: dir)
        for s in ["one", "two", "one", "  \n"] { paste(s, into: h) }
        XCTAssertEqual(h.clips.map(\.text), ["one", "two"], "the same text once, on top; blank never")
        XCTAssertEqual(ClipboardHistory(dir: dir).clips.map(\.text), ["one", "two"], "on disk: the other keyboard sees it")
    }

    /// Kept only on a changeCount not kept yet, and never with a concealed or transient type:
    /// both read prompt-free (`changeCount`, `types`).
    func testKeepsOnlyAFreshUnconcealedClip() {
        let h = ClipboardHistory(dir: dir)
        XCTAssertFalse(h.fresh(pb), "empty")
        pb.string = "alpha"
        XCTAssertTrue(h.fresh(pb))
        h.record("alpha", from: pb)
        XCTAssertFalse(h.fresh(pb), "kept")
        h.record("alpha again", from: pb)
        XCTAssertEqual(h.clips.map(\.text), ["alpha"], "an unchanged count isn't kept twice")

        for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            pb.setItems([[UTType.utf8PlainText.identifier: "s3cret", type: Data()]])
            XCTAssertTrue(pb.hasStrings, type)
            XCTAssertFalse(h.fresh(pb), type)
            h.record("s3cret", from: pb)
            XCTAssertEqual(h.clips.map(\.text), ["alpha"], type)
        }
        pb.string = "beta"
        XCTAssertTrue(h.fresh(pb))
    }

    /// `cap` unpinned, the oldest go; past `maxAge` the unpinned go; Clear all and delete.
    func testCapAndAgeOutSparePinned() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let h = ClipboardHistory(dir: dir, cap: 3, maxAge: 100)
        h.now = { now }
        paste("pinned", into: h)
        let pinned = try XCTUnwrap(h.clips.first)
        h.pin(pinned.id, true)
        for s in ["a", "b", "c", "d"] { paste(s, into: h) }
        XCTAssertEqual(h.clips.map(\.text), ["d", "c", "b", "pinned"], "three unpinned; the pinned one stays")
        now += 101
        paste("e", into: h)
        XCTAssertEqual(h.clips.map(\.text), ["e", "pinned"], "aged out, but not the pinned one")
        paste("pinned", into: h)
        XCTAssertEqual(h.clips.map(\.text), ["pinned", "e"])
        XCTAssertEqual(h.clips.first?.pinned, true, "moving up keeps the pin")
        h.clear()
        XCTAssertEqual(h.clips.map(\.text), ["pinned"], "Clear all keeps the pinned")
        h.delete(try XCTUnwrap(h.clips.first).id)
        XCTAssertEqual(h.clips, [])
    }

    /// An image goes in downsampled to `imageSide`, the same one once, its thumbnail smaller
    /// still; its file goes with its clip.
    func testImagesAreDownsampledKeptOnceAndTheirFilesGo() throws {
        let h = ClipboardHistory(dir: dir)
        let big = try jpeg(3000, 1500)
        try captureImage(big, into: h)
        let clip = try XCTUnwrap(h.clips.first)
        let name = try XCTUnwrap(clip.image)
        XCTAssertNil(clip.text)
        XCTAssertEqual(Self.pixels(h.url(name)), CGSize(width: 1024, height: 512))
        XCTAssertLessThanOrEqual(try XCTUnwrap(h.thumbnail(clip, side: 64)).size.width, 64)

        try captureImage(big, into: h)
        XCTAssertEqual(h.clips.count, 1, "the same image once")
        let small = try jpeg(200, 100)
        try captureImage(small, into: h)
        XCTAssertEqual(h.clips.count, 2)
        XCTAssertEqual(Self.pixels(h.url(try XCTUnwrap(h.clips.first?.image))), CGSize(width: 200, height: 100), "never up")

        h.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.url(name).path), "the file goes with its clip")
    }

    /// A keyboard over a fake field, the bar hosted in a view, its toolbar the default one and
    /// the clipboard history's key.
    private func rig(_ text: String, history: ClipboardHistory?, fullAccess: Bool = true)
        -> (TerminalKeyboard, SuggestionBar, Proxy, UIView) {
        let doc = Proxy()
        doc.text = text
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults)))
        bar.history = history
        let pb = self.pb
        if fullAccess { bar.suggestions.pasteboard = { pb } }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        bar.attach(kb)
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults + [Shortcuts.clipboard] }
        return (kb, bar, doc, view)
    }

    private static func caps(_ v: UIView) -> [KeyCapButton] {
        v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) }
    }

    /// A text pick types it at the cursor and copies it; an image pick only copies it (a proxy
    /// takes text alone). Either closes the panel; neither comes back as a fresh clip.
    func testPickTypesTextAndCopiesItButOnlyCopiesAnImage() throws {
        let h = ClipboardHistory(dir: dir)
        let image = try jpeg(300, 200)
        try captureImage(image, into: h)
        paste("hello", into: h)
        let (kb, bar, doc, view) = rig("say ", history: h)

        bar.press(Shortcuts.clipboard)
        var panel = try XCTUnwrap(bar.clipsPanel)
        XCTAssertTrue(panel.superview === view)
        XCTAssertEqual(panel.clips.map { $0.text ?? "image" }, ["hello", "image"])
        let cell = panel.tableView(panel.table, cellForRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(cell.accessibilityLabel, "Image")
        pb.string = "elsewhere"
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(doc.text, "say hello")
        XCTAssertEqual(pb.string, "hello")
        XCTAssertNil(bar.clipsPanel, "a pick closes the panel")
        XCTAssertFalse(h.fresh(pb), "our own write isn't offered")
        XCTAssertEqual(bar.suggestions.memory.retiredClip, pb.changeCount)

        bar.press(Shortcuts.clipboard)
        panel = try XCTUnwrap(bar.clipsPanel)
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(doc.text, "say hello", "an image is never typed")
        XCTAssertFalse(pb.hasStrings)
        XCTAssertTrue(pb.hasImages)
        let stored = try Data(contentsOf: h.url(try XCTUnwrap(h.clips.last?.image)))
        XCTAssertEqual(pb.data(forPasteboardType: UTType.jpeg.identifier), stored)
        XCTAssertNil(bar.clipsPanel)

        bar.press(Shortcuts.clipboard)
        XCTAssertNotNil(bar.clipsPanel)
        bar.press(Shortcuts.clipboard)
        XCTAssertNil(bar.clipsPanel, "the key again: the keys back")
        withExtendedLifetime(kb) {}
    }

    /// The toolbar's and the terminal's (#603), added in the editor, a labelled iOS 16 symbol;
    /// on the toolbar only with Full Access and a store, like copy and cut line.
    func testClipboardKeyIsAddedInTheEditorAndNeedsFullAccess() throws {
        XCTAssertEqual(Shortcuts.hostKey(Shortcuts.clipboard.id), .clipboard)
        XCTAssertTrue(Shortcuts.Bar.toolbar.catalog.contains(Shortcuts.clipboard))
        XCTAssertTrue(Shortcuts.Bar.terminal.catalog.contains(Shortcuts.clipboard))
        XCTAssertFalse(Shortcuts.Bar.terminal.catalog.contains { $0.id == Shortcuts.dictate.id })
        XCTAssertFalse(Shortcuts.Bar.terminal.defaults.contains { $0.id == Shortcuts.clipboard.id })
        XCTAssertFalse(Shortcuts.defaults.contains { $0.id == Shortcuts.clipboard.id })
        XCTAssertFalse(Shortcuts.Bar.toolbar.defaults.contains(Shortcuts.clipboard), "added in the editor")
        XCTAssertEqual(Shortcuts.clipboard.systemImage, "list.clipboard")
        XCTAssertNotNil(UIImage(systemName: "list.clipboard"))

        let label = Shortcuts.clipboard.label
        let (_, none, _, _) = rig("", history: ClipboardHistory(dir: dir), fullAccess: false)
        XCTAssertFalse(Self.caps(try XCTUnwrap(none.toolbar)).contains { $0.accessibilityLabel == label }, "no Full Access")
        let (_, storeless, _, _) = rig("", history: nil)
        XCTAssertFalse(Self.caps(try XCTUnwrap(storeless.toolbar)).contains { $0.accessibilityLabel == label }, "no store")
        let (kb, full, _, _) = rig("", history: ClipboardHistory(dir: dir))
        XCTAssertTrue(Self.caps(try XCTUnwrap(full.toolbar)).contains { $0.accessibilityLabel == label })
        withExtendedLifetime(kb) {}
    }

    /// The keyboard's own copy (copy line) goes in, and so does the toolbar's Paste.
    func testOwnCopyAndToolbarPasteAreKept() throws {
        let h = ClipboardHistory(dir: dir)
        let (kb, bar, doc, _) = rig("first line", history: h)
        bar.press(try XCTUnwrap(Shortcuts.hostOnly.first { $0.id == "copyLine" }))
        let deadline = Date() + 2
        while h.clips.isEmpty, Date() < deadline { doc.catchUp(); kb.pollCaret(); RunLoop.main.run(until: Date() + 0.01) }
        XCTAssertEqual(h.clips.map(\.text), ["first line"])

        pb.string = "pasted"
        bar.showsToolbar = true
        let toolbar = try XCTUnwrap(bar.toolbar)
        toolbar.paste(itemProviders: [NSItemProvider(object: "pasted" as NSString)])
        while h.clips.count < 2, Date() < deadline + 2 { RunLoop.main.run(until: Date() + 0.01) }
        XCTAssertEqual(h.clips.map(\.text), ["pasted", "first line"])
        withExtendedLifetime(kb) {}
    }
    /// A cut line in batches (a UITextView's line window) is one row, the whole line; rows
    /// from before stay as they were, one equal to a batch's text too, and a pin on the line
    /// moves up with it (#597 QA: "gamma line x" and "amma line x" both kept).
    func testCutLineInBatchesKeepsOneRow() throws {
        let h = ClipboardHistory(dir: dir)
        for s in ["older", "a line x", "gamma line x"] { paste(s, into: h) }
        h.pin(try XCTUnwrap(h.clips.first).id, true)
        let (kb, bar, doc, _) = rig("alpha one beta two\ngamma line x", history: h)
        doc.window = 5
        bar.press(try XCTUnwrap(Shortcuts.hostOnly.first { $0.id == "cutLine" }))
        let before = pb.changeCount
        for _ in 1...3_000 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text + (doc.after ?? ""), "alpha one beta two")
        XCTAssertEqual(pb.string, "gamma line x")
        XCTAssertGreaterThan(pb.changeCount - before, 1, "in batches")
        XCTAssertEqual(h.clips.map(\.text), ["gamma line x", "a line x", "older"])
        XCTAssertEqual(h.clips.map(\.pinned), [true, false, false])
        withExtendedLifetime(kb) {}
    }

    /// A blank clip the panel's Paste takes isn't kept, and the Paste goes (#597 QA: it stayed).
    func testBlankPasteIsNotOfferedAgain() {
        let h = ClipboardHistory(dir: dir)
        pb.string = "   \n  "
        let panel = ClipboardPanel(history: h, pasteboard: pb)
        XCTAssertFalse(panel.pasteControl.isHidden)
        panel.paste(itemProviders: [NSItemProvider(object: "   \n  " as NSString)])
        let deadline = Date() + 5
        while !panel.pasteControl.isHidden, Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
        XCTAssertTrue(panel.pasteControl.isHidden)
        XCTAssertEqual(h.clips, [])
    }

    /// `h`'s reads counted, through its own or `fake`.
    private func counting(_ h: ClipboardHistory, _ fake: ((UIPasteboard) -> (text: String?, image: Data?))? = nil) -> () -> Int {
        var reads = 0
        let real = fake ?? h.read
        h.read = { reads += 1; return real($0) }
        return { reads }
    }

    /// Save Copies Automatically turned off, or no Full Access: a clip copied elsewhere is
    /// never read (Allow Paste), nor kept: as before #601.
    func testSaveCopiesOffNeverReads() {
        let h = ClipboardHistory(dir: dir)
        let reads = counting(h)
        defaults.set(false, forKey: KeyboardSettings.Key.saveCopies)
        let (kb, off, _, _) = rig("", history: h)
        off.suggestions.settings = KeyboardSettings(defaults)
        let (kb2, noAccess, _, _) = rig("", history: h, fullAccess: false)
        noAccess.suggestions.settings = KeyboardSettings.current(fullAccess: false)
        pb.string = "elsewhere"
        off.refresh()
        noAccess.refresh()
        XCTAssertEqual(reads(), 0)
        XCTAssertEqual(h.clips, [])
        XCTAssertTrue(h.fresh(pb), "the panel's Paste still offers it")
        withExtendedLifetime((kb, kb2)) {}
    }

    /// On, by default: the key never written (#601). A fresh clip read once and kept once, the bar's Paste still offered and its
    /// tap not kept twice; one refused isn't asked again, and stays the panel's to Paste; a
    /// concealed one is never read.
    func testSaveCopiesKeepsAFreshClipOnce() throws {
        let h = ClipboardHistory(dir: dir)
        var reads = counting(h)
        let (kb, bar, doc, _) = rig("", history: h)
        XCTAssertNil(defaults.object(forKey: KeyboardSettings.Key.saveCopies))
        bar.suggestions.settings = KeyboardSettings(defaults)
        pb.string = "alpha"
        bar.refresh()
        XCTAssertEqual(h.clips.map(\.text), ["alpha"])
        XCTAssertEqual(reads(), 1)
        XCTAssertEqual(bar.state, .paste, "the fresh clip's Paste stays")
        let saved = h.clips.map(\.id)
        bar.paste(itemProviders: [NSItemProvider(object: "alpha" as NSString)])
        let deadline = Date() + 5
        while doc.text != "alpha", Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
        XCTAssertEqual(doc.text, "alpha")
        XCTAssertEqual(h.clips.map(\.id), saved, "the Paste's clip isn't kept anew")
        h.delete(try XCTUnwrap(h.clips.first).id)
        bar.refresh()
        XCTAssertEqual(reads(), 1, "the same changeCount isn't read again")
        XCTAssertEqual(h.clips, [], "nor kept again")

        reads = counting(h) { _ in (nil, nil) }   // Don't Allow
        pb.string = "beta"
        bar.refresh()
        bar.refresh()
        XCTAssertEqual(reads(), 1, "refused once, not asked again")
        XCTAssertEqual(h.clips, [])
        XCTAssertTrue(h.fresh(pb), "the panel's Paste still offers it")

        reads = counting(h)
        pb.setItems([[UTType.utf8PlainText.identifier: "s3cret", "org.nspasteboard.ConcealedType": Data()]])
        bar.refresh()
        XCTAssertEqual(reads(), 0, "concealed")
        XCTAssertEqual(h.clips, [])
        withExtendedLifetime(kb) {}
    }

    /// An image clip goes in downsampled, as the panel's Paste keeps it.
    func testSaveCopiesKeepsAnImageDownsampled() throws {
        let h = ClipboardHistory(dir: dir)
        let (kb, bar, _, _) = rig("", history: h)
        pb.setData(try Data(contentsOf: try jpeg(3000, 1500)), forPasteboardType: UTType.jpeg.identifier)
        bar.refresh()
        let clip = try XCTUnwrap(h.clips.first)
        XCTAssertNil(clip.text)
        XCTAssertEqual(Self.pixels(h.url(try XCTUnwrap(clip.image))), CGSize(width: 1024, height: 512))
        withExtendedLifetime(kb) {}
    }
}
