import SwiftUI
import UIKit

/// One key on the shortcut bar above the keyboard. `bytes` are sent verbatim to the
/// remote pty; `.ctrl` is a sticky modifier (next typed letter → control char);
/// `.pasteText` injects the iOS clipboard string.
struct ShortcutKey: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case bytes, ctrl, pasteText }
    var id: String
    var label: String
    var kind: Kind
    var bytes: [UInt8] = []
    /// SF Symbol name. When set, the keycap shows the icon instead of `label`
    /// (label still used in the editor list + accessibility).
    var systemImage: String? = nil
}

/// Shortcut-bar config: catalog of available keys, the user's chosen set (persisted
/// as JSON in UserDefaults), and the default set.
enum Shortcuts {
    static let storageKey = "shortcutKeys"

    /// Everything the user can add. Default set is a curated subset (see `defaults`).
    static let catalog: [ShortcutKey] = [
        ShortcutKey(id: "esc",     label: "esc",   kind: .bytes, bytes: [0x1b], systemImage: "escape"),
        ShortcutKey(id: "tab",     label: "tab",   kind: .bytes, bytes: [0x09], systemImage: "increase.indent"),
        ShortcutKey(id: "stab",    label: "⇧tab",  kind: .bytes, bytes: [0x1b, 0x5b, 0x5a], systemImage: "decrease.indent"),
        ShortcutKey(id: "ctrl",    label: "ctrl",  kind: .ctrl),
        ShortcutKey(id: "ctlc",    label: "^C",    kind: .bytes, bytes: [0x03]),
        ShortcutKey(id: "ctld",    label: "^D",    kind: .bytes, bytes: [0x04]),
        ShortcutKey(id: "ctlr",    label: "^R",    kind: .bytes, bytes: [0x12]),
        ShortcutKey(id: "up",      label: "↑",     kind: .bytes, bytes: [0x1b, 0x5b, 0x41]),
        ShortcutKey(id: "down",    label: "↓",     kind: .bytes, bytes: [0x1b, 0x5b, 0x42]),
        ShortcutKey(id: "left",    label: "←",     kind: .bytes, bytes: [0x1b, 0x5b, 0x44]),
        ShortcutKey(id: "right",   label: "→",     kind: .bytes, bytes: [0x1b, 0x5b, 0x43]),
        ShortcutKey(id: "home",    label: "home",  kind: .bytes, bytes: [0x1b, 0x5b, 0x48], systemImage: "arrow.left.to.line"),
        ShortcutKey(id: "end",     label: "end",   kind: .bytes, bytes: [0x1b, 0x5b, 0x46], systemImage: "arrow.right.to.line"),
        ShortcutKey(id: "pgup",    label: "pgup",  kind: .bytes, bytes: [0x1b, 0x5b, 0x35, 0x7e]),
        ShortcutKey(id: "pgdn",    label: "pgdn",  kind: .bytes, bytes: [0x1b, 0x5b, 0x36, 0x7e]),
        ShortcutKey(id: "slash",   label: "/",     kind: .bytes, bytes: [0x2f]),
        ShortcutKey(id: "pipe",    label: "|",     kind: .bytes, bytes: [0x7c]),
        ShortcutKey(id: "paste",   label: "paste", kind: .pasteText, systemImage: "doc.on.clipboard"),
        // Ctrl-V: Claude Code grabs the image from the *Mac's* clipboard.
        ShortcutKey(id: "pasteImg", label: "paste img", kind: .bytes, bytes: [0x16], systemImage: "photo"),
        // ESC+CR = meta/option-enter; Claude Code (and most TUIs) maps it to "insert
        // newline, don't submit". ponytail: relies on Claude's meta-enter binding; if a
        // shell needs a literal LF instead, bytes [0x0a] is the fallback.
        ShortcutKey(id: "snl",     label: "⇧⏎",    kind: .bytes, bytes: [0x1b, 0x0d], systemImage: "arrow.turn.down.left"),
    ]

    static var defaults: [ShortcutKey] {
        ["esc", "tab", "ctrl", "home", "end", "paste", "pasteImg", "ctlc", "ctld", "snl"]
            .compactMap { id in catalog.first { $0.id == id } }
    }

    static func load() -> [ShortcutKey] {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let keys = try? JSONDecoder().decode([ShortcutKey].self, from: data),
              !keys.isEmpty
        else { return defaults }
        return keys
    }

    static func save(_ keys: [ShortcutKey]) {
        guard let data = try? JSONEncoder().encode(keys),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: storageKey)
    }
}

