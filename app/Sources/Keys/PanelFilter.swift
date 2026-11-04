import UIKit

/// A list panel's filter mode (#665), as the system's emoji search, over the bar too
/// (`KeysPanel.overBar`): the search row on top, two rows of live results (`shown`), then compact keys of the covered keyboard's layout (`KeysPanel.layout`)
/// that type into the query, never into the host. Each key ranks the rows again (`rank`); a tap
/// on a result is the list's own tap, return the first pickable result's. Done hands the list
/// back as it was (`KeysPanel.filter`). Rows, picks and fields are the caller's, by index, so a
/// panel of any kind can use it; the emoji picker's (#666) ranks its own and shows a grid in
/// the table's place (`grid`). Laid out by hand: the keys take what the field and two rows
/// leave, between `keyRow`'s bounds, and a taller panel (the app's) gives the rest to the
/// results.
///
/// ponytail: where even one row leaves the keys under their minimum (landscape) the whole
/// mode scrolls; a side-by-side layout would fit landscape.
final class PanelFilter: UIScrollView, UITableViewDataSource, UITableViewDelegate, UIInputViewAudioFeedback {
    typealias Style = TerminalKeyboard.Style
    static let fieldHeight: CGFloat = 34
    static let rowHeight: CGFloat = 38
    /// The emoji grid's least cell (#686): three rows in 108 pt, the glyph inside at 36.
    static let cellSide: CGFloat = 34
    static let keyRow: ClosedRange<CGFloat> = 26...40
    static let gap: CGFloat = 5

    var cell: (Int) -> UITableViewCell = { _ in UITableViewCell() }
    var pickable: (Int) -> Bool = { _ in true }
    var pick: (Int) -> Void = { _ in }
    var onDone: (() -> Void)?

    let placeholder: String
    let layout: TerminalKeyboard.Layout
    let fields: [[String]]
    private(set) var query = ""
    /// Indices into `fields`, best first.
    private(set) var matches: [Int]
    /// The 123 keys in the letters' place.
    private(set) var digits = false
    /// #740: the 123 keys' second page (`more`), as Apple's #+=: * ^ % and more for an argument
    /// such as Calculate's.
    private(set) var moreSymbols = false
    /// The letters shown: `layout`'s, or English's after the language key (#680), so a
    /// Bulgarian keyboard can type English words too. Fresh each time filter mode opens.
    private(set) var letters: TerminalKeyboard.Layout
    /// Result rows the keys leave room for: one where two would take them under their
    /// minimum (a panel not stretched over the bar, `KeysPanel.overBar`).
    private(set) var shown = 2

    let field: UIButton
    let clear = UIButton(configuration: .plain())
    let done = UIButton(configuration: .plain())
    let results = UITableView(frame: .zero, style: .plain)
    /// In the table's place, the caller's grid of `matches` (the emoji picker's, #666).
    let grid: UICollectionView?
    private let ranker: ((String) -> [Int])?
    let none = UILabel()
    private let repeater = TerminalKeyboard.Repeat()
    /// The keys' press bubble over a pressed letter or symbol.
    let preview = TerminalKeyboard.KeyPreview()
    /// The letter or symbol keys, by row; the specials stay.
    private(set) var rows: [[UIButton]] = []
    let toggle = Key(special: true), delete = Key(special: true), space = Key(special: false), go = Key(special: false)
    /// Before space, the keys' language key (#638): only over a non-English layout.
    let language = Key(special: true)
    /// #740: on the 123 keys, before space: #+= to `moreSymbols`, 123 back.
    let more = Key(special: true)

    init(placeholder: String, layout: TerminalKeyboard.Layout, fields: [[String]], grid: UICollectionView? = nil,
         rank ranker: ((String) -> [Int])? = nil) {
        self.placeholder = placeholder
        self.layout = layout
        letters = layout
        self.fields = fields
        self.grid = grid
        self.ranker = ranker
        matches = Array(fields.indices)
        field = Self.field(placeholder)
        super.init(frame: .zero)
        backgroundColor = Style.backdrop
        overrideUserInterfaceStyle = Style.palette.style
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        delaysContentTouches = false
        accessibilityViewIsModal = true   // VoiceOver stays off the list under it

        field.accessibilityTraits = .searchField
        clear.configuration?.image = UIImage(systemName: "xmark.circle.fill")
        clear.configuration?.baseForegroundColor = Style.hint
        clear.accessibilityLabel = "Clear"
        clear.addAction(UIAction { [weak self] _ in self?.type(nil) }, for: .touchUpInside)
        field.addSubview(clear)
        done.configuration?.title = "Done"
        done.configuration?.baseForegroundColor = Style.accent
        done.accessibilityHint = "Back to the list"
        done.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)

