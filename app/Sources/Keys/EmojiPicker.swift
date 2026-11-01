import UIKit
import CoreText

/// The emoji most recently typed from the picker: newest first, each once, at most
/// `limit`. Kept in the App Group beside the Keyboard settings, so the app's keyboard and
/// the extension's (the toggle's menu, #629) share them.
struct EmojiRecents: Equatable {
    static let key = "keyboard.emojiRecents"
    static let limit = 32
    private(set) var emoji: [String]

    init(_ emoji: [String] = []) { self.emoji = Array(emoji.prefix(Self.limit)) }

    mutating func add(_ e: String) {
        emoji = Array(([e] + emoji.filter { $0 != e }).prefix(Self.limit))
    }

    static func load(fullAccess: Bool = true) -> EmojiRecents {
        EmojiRecents(store(fullAccess: fullAccess)?.stringArray(forKey: key) ?? [])
    }
    func save(fullAccess: Bool = true) { Self.store(fullAccess: fullAccess)?.set(emoji, forKey: Self.key) }
    /// The App Group with Full Access; without it the group may not keep a write, so the
    /// extension's own defaults (#629).
    static func store(fullAccess: Bool) -> UserDefaults? { fullAccess ? KeyboardSettings.store() : .standard }
}

/// The emoji key's page (`TerminalKeyboard.Key.emoji`) in the app's keyboard, whose ASCII
/// field leaves out iOS's own emoji, and the toggle menu's Emoji in the extension's, which
/// can't switch to iOS's (#629). It takes the
/// caps' place at their height: a grid scrolling sideways through Recents and every group
/// iOS's own emoji keyboard has (`groups`, #664), over a bar of ABC (back to the letters),
/// a button per group and delete. Its touches stay its own: the keyboard's tracker ignores
/// every touch while it shows (`TerminalKeyboard.track`).
///
/// The group in view is lit in the accent (#626), as the grid scrolls or a bar tap moves it.
/// Over the grid, a search row: #665's filter mode, matching CLDR's words (`EmojiKeywords`,
/// #666), its results two rows of cells drawn as the grid's.
///
/// ponytail: delete doesn't repeat while held. Add it if the picker sees heavy use.
final class EmojiPicker: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    typealias Style = TerminalKeyboard.Style
    /// What a cell types, delete, and ABC: the keyboard's.
    var pick: (String) -> Void = { _ in }
    var delete: () -> Void = {}
    var letters: () -> Void = {}

    /// iOS's emoji keyboard's groups, its names and order, each Unicode's (`EmojiData`)
    /// under it, and the bar's symbol.
    static let native: [(name: String, symbol: String, unicode: [String])] = [
        ("Smileys & People", "face.smiling", ["Smileys & Emotion", "People & Body"]),
        ("Animals & Nature", "pawprint", ["Animals & Nature"]),
        ("Food & Drink", "fork.knife", ["Food & Drink"]),
        ("Activity", "sportscourt", ["Activities"]),
        ("Travel & Places", "car", ["Travel & Places"]),
        ("Objects", "lightbulb", ["Objects"]),
        ("Symbols", "heart", ["Symbols"]),
        ("Flags", "flag", ["Flags"]),
    ]
    /// Each of `native`'s emoji, without the newer ones this iOS can't draw.
    static let groups: [[String]] = native.map { g in
        EmojiData.groups.filter { g.unicode.contains($0.name) }.flatMap { words($0.emoji) }.filter { !undrawable.contains($0) }
    }
    static let frequent = words(EmojiData.frequent)
    /// Recents, then each of `native`.
    static let symbols = ["clock"] + native.map(\.symbol)
    /// The emoji newer than 14.0 (`EmojiData.newer`) this iOS's Apple Color Emoji lacks.
    static let undrawable = Set(EmojiData.newer.flatMap { words($0.emoji) }.filter { !draws($0) })
    private static func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Whether Apple Color Emoji itself draws `e` as one glyph: a codepoint it lacks shapes
    /// to .notdef or a fallback font's box, a sequence it lacks to several glyphs.
    static func draws(_ e: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: e, attributes: [.font: font]))
        guard CTLineGetGlyphCount(line) == 1, let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first,
              let used = (CTRunGetAttributes(run) as? [NSAttributedString.Key: Any])?[.font] else { return false }
        var glyph = CGGlyph(0)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        return glyph != 0 && CTFontCopyPostScriptName(used as! CTFont) as String == "AppleColorEmoji"
    }
    private(set) var recents = EmojiRecents()
    /// Every group, or Recents and `frequent` only (#629): the system keyboards' when the
    /// picker can't have a font of its own (`makeFont`), as the shared one's glyphs outgrow
    /// an extension's memory. The app's keyboard has the memory.
    let full: Bool
    /// Where recents are kept (`EmojiRecents.store`): the keyboard's, set before `reload`.
    var fullAccess = true
    /// What the grid shows: recents as they were when the picker opened, then the groups.
    private(set) var sections: [[String]] = []
    let grid = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private let bar = UIStackView()
    private(set) var groupButtons: [UIButton] = []
    /// What the cells are drawn in (`emojiFont`). A font keeps every glyph it drew decoded
    /// while it lives, and every group's outgrow an extension's memory (#515: +96 MB at
    /// the cells' size); so past `glyphCap` new emoji a fresh instance takes over, and the
    /// old one's glyphs go once it draws: +9 MB for every group (#664). Drawn into images,
    /// not by labels, whose text caches keep the fonts they drew with (+28 MB).
    private var font: UIFont
    private var drawn = Set<String>()
    static let glyphCap = 150
    /// `emojiFont`, or nil where a test plays a read that failed.
    static var makeFont: (CGFloat) -> UIFont? = emojiFont(size:)
    /// The search row (#666): a tap opens filter mode (`search`).
    let searchRow = PanelFilter.field("Describe an emoji")
    /// Filter mode over the picker, while searching (#666).
    private(set) var filter: PanelFilter?
    /// CLDR's words, parsed as a search opens, dropped as it closes (#666).
    private(set) var keywords: EmojiKeywords?
    /// The keyboard's: filter mode's keys, and Bulgarian's words besides English's (#666).
    var layout = TerminalKeyboard.Layout.english
    /// Filter mode opened or closed: the extension's bar lends it its height (`TerminalKeyboard.searchesEmoji`).
    var searched: () -> Void = {}

    init(frame: CGRect = .zero, inApp: Bool = true) {
        let own = Self.makeFont(17)
        font = own ?? .systemFont(ofSize: 17)
        full = inApp || own != nil
        super.init(frame: frame)
        setUp(grid)
        addSubview(grid)
        searchRow.accessibilityHint = "Filters with keys of its own"
        searchRow.addAction(UIAction { [weak self] _ in self?.search(true) }, for: .touchUpInside)
        addSubview(searchRow)

        bar.distribution = .fillEqually
        bar.spacing = 2
        bar.addArrangedSubview(button(title: "ABC", label: "letters", fill: Style.surface) { [weak self] in self?.letters() })
        let names = ["Recents"] + (full ? Self.native.map(\.name) : ["Frequent"])
        for (section, (symbol, name)) in zip(full ? Self.symbols : ["clock", "star"], names).enumerated() {
            let b = button(image: symbol, label: name) { [weak self] in self?.show(section) }
            groupButtons.append(b)
            bar.addArrangedSubview(b)
        }
        light(0)
        bar.addArrangedSubview(button(image: "delete.left", label: "delete", fill: Style.surface) { [weak self] in self?.delete() })
        addSubview(bar)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A grid of cells scrolling sideways, this picker's: the groups', or a search's results.
    private func setUp(_ grid: UICollectionView) {
        let flow = grid.collectionViewLayout as! UICollectionViewFlowLayout
        flow.scrollDirection = .horizontal
        flow.minimumLineSpacing = 0
        flow.minimumInteritemSpacing = 0
        grid.backgroundColor = .clear
        grid.showsHorizontalScrollIndicator = false
        grid.register(Cell.self, forCellWithReuseIdentifier: "e")
        grid.dataSource = self
        grid.delegate = self
    }

    private func button(title: String? = nil, image: String? = nil, label: String, fill: UIColor? = nil,
                        action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .custom)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = Style.wordFont
        b.titleLabel?.adjustsFontSizeToFitWidth = true   // ABC in a 30 pt key
        b.titleLabel?.minimumScaleFactor = 0.6
        b.setImage(image.flatMap { UIImage(systemName: $0, withConfiguration: Style.symbol) }, for: .normal)
        b.tintColor = fill == nil ? Style.hint : Style.icon
        b.setTitleColor(Style.label, for: .normal)
        b.backgroundColor = fill
        b.layer.cornerRadius = Style.radius
        if fill != nil { ShortcutBar.shade(b) }
        b.accessibilityLabel = label
        b.accessibilityTraits = .keyboardKey
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    /// Recents read again, from what this or another keyboard typed since.
    func reload() {
        recents = EmojiRecents.load(fullAccess: fullAccess)
        sections = [recents.emoji] + (full ? Self.groups : [Self.frequent])
        grid.reloadData()
    }

    /// The bar's group button: the grid scrolls to its first emoji.
    func show(_ section: Int) {
        if sections[section].isEmpty {
            grid.setContentOffset(.zero, animated: false)
        } else {
            grid.scrollToItem(at: IndexPath(item: 0, section: section), at: .left, animated: false)
        }
        light(section)   // the one tapped, though the end of the grid may show the one before
    }

    /// Filter mode over the picker, or the grid back (#666): every emoji the picker has,
    /// recents first, ranked by `keywords` in the keyboard's languages; a result types as a cell.
    func search(_ on: Bool) {
        guard on || filter != nil else { return }
        filter?.removeFromSuperview()
        filter = nil
        keywords = nil
        if on {
            var seen = Set<String>()
            let all = sections.joined().filter { seen.insert($0).inserted }
            keywords = EmojiKeywords(layout)
            let flow = UICollectionViewFlowLayout()
            flow.itemSize = CGSize(width: PanelFilter.rowHeight, height: PanelFilter.rowHeight)
            let results = UICollectionView(frame: .zero, collectionViewLayout: flow)
            setUp(results)
            let f = PanelFilter(placeholder: searchRow.accessibilityLabel ?? "", layout: layout, fields: all.map { [$0] },
                                grid: results) { [weak self] in self?.keywords?.rank($0, all) ?? [] }
            f.pick = { [weak self] in self?.choose(all[$0]) }
            f.onDone = { [weak self] in self?.search(false) }
            f.frame = bounds
            f.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(f)
            filter = f
        }
        UIAccessibility.post(notification: .screenChanged, argument: filter?.field ?? searchRow)
        searched()
    }

    private func light(_ section: Int) {
        for (i, b) in groupButtons.enumerated() { b.tintColor = i == section ? Style.accent : Style.hint }
    }

    /// The group at the grid's left edge, lit as the grid scrolls.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let x = grid.contentOffset.x + 1
        light(sections.indices.last { s in
            !sections[s].isEmpty && (grid.layoutAttributesForItem(at: IndexPath(item: 0, section: s))?.frame.minX ?? .infinity) <= x
        } ?? 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let m = TerminalKeyboard.metrics(compact: traitCollection.verticalSizeClass == .compact)
        bar.frame = CGRect(x: 0, y: bounds.maxY - m.row, width: bounds.width, height: m.row)
        searchRow.frame = CGRect(x: 0, y: m.top, width: bounds.width, height: PanelFilter.fieldHeight)
        grid.frame = CGRect(x: 0, y: searchRow.frame.maxY + m.top, width: bounds.width,
                            height: bar.frame.minY - searchRow.frame.maxY - m.top - m.top)
        // Whole rows of square cells, about 40 pt: five in portrait, three in landscape.
        let rows = max(1, (grid.bounds.height / 38).rounded(.down))
        let side = (grid.bounds.height / rows).rounded(.down)
        let flow = grid.collectionViewLayout as! UICollectionViewFlowLayout
        if flow.itemSize.height != side {
            flow.itemSize = CGSize(width: side, height: side)
            flow.invalidateLayout()
            renew(size: side * 0.7)
            grid.reloadData()
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === grid ? sections[section].count : filter?.matches.count ?? 0
    }
    func numberOfSections(in collectionView: UICollectionView) -> Int { collectionView === grid ? sections.count : 1 }

    /// The grid's cell's emoji, or a search result's (#666).
    private func emoji(_ collectionView: UICollectionView, _ indexPath: IndexPath) -> String {
        guard collectionView !== grid, let filter else { return sections[indexPath.section][indexPath.item] }
        return filter.fields[filter.matches[indexPath.item]][0]
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "e", for: indexPath) as! Cell
        let e = emoji(collectionView, indexPath)
        if drawn.insert(e).inserted, drawn.count > Self.glyphCap {
            renew(size: font.pointSize)
            drawn = [e]
        }
        cell.emoji.image = Self.image(e, font: font)
        cell.accessibilityLabel = e   // VoiceOver speaks its name
        return cell
    }

    /// `e` drawn in `font`, sized to the union of its advance and its ink: some glyphs (🫡)
    /// ink past their advance, and an image the advance's size cut them off (#673). In the
    /// label's colour: ♀️ ♂️ ⚕️ are the font's outlines, not bitmaps, filled in the text's,
    /// black without one (#676).
    static func image(_ e: String, font: UIFont) -> UIImage {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: e, attributes: [.font: font, .foregroundColor: Style.label]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let box = CGRect(x: 0, y: -descent, width: width, height: ascent + descent)
            .union(CTLineGetImageBounds(line, nil)).integral   // y up, from the baseline
        let format = UIGraphicsImageRendererFormat.preferred()
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: box.size, format: format).image { c in
            c.cgContext.translateBy(x: -box.minX, y: box.maxY)
            c.cgContext.scaleBy(x: 1, y: -1)
            CTLineDraw(line, c.cgContext)
        }
    }

    private func renew(size: CGFloat) {
        font = Self.makeFont(size) ?? .systemFont(ofSize: size)
        drawn = []
    }

    /// Apple Color Emoji at `size`, an instance of its own read from the font's file: the
    /// system's shared one keeps every glyph it drew for the process's life. Nil if the
    /// file can't be read.
    static func emojiFont(size: CGFloat) -> UIFont? {
        let shared = CTFontCreateWithName("AppleColorEmoji" as CFString, size, nil)
        let name = CTFontCopyPostScriptName(shared)
        guard let url = CTFontCopyAttribute(shared, kCTFontURLAttribute) as? URL,
              let data = try? Data(contentsOf: url, options: .alwaysMapped),   // file-backed: not the footprint
              let all = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let own = all.first(where: { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == name as String })
        else { return nil }
        return CTFontCreateWithFontDescriptor(own, size, nil) as UIFont
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        choose(emoji(collectionView, indexPath))
    }

    /// A cell's tap, the grid's or a search's (#666): typed, and first in recents from the
    /// next time the picker opens: the grid doesn't reorder under the finger.
    func choose(_ e: String) {
        recents.add(e)
        recents.save(fullAccess: fullAccess)
        pick(e)
    }

    private final class Cell: UICollectionViewCell {
        let emoji = UIImageView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            emoji.contentMode = .center
            contentView.addSubview(emoji)
            contentView.layer.cornerRadius = 6
            isAccessibilityElement = true
            accessibilityTraits = .keyboardKey
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func layoutSubviews() {
            super.layoutSubviews()
            emoji.frame = contentView.bounds
        }
        override var isHighlighted: Bool { didSet { contentView.backgroundColor = isHighlighted ? Style.special : nil } }
    }
}

