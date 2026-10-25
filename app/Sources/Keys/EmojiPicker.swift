import UIKit

/// The emoji most recently typed from the picker: newest first, each once, at most
/// `limit`. Kept in the App Group beside the Keyboard settings: the picker is the app's
/// keyboard's only (`TerminalKeyboard.offersEmoji`).
struct EmojiRecents: Equatable {
    static let key = "keyboard.emojiRecents"
    static let limit = 32
    private(set) var emoji: [String]

    init(_ emoji: [String] = []) { self.emoji = Array(emoji.prefix(Self.limit)) }

    mutating func add(_ e: String) {
        emoji = Array(([e] + emoji.filter { $0 != e }).prefix(Self.limit))
    }

    static func load() -> EmojiRecents {
        EmojiRecents(KeyboardSettings.store()?.stringArray(forKey: key) ?? [])
    }
    func save() { KeyboardSettings.store()?.set(emoji, forKey: Self.key) }
}

/// The emoji key's page (`TerminalKeyboard.Key.emoji`), in the app's keyboard only: the
/// terminal asks for an ASCII keyboard, which leaves out iOS's own emoji. It takes the
/// caps' place at their height: a grid scrolling sideways through Recents and the nine
/// Unicode groups (`EmojiData`), over a bar of ABC (back to the letters), a button per
/// group and delete. Its touches stay its own: the keyboard's tracker ignores every touch
/// while it shows (`TerminalKeyboard.track`).
///
/// ponytail: delete doesn't repeat while held, and the bar doesn't follow the scroll to
/// light the group in view. Add both if the picker sees heavy use.
final class EmojiPicker: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    typealias Style = TerminalKeyboard.Style
    /// What a cell types, delete, and ABC: the keyboard's.
    var pick: (String) -> Void = { _ in }
    var delete: () -> Void = {}
    var letters: () -> Void = {}

    static let groups = EmojiData.groups.map { $0.emoji.split(whereSeparator: \.isWhitespace).map(String.init) }
    /// Recents, then each of `EmojiData.groups`.
    static let symbols = ["clock", "face.smiling", "hand.wave", "pawprint", "fork.knife", "car",
                          "sportscourt", "lightbulb", "heart", "flag"]
    private(set) var recents = EmojiRecents()
    /// What the grid shows: recents as they were when the picker opened, then the groups.
    private(set) var sections: [[String]] = []
    let grid = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private let bar = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let flow = grid.collectionViewLayout as! UICollectionViewFlowLayout
        flow.scrollDirection = .horizontal
        flow.minimumLineSpacing = 0
        flow.minimumInteritemSpacing = 0
        grid.backgroundColor = .clear
        grid.showsHorizontalScrollIndicator = false
        grid.register(Cell.self, forCellWithReuseIdentifier: "e")
        grid.dataSource = self
        grid.delegate = self
        addSubview(grid)

        bar.distribution = .fillEqually
        bar.spacing = 2
        bar.addArrangedSubview(button(title: "ABC", label: "letters", fill: Style.special) { [weak self] in self?.letters() })
        let names = ["Recents"] + EmojiData.groups.map(\.name)
        for (section, (symbol, name)) in zip(Self.symbols, names).enumerated() {
            bar.addArrangedSubview(button(image: symbol, label: name) { [weak self] in self?.show(section) })
        }
        bar.addArrangedSubview(button(image: "delete.left", label: "delete", fill: Style.special) { [weak self] in self?.delete() })
        addSubview(bar)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func button(title: String? = nil, image: String? = nil, label: String, fill: UIColor? = nil,
                        action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .custom)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = Style.wordFont
        b.titleLabel?.adjustsFontSizeToFitWidth = true   // ABC in a 30 pt key
        b.titleLabel?.minimumScaleFactor = 0.6
        b.setImage(image.flatMap { UIImage(systemName: $0, withConfiguration: Style.symbol) }, for: .normal)
        b.tintColor = fill == nil ? Style.hint : .white
        b.backgroundColor = fill
        b.layer.cornerRadius = 6
        b.accessibilityLabel = label
        b.accessibilityTraits = .keyboardKey
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    /// Recents read again, from what this or another keyboard typed since.
    func reload() {
        recents = EmojiRecents.load()
        sections = [recents.emoji] + Self.groups
        grid.reloadData()
    }

    /// The bar's group button: the grid scrolls to its first emoji.
    func show(_ section: Int) {
        guard !sections[section].isEmpty else { return grid.setContentOffset(.zero, animated: false) }
        grid.scrollToItem(at: IndexPath(item: 0, section: section), at: .left, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let m = TerminalKeyboard.metrics(compact: traitCollection.verticalSizeClass == .compact)
        bar.frame = CGRect(x: 0, y: bounds.maxY - m.row, width: bounds.width, height: m.row)
        grid.frame = CGRect(x: 0, y: m.top, width: bounds.width, height: bar.frame.minY - m.top - m.top)
        // Whole rows of square cells, about 40 pt: five in portrait, three in landscape.
        let rows = max(1, (grid.bounds.height / 38).rounded(.down))
        let side = (grid.bounds.height / rows).rounded(.down)
        let flow = grid.collectionViewLayout as! UICollectionViewFlowLayout
        if flow.itemSize.height != side {
            flow.itemSize = CGSize(width: side, height: side)
            flow.invalidateLayout()
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].count
    }
    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "e", for: indexPath) as! Cell
        let e = sections[indexPath.section][indexPath.item]
        cell.label.text = e
        cell.accessibilityLabel = e   // VoiceOver speaks its name
        return cell
    }

    /// Typed, and first in recents from the next time the picker opens: the grid doesn't
    /// reorder under the finger.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        let e = sections[indexPath.section][indexPath.item]
        recents.add(e)
        recents.save()
        pick(e)
    }

    private final class Cell: UICollectionViewCell {
        let label = UILabel()
        override init(frame: CGRect) {
            super.init(frame: frame)
            label.textAlignment = .center
            contentView.addSubview(label)
            contentView.layer.cornerRadius = 6
            isAccessibilityElement = true
            accessibilityTraits = .keyboardKey
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func layoutSubviews() {
            super.layoutSubviews()
            label.frame = contentView.bounds
            label.font = .systemFont(ofSize: bounds.height * 0.7)
        }
        override var isHighlighted: Bool { didSet { contentView.backgroundColor = isHighlighted ? Style.special : nil } }
    }
}