/// The horizontal key strip shown above the software keyboard. Owned by the terminal
/// view controller and pinned above the keyboard in its own hierarchy (NOT an
/// `inputAccessoryView` — the keyboard's remote input window swallowed touches there).
/// Reads its keys from `Shortcuts.load()`; call `reload()` after the editor changes them.
final class ShortcutBar: UIView {
    static let barHeight: CGFloat = 44
    var onKey: ((ShortcutKey) -> Void)?
    var ctrlArmed = false { didSet { refreshCtrl() } }
    private weak var ctrlButton: UIButton?
    private weak var container: UIView?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: ShortcutBar.barHeight))
        // Match the iOS keyboard chrome so the strip reads as part of it.
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.container = blur.contentView
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() { build() }

    private func build() {
        guard let container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        ctrlButton = nil

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.keyboardDismissMode = .none
        scroll.alwaysBounceHorizontal = true          // always draggable, even near-fit
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .fill     // uniform cap height (ctrl's 2-line cap is the tallest)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        for key in Shortcuts.load() {
            let b = makeButton(key)
            stack.addArrangedSubview(b)
            if key.kind == .ctrl { ctrlButton = b }
        }
        refreshCtrl()
    }

    // Neon keycaps, matching Prosper's theme palette (theme-default/theme.json):
    // dark card fill, electric-cyan hairline border + glow, bright-cyan glyphs.
    private enum Neon {
        static let blue       = UIColor(hex: 0x21CCFF)   // electric cyan border/glow
        static let blueBright = UIColor(hex: 0x75EBFF)   // glyph highlight
        static let card       = UIColor(hex: 0x131923)   // keycap fill
        static let text       = UIColor(hex: 0xE8F2FC)   // primary text
    }
    private static let capFont: UIFont = {
        let base = UIFont.systemFont(ofSize: 15, weight: .medium)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: d, size: 15)
    }()
    private static let capBigFont: UIFont = {
        let base = UIFont.systemFont(ofSize: 18, weight: .bold)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: d, size: 18)
    }()
    private static let capTinyFont = UIFont.systemFont(ofSize: 8, weight: .semibold)

    private func makeButton(_ key: ShortcutKey) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.baseForegroundColor = Neon.blueBright
        cfg.contentInsets = .init(top: 5, leading: 12, bottom: 5, trailing: 12)
        if key.kind == .ctrl {
            // Modifier cap: big "^" with a tiny "ctrl" caption underneath (trademark-style).
            cfg.title = "^"
            cfg.subtitle = "ctrl"
            cfg.titleAlignment = .center
            cfg.titleTextAttributesTransformer    = .init { var c = $0; c.font = Self.capBigFont; return c }
            cfg.subtitleTextAttributesTransformer = .init { var c = $0; c.font = Self.capTinyFont; return c }
        } else if let sym = key.systemImage {
            cfg.image = UIImage(systemName: sym,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        } else {
            cfg.title = key.label
            cfg.titleTextAttributesTransformer = .init { var c = $0; c.font = Self.capFont; return c }
        }
        cfg.background.backgroundColor = Neon.card
        cfg.background.cornerRadius = 7
        cfg.background.strokeColor = Neon.blue.withAlphaComponent(0.55)
        cfg.background.strokeWidth = 1
        let b = UIButton(configuration: cfg)
        // Neon halo.
        b.layer.shadowColor = Neon.blue.cgColor
        b.layer.shadowOpacity = 0.5
        b.layer.shadowRadius = 5
        b.layer.shadowOffset = .zero
        b.layer.masksToBounds = false
        // Hug content so each key keeps its natural width — otherwise the stack
        // stretches them to fill the bar and the row can't scroll.
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.addAction(UIAction { [weak self] _ in self?.onKey?(key) }, for: .touchUpInside)
        return b
    }

    private func refreshCtrl() {
        guard let b = ctrlButton, var cfg = b.configuration else { return }
        // Armed = solid cyan fill + dark glyph; idle = neon outline like the rest.
        cfg.background.backgroundColor = ctrlArmed ? Neon.blue : Neon.card
        cfg.baseForegroundColor = ctrlArmed ? UIColor(hex: 0x05080D) : Neon.blueBright
        b.configuration = cfg
        b.layer.shadowOpacity = ctrlArmed ? 0.9 : 0.5
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red:   CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8)  & 0xff) / 255,
                  blue:  CGFloat( hex        & 0xff) / 255,
                  alpha: 1)
    }
}

/// Add / remove / reorder the shortcut-bar keys. Persists to the same UserDefaults
/// key the bar reads, so the bar reloads with the new set when the sheet closes.
struct ShortcutEditor: View {
    @AppStorage(Shortcuts.storageKey) private var raw = ""   // observe-only: triggers refresh
    @State private var keys: [ShortcutKey] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Active (drag to reorder, swipe to remove)") {
                    ForEach(keys) { k in Text(k.label).font(.body.monospaced()) }
                        .onMove { keys.move(fromOffsets: $0, toOffset: $1); persist() }
                        .onDelete { keys.remove(atOffsets: $0); persist() }
                }
                let avail = Shortcuts.catalog.filter { c in !keys.contains { $0.id == c.id } }
                if !avail.isEmpty {
                    Section("Add") {
                        ForEach(avail) { c in
                            Button { keys.append(c); persist() } label: {
                                Label(c.label, systemImage: "plus.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Shortcut Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset") { keys = Shortcuts.defaults; persist() }
                }
                ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { keys = Shortcuts.load() }
    }

    private func persist() { Shortcuts.save(keys) }
}