        results.backgroundColor = Style.surface
        results.separatorColor = Style.hairline
        results.layer.cornerRadius = 14
        results.rowHeight = Self.rowHeight
        results.contentInsetAdjustmentBehavior = .never   // whole rows from the card's top (#674)
        results.tableFooterView = UIView()   // no empty-row separators; zero height, so the end rests on a row top (#678)
        // The card's foot clipped by 1 pt (#681): rows are whole and rest on a row top, so
        // the bottom visible row's separator always falls there.
        let clip = UIView()
        clip.backgroundColor = .black
        clip.layer.cornerRadius = results.layer.cornerRadius   // the card's corners whole, 1 pt shorter
        results.mask = clip
        results.dataSource = self
        results.delegate = self
        none.text = "No matches"
        none.textColor = Style.hint
        none.font = .systemFont(ofSize: 14)
        none.textAlignment = .center

        toggle.accessibilityLabel = "Numbers"
        toggle.addAction(UIAction { [weak self] _ in self?.switchKeys() }, for: .touchUpInside)
        delete.configuration?.image = UIImage(systemName: "delete.left", withConfiguration: Style.symbol)
        delete.accessibilityLabel = "Delete"
        // Delete on touch-down, then repeating while held, as the keys' backspace.
        delete.addAction(UIAction { [weak self] _ in
            self?.type("\u{8}")
            self?.repeater.start { self?.edit("\u{8}") }
        }, for: .touchDown)
        delete.addAction(UIAction { [weak self] _ in self?.repeater.stop() },
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        language.isHidden = layout == .english
        language.addAction(UIAction { [weak self] _ in self?.switchLanguage() }, for: .touchUpInside)
        more.addAction(UIAction { [weak self] _ in self?.switchSymbols() }, for: .touchUpInside)
        space.configuration?.title = "space"
        space.accessibilityLabel = "Space"
        space.addAction(UIAction { [weak self] _ in self?.type(" ") }, for: .touchUpInside)
        go.wash()
        go.configuration?.image = UIImage(systemName: "return", withConfiguration: Style.symbol)
        go.accessibilityLabel = "Pick the first result"
        go.addAction(UIAction { [weak self] _ in self?.pickFirst() }, for: .touchUpInside)
        results.isHidden = grid != nil
        for v in [field, done, results, none, toggle, delete, language, more, space, go] + (grid.map { [$0] } ?? []) { addSubview(v) }
        buildKeys()
        refilter(announce: false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var enableInputClicksWhenVisible: Bool { true }

    /// The search row's look, the list's and this mode's: a magnifier and the placeholder.
    static func field(_ placeholder: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = Style.surface
        config.baseForegroundColor = Style.hint
        config.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        config.imagePadding = 6
        config.attributedTitle = AttributedString(placeholder, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15)]))
        config.background.cornerRadius = 10
        config.cornerStyle = .fixed
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 34)
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = placeholder
        return button
    }

    /// `fields`' indices matching `query`, best first: a prefix, then a word's start, then
    /// anywhere, then its characters in order, each case- and diacritic-insensitive, a row by
    /// its best field (then the earlier field). Ties, and every row for a blank query, keep
    /// their order.
    static func rank(_ query: String, _ fields: [[String]]) -> [Int] {
        let q = fold(query)
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(fields.indices) }
        func tier(_ text: String) -> Int? {
            let f = fold(text)
            if f.hasPrefix(q) { return 0 }
            var found = false, from = f.startIndex
            while let r = f.range(of: q, range: from..<f.endIndex) {
                let before = f[f.index(before: r.lowerBound)]
                if !before.isLetter && !before.isNumber { return 1 }
                found = true
                from = f.index(after: r.lowerBound)
            }
            if found { return 2 }
            var rest = Substring(q)
            for c in f where c == rest.first {
                rest.removeFirst()
                if rest.isEmpty { return 3 }
            }
            return nil
        }
        return fields.enumerated()
            .compactMap { i, texts in
                texts.enumerated().compactMap { j, text in tier(text).map { ($0, j) } }.min { $0 < $1 }.map { ($0.0, $0.1, i) }
            }
            .sorted { $0 < $1 }
            .map(\.2)
    }

    /// Case and diacritics folded away: the query's and what it matches (`EmojiKeywords` too, #666).
    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// A key's text into the query: nil clears it, a backspace (U+0008) takes the last character.
    func type(_ text: String?) {
        UIDevice.current.playInputClick()
        edit(text)
    }

    /// `type` without the click: the repeat clicks its own.
    private func edit(_ text: String?) {
        switch text {
        case nil: query = ""
        case "\u{8}": if !query.isEmpty { query.removeLast() }
        case let text?: query += text
        }
        refilter(announce: true)
    }

    /// Return: the first result that takes a tap.
    func pickFirst() {
        guard let i = matches.first(where: pickable) else { return }
        UIDevice.current.playInputClick()
        pick(i)
    }

    /// What VoiceOver hears after each key.
    var count: String {
        switch matches.count {
        case 0: return "No matches"
        case 1: return "1 result"
        case let n: return "\(n) results"
        }
    }

    private func refilter(announce: Bool) {
        matches = ranker?(query) ?? Self.rank(query, fields)
        // The caret in the accent, after the query or before the placeholder.
        let text = AttributedString(query.isEmpty ? placeholder : query,
                                    attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15),
                                                                    .foregroundColor: query.isEmpty ? Style.hint : Style.label]))
        let caret = AttributedString("|", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 17, weight: .light),
                                                                          .foregroundColor: Style.accent]))
        field.configuration?.attributedTitle = query.isEmpty ? caret + text : text + caret
        field.accessibilityValue = query
        clear.isHidden = query.isEmpty
        none.isHidden = !matches.isEmpty
        results.reloadData()
        results.contentOffset.y = -results.adjustedContentInset.top
        grid?.reloadData()
        grid?.contentOffset = .zero
        if announce { UIAccessibility.post(notification: .announcement, argument: count) }
    }

    /// #740: Apple's #+= page, its rows' lengths the 123 keys'.
    static let symbolRows: [[Character]] = [Array("[]{}#%^*+="), Array("_\\|~<>€£¥•"), Array(".,?!'")]

    /// The letters of `letters`, or the 123 keys: the digit row, the numpad's symbols, a few more;
    /// or their #+= page (#740).
    private func buildKeys() {
        rows.joined().forEach { $0.removeFromSuperview() }
        let symbols = String(TerminalKeyboard.numpadRows.joined().compactMap {
            if case .char(let c) = $0, Int(c) == nil { return Character(c) } else { return nil }
        })
        let chars: [[Character]] = !digits ? letters.letterRows
            : moreSymbols ? Self.symbolRows : [Array("1234567890"), Array(symbols), Array("_#&+'?!")]
        rows = chars.map { row in
            row.map { c in
                let key = Key(special: false)
                key.configuration?.title = String(c)
                key.accessibilityLabel = String(c)
                key.addAction(UIAction { [weak self] _ in self?.type(String(c)) }, for: .touchUpInside)
                key.addAction(UIAction { [weak self, weak key] _ in key.map { self?.showPreview($0) } },
                              for: [.touchDown, .touchDragEnter])
                key.addAction(UIAction { [weak self] _ in self?.preview.removeFromSuperview() },
                              for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
                addSubview(key)
                return key
            }
        }
        toggle.configuration?.title = digits ? "ABC" : "123"
        toggle.accessibilityLabel = digits ? "Letters" : "Numbers"
        more.isHidden = !digits
        more.configuration?.title = moreSymbols ? "123" : "#+="
        more.accessibilityLabel = moreSymbols ? "Numbers" : "More symbols"
        let next: TerminalKeyboard.Layout = letters == layout ? .english : layout
        language.configuration?.title = next.short
        language.accessibilityLabel = "Switch to \(next.name)"
        setNeedsLayout()
    }

    /// The bubble over `key`, inside this view, which reaches over the bar while filtering.
    private func showPreview(_ key: UIButton) {
        guard let text = key.configuration?.title else { return }
        addSubview(preview)   // also brings it to the front
        preview.show(text, over: key.frame, within: CGRect(origin: contentOffset, size: bounds.size),
                     rise: TerminalKeyboard.KeyPreview.rise(compact: traitCollection.verticalSizeClass == .compact))
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil { repeater.stop() }   // closed mid-hold
    }

    private func switchKeys() {
        UIDevice.current.playInputClick()
        digits.toggle()
        moreSymbols = false
        buildKeys()
    }

    /// #740: the 123 keys and their #+= page.
    private func switchSymbols() {
        UIDevice.current.playInputClick()
        moreSymbols.toggle()
        buildKeys()
    }

    /// The other layout's letters, from the 123 keys too.
    private func switchLanguage() {
        UIDevice.current.playInputClick()
        letters = letters == layout ? .english : layout
        digits = false
        moreSymbols = false
        buildKeys()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x0 = safeAreaInsets.left + 8, width = bounds.width - x0 - safeAreaInsets.right - 8
        let gap = Self.gap, top: CGFloat = 3, bottom: CGFloat = 4
        let resultsTop = top + Self.fieldHeight + gap
        func room(_ shown: CGFloat) -> CGFloat { (bounds.height - resultsTop - shown * Self.rowHeight - gap - bottom - 3 * gap) / 4 }
        shown = room(2) < Self.keyRow.lowerBound ? 1 : 2
        let keyRow = min(max(room(CGFloat(shown)), Self.keyRow.lowerBound), Self.keyRow.upperBound)
        let keysHeight = 4 * keyRow + 3 * gap
        let resultsHeight = max(CGFloat(shown) * Self.rowHeight, bounds.height - bottom - keysHeight - gap - resultsTop)
        contentSize = CGSize(width: bounds.width, height: resultsTop + resultsHeight + gap + keysHeight + bottom)

        done.sizeToFit()
        done.frame = CGRect(x: x0 + width - done.bounds.width, y: top, width: done.bounds.width, height: Self.fieldHeight)
        field.frame = CGRect(x: x0, y: top, width: done.frame.minX - 4 - x0, height: Self.fieldHeight)
        clear.frame = CGRect(x: field.bounds.width - 34, y: 0, width: 34, height: Self.fieldHeight)
        results.frame = CGRect(x: x0, y: resultsTop, width: width, height: resultsHeight)
        none.frame = results.frame
        grid?.frame = results.frame
        // The card shared out in whole rows, none under `rowHeight`: no partial row peeks at its
        // foot, and a two-line row gets the slack (#674).
        results.rowHeight = resultsHeight / max(1, (resultsHeight / Self.rowHeight).rounded(.down))
        // The grid too, in rows none under `cellSide`, columns no wider than `rowHeight`: 38 pt
        // cells in 108 pt left a row's band between two, the flow spreading them over it (#686).
        if let flow = grid?.collectionViewLayout as? UICollectionViewFlowLayout {
            let side = resultsHeight / max(1, (resultsHeight / Self.cellSide).rounded(.down))
            let item = CGSize(width: min(side, Self.rowHeight), height: side)
            if flow.itemSize != item { flow.itemSize = item; flow.invalidateLayout() }
        }
        clipFoot()

        // Keys a column wide, the longest row's (Bulgarian's 11) or 10, English's too on
        // Bulgarian; 123 and delete flank the third row as shift and delete do on the keys.
        let columns = CGFloat(max(layout.columns, 10)), keyGap: CGFloat = 5
        let unit = (width - (columns - 1) * keyGap) / columns
        var y = results.frame.maxY + gap
        for (r, row) in rows.enumerated() {
            let span = CGFloat(row.count) * unit + CGFloat(row.count - 1) * keyGap
            for (k, key) in row.enumerated() {
                key.frame = CGRect(x: x0 + (width - span) / 2 + CGFloat(k) * (unit + keyGap), y: y, width: unit, height: keyRow)
            }
            if r == 2 {
                toggle.frame = CGRect(x: x0, y: y, width: unit * 1.5, height: keyRow)
                delete.frame = CGRect(x: x0 + width - unit * 1.5, y: y, width: unit * 1.5, height: keyRow)
            }
            y += keyRow + gap
        }
        let goWidth = unit * 2.5 + keyGap
        let lead = language.isHidden ? 0 : unit * 1.5 + keyGap
        language.frame = CGRect(x: x0, y: y, width: unit * 1.5, height: keyRow)
        let extra = more.isHidden ? 0 : unit * 1.5 + keyGap   // #740
        more.frame = CGRect(x: x0 + lead, y: y, width: unit * 1.5, height: keyRow)
        space.frame = CGRect(x: x0 + lead + extra, y: y, width: width - goWidth - keyGap - lead - extra, height: keyRow)
        go.frame = CGRect(x: x0 + width - goWidth, y: y, width: goWidth, height: keyRow)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { matches.count }

    /// The list's own cell for the row, on one line and a smaller second line, without its
    /// side buttons (the clipboard's pin and delete), to fit a short row.
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = cell(matches[indexPath.row])
        cell.accessoryView = nil
        cell.accessibilityCustomActions = nil
        // No hairline under the last row (#678); a zero-width one, as a right inset alone leaves
        // a stub at the left edge (#681). The cells are fresh, never reused.
        if indexPath.row == matches.count - 1 { cell.separatorInset = UIEdgeInsets(top: 0, left: tableView.bounds.width, bottom: 0, right: 0) }
        if var content = cell.contentConfiguration as? UIListContentConfiguration {
            content.textProperties.numberOfLines = 1
            content.secondaryTextProperties.font = .systemFont(ofSize: 11)   // clear of the separator (#674)
            content.textToSecondaryTextVerticalPadding = 0
            content.directionalLayoutMargins.top = 2
            content.directionalLayoutMargins.bottom = 2
            cell.contentConfiguration = content
        }
        return cell
    }

    /// The mask in the table's bounds, which move as it scrolls: all but the foot's 1 pt, a
    /// separator's height at most, below any row's text (#681).
    private func clipFoot() {
        let b = results.bounds
        results.mask?.frame = CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height - 1)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === results { clipFoot() }
    }

    /// A scroll comes to rest on a row's top, never mid-row (#674).
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset target: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === results else { return }
        // The end from the rows, not contentSize, which can carry a footer or a stale height (#678).
        let row = results.rowHeight, end = max(0, CGFloat(matches.count) * row - results.bounds.height)
        target.pointee.y = min((target.pointee.y / row).rounded() * row, end)
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        pickable(matches[indexPath.row]) ? indexPath : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        pick(matches[indexPath.row])
    }

    /// A compact key in the keys' look: raised, hairline-bordered, lighter while pressed.
    final class Key: UIButton {
        private var fill: UIColor, pressed: UIColor

        init(special: Bool) {
            fill = special ? Style.special : Style.key
            pressed = special ? Style.specialPressed : Style.keyPressed
            super.init(frame: .zero)
            var config = UIButton.Configuration.plain()
            config.baseForegroundColor = Style.label
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var a = $0
                a.font = .systemFont(ofSize: special ? 15 : 19)
                return a
            }
            config.contentInsets = .zero
            configuration = config
            backgroundColor = fill
            layer.cornerRadius = Style.radius - 2
            layer.borderColor = Style.palette.border.cgColor
            layer.borderWidth = Style.palette.neon == nil ? 0.5 : 1
            ShortcutBar.shade(self, glow: Style.palette.glow)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        /// Filled with the accent, the label on it: return's.
        func wash() {
            fill = Style.accent
            pressed = Style.accent.withAlphaComponent(0.75)
            backgroundColor = fill
            configuration?.baseForegroundColor = Style.onAccent
        }

        override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? pressed : fill } }

        override func layoutSubviews() {
            super.layoutSubviews()
            ShortcutBar.trace(self)
        }
    }
}
