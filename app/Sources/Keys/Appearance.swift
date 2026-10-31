import UIKit

/// The look, from the keys (#641): the hold menu's Appearance opens it in their place
/// (`SuggestionBar.showAppearance`). A Keys row of every theme, a Toolbar row of Match Keys and
/// every theme, and the accent while the keys are Dark, Light or True Black (a Mac theme lights
/// in its own colour, #642): each a strip that scrolls sideways, the current swatch ringed in
/// the accent and in view. A tap hands the settings with it to `onPick`; the bar applies and
/// stores them and draws this panel again in the new look. Without Full Access the rows are
/// off, under a note: the keyboard can't reach the app's settings then.
final class AppearancePanel: KeysPanel {
    typealias Theme = KeyboardSettings.Theme
    let settings: KeyboardSettings
    var onPick: ((KeyboardSettings) -> Void)?
    /// Each row's swatches: Keys, Toolbar (Match Keys first), Accent (none for a Mac theme).
    private(set) var keys: [UIButton] = [], toolbar: [UIButton] = [], accents: [UIButton] = []
    let note = UILabel()
    /// The panel's own scroll and the rows', by caption.
    ///
    /// ponytail: landscape's keys show the Keys row whole and scroll down to the rest; rows with
    /// the caption beside them would fit it, at the strips' width.
    private let scroll = Strip()
    private var strips: [String: Strip] = [:]