/// CLDR's names and keywords for the emoji search (#666), `EmojiData.keywords`: English's,
/// and on the Bulgarian keys Bulgarian's too. Parsed as a search opens into slices of the
/// literals, which stay in the binary's pages: nothing is copied but the emoji.
struct EmojiKeywords {
    private var words: [String: [(name: Substring, keywords: Substring)]] = [:]

    init(_ layout: TerminalKeyboard.Layout) {
        for language in layout == .bulgarian ? ["bg", "en"] : ["en"] {
            for line in EmojiData.keywords[language, default: ""].split(separator: "\n") {
                guard let space = line.firstIndex(of: " "), let bar = line.firstIndex(of: "|") else { continue }
                words[String(line[..<space]), default: []].append((line[line.index(after: space)..<bar], line[bar...]))
            }
        }
    }

    /// `emoji`'s indices matching `query`, best first: an exact keyword, then a keyword's
    /// prefix, then a name's word's, in any language; ties, and every emoji for a blank
    /// query, keep `emoji`'s order. Bytes against bytes: both folded (`PanelFilter.fold`) and composed.
    func rank(_ query: String, _ emoji: [String]) -> [Int] {
        let q = Array(PanelFilter.fold(query).precomposedStringWithCanonicalMapping.utf8)
        guard q.contains(where: { $0 != 32 }) else { return Array(emoji.indices) }
        let bar: UInt8 = 124, space: UInt8 = 32
        let exact = [bar] + q + [bar], prefix = [bar] + q, word = [space] + q
        func tier(_ w: (name: Substring, keywords: Substring)) -> Int? {
            if w.keywords.utf8.firstRange(of: exact) != nil { return 0 }
            if w.keywords.utf8.firstRange(of: prefix) != nil { return 1 }
            if w.name.utf8.starts(with: q) || w.name.utf8.firstRange(of: word) != nil { return 2 }
            return nil
        }
        return emoji.enumerated()
            .compactMap { i, e in words[e]?.compactMap(tier).min().map { ($0, i) } }
            .sorted { $0 < $1 }
            .map(\.1)
    }
}