    init(settings: KeyboardSettings, enabled: Bool) {
        self.settings = settings
        super.init(title: "Appearance", empty: "")
        table.isHidden = true
        empty.isHidden = true
        let accent = settings.accent
        keys = Theme.allCases.map { theme in
            swatch(theme.title, Self.chip(theme, accent), on: theme == settings.theme) { $0.theme = theme }
        }
        toolbar = [swatch("Match Keys", Self.chip(settings.theme, accent), on: settings.toolbarTheme == nil) { $0.toolbarTheme = nil }]
            + Theme.allCases.map { theme in
                swatch(theme.title, Self.chip(theme, accent), on: theme == settings.toolbarTheme) { $0.toolbarTheme = theme }
            }
        if !settings.theme.isMac {
            accents = KeyboardSettings.Accent.allCases.map { lit in
                let dot = Self.dot(Style.Palette(settings.theme, accent: lit).accent)
                return swatch(lit.rawValue.capitalized, dot, on: lit == accent) { $0.accent = lit }
            }
        }
        note.text = "Turn on Full Access to change the look here"
        note.textColor = Style.hint
        note.font = .systemFont(ofSize: 13)
        note.numberOfLines = 0
        note.isHidden = enabled
        var rows: [UIView] = [note]
        for (caption, row) in [("Keys", keys), ("Toolbar", toolbar), ("Accent", accents)] where !row.isEmpty {
            row.forEach { $0.isEnabled = enabled }
            let label = UILabel()
            let indent = NSMutableParagraphStyle()
            indent.firstLineHeadIndent = 12   // over the swatches' edge
            label.attributedText = NSAttributedString(string: caption.uppercased(), attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Style.hint, .kern: 0.5,
                .paragraphStyle: indent])
            label.accessibilityLabel = caption
            label.accessibilityTraits = .header
            let strip = Strip()
            strip.current = row.first { $0.accessibilityTraits.contains(.selected) }
            strip.showsHorizontalScrollIndicator = false
            strip.alpha = enabled ? 1 : 0.4
            let stack = UIStackView(arrangedSubviews: row)
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: strip.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor, constant: -8),
                strip.heightAnchor.constraint(equalTo: stack.heightAnchor),
            ])
            strips[caption] = strip
            let section = UIStackView(arrangedSubviews: [label, strip])
            section.axis = .vertical
            section.spacing = 3
            rows.append(section)
        }
        let content = UIStackView(arrangedSubviews: rows)
        content.axis = .vertical
        content.spacing = 6
        content.setCustomSpacing(6, after: note)
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = .init(top: 0, leading: 0, bottom: 8, trailing: 0)
        note.textAlignment = .center
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 42),   // under KeysPanel's header
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The strips where `old`'s were, the panel this one redraws after a pick, so a pick doesn't
    /// jump them back to the current; a row new to it centres its current.
    func keep(_ old: AppearancePanel?) {
        guard let old else { return }
        scroll.start = old.scroll.contentOffset
        for (caption, strip) in strips { strip.start = old.strips[caption]?.contentOffset }
    }

    /// A swatch (#641): `image` over its name, ringed in the accent while `on`, which VoiceOver
    /// hears as selected. A tap: the settings with `change`.
    private func swatch(_ name: String, _ image: UIImage, on: Bool,
                        _ change: @escaping (inout KeyboardSettings) -> Void) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.image = image
        cfg.imagePlacement = .top
        cfg.imagePadding = 2
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)   // three rows in Normal's keys
        cfg.title = name
        cfg.titleLineBreakMode = .byTruncatingTail   // one line
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var a = $0
            a.font = .systemFont(ofSize: 11, weight: on ? .semibold : .regular)
            a.foregroundColor = Style.label
            return a
        }
        cfg.background.backgroundColor = Style.surface
        cfg.background.cornerRadius = 10
        cfg.background.strokeColor = on ? Style.accent : Style.hairline
        cfg.background.strokeWidth = on ? 2 : 1
        let b = UIButton(configuration: cfg)
        b.setContentHuggingPriority(.required, for: .horizontal)   // as wide as its name, not the strip's share
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.accessibilityLabel = name
        b.accessibilityTraits = on ? [.button, .selected] : .button
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UIDevice.current.playInputClick()
            var s = self.settings
            change(&s)
            self.onPick?(s)
        }, for: .touchUpInside)
        return b
    }

    /// Settings' `ThemeLabel` look (#642): a cap in its outline and the accent's dot, on the
    /// theme's backdrop.
    static func chip(_ theme: Theme, _ accent: KeyboardSettings.Accent) -> UIImage {
        let p = Style.Palette(theme, accent: accent)
        let box = CGRect(x: 0, y: 0, width: 36, height: 24)
        return UIGraphicsImageRenderer(bounds: box).image { _ in
            let back = UIBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
            p.backdrop.setFill()
            back.fill()
            UIColor.gray.withAlphaComponent(0.4).setStroke()
            back.lineWidth = 0.5
            back.stroke()
            let cap = UIBezierPath(roundedRect: CGRect(x: 6, y: 5, width: 14, height: 14), cornerRadius: 3)
            p.key.setFill()
            cap.fill()
            p.border.setStroke()
            cap.lineWidth = 1
            cap.stroke()
            p.accent.setFill()
            UIBezierPath(ovalIn: CGRect(x: 24, y: 8, width: 8, height: 8)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// An accent's swatch: its colour in a 22 pt circle, as tall as a theme's.
    static func dot(_ color: UIColor) -> UIImage {
        let box = CGRect(x: 0, y: 0, width: 24, height: 24)
        return UIGraphicsImageRenderer(bounds: box).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: box.insetBy(dx: 2, dy: 2)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// A scroll view placed once laid out: at `start` (the old panel's, `keep`), else with
    /// `current` centred, as far as it scrolls.
    final class Strip: UIScrollView {
        var current: UIView?
        var start: CGPoint?
        private var placed = false
        /// Set by the layout after `layoutSubviews` at times: placed in a pass after it.
        override var contentSize: CGSize { didSet { if !placed { setNeedsLayout() } } }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard !placed, bounds.width > 0, contentSize.width > 0 else { return }
            placed = true
            current?.superview?.layoutIfNeeded()   // the row's stack, for `current`'s frame
            let room = CGPoint(x: max(0, contentSize.width - bounds.width), y: max(0, contentSize.height - bounds.height))
            let at = start ?? CGPoint(x: current.map { $0.convert($0.bounds, to: self).midX - bounds.width / 2 } ?? 0, y: 0)
            contentOffset = CGPoint(x: min(max(0, at.x), room.x), y: min(max(0, at.y), room.y))
        }
    }
}
