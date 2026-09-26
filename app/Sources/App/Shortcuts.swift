import SwiftUI
import UIKit

/// One key on the shortcut bar above the keyboard. `bytes` are sent verbatim to the
/// remote pty; `.ctrl` is a sticky modifier (next typed letter → control char);
/// `.pasteText` injects the iOS clipboard string; `.insertText` opens a compose
/// sheet whose text is sent as one paste; `.redraw` jiggles the pty size so the
/// remote TUI repaints.
struct ShortcutKey: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case bytes, ctrl, pasteText, pasteImage, insertText, redraw }
    var id: String
    var label: String
    var kind: Kind
    var bytes: [UInt8] = []
    /// SF Symbol name. When set, the keycap shows the icon instead of `label`
    /// (label still used in the editor list + accessibility).
    var systemImage: String? = nil
}

/// Terminal text size, nudged from the shortcut editor sheet. Stored as a point
/// size; changing it reflows the grid (fewer/more cols+rows) and resizes the pty.
enum TerminalPrefs {
    static let sizeKey = "terminalFontSize"
    /// 10% below the original hard-coded 13 pt — more of the remote screen fits.
    static let defaultSize: CGFloat = 11.7
    static let range: ClosedRange<CGFloat> = 8...20
    static let step: CGFloat = 0.5

    static var fontSize: CGFloat {
        get {
            let v = CGFloat(UserDefaults.standard.double(forKey: sizeKey))
            return v > 0 ? clamp(v) : defaultSize
        }
        set {
            UserDefaults.standard.set(Double(clamp(newValue)), forKey: sizeKey)
            // Flush now. UserDefaults writes back on its own schedule, and the size is
            // typically changed and then the app is put away or force-quit within
            // seconds — exactly the window where an unflushed write is lost and the
            // terminal comes back at the default size next launch.
            UserDefaults.standard.synchronize()
        }
    }

    static func clamp(_ v: CGFloat) -> CGFloat { min(max(v, range.lowerBound), range.upperBound) }
}

/// Shortcut-bar config: catalog of available keys, the user's chosen set (persisted
/// as JSON in UserDefaults), and the default set.
enum Shortcuts {
    static let storageKey = "shortcutKeys"

    /// Everything the user can add. Default set is a curated subset (see `defaults`).
    static let catalog: [ShortcutKey] = [
        // esc/tab/⇧tab read as words, not pictograms: `escape` and the indent arrows are
        // both guessable-at-best, and the word is no wider than the glyph.
        ShortcutKey(id: "esc",     label: "esc",   kind: .bytes, bytes: [0x1b]),
        ShortcutKey(id: "tab",     label: "tab",   kind: .bytes, bytes: [0x09]),
        ShortcutKey(id: "stab",    label: "⇧tab",  kind: .bytes, bytes: [0x1b, 0x5b, 0x5a]),
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
        // Ships the copied image to the remote machine's clipboard, then sends
        // ctrl-V — which is what Claude Code reads. Sending ctrl-V alone only worked
        // when Universal Clipboard happened to have carried the image over.
        ShortcutKey(id: "pasteImg", label: "paste img", kind: .pasteImage, bytes: [0x16], systemImage: "photo"),
        // Compose locally, send once: the sheet (`InsertTextVC`) hands the whole text
        // to the pty as one bracketed paste — no per-keystroke round-trip.
        ShortcutKey(id: "insert",  label: "insert", kind: .insertText, systemImage: "text.cursor"),
        // ESC+CR = meta/option-enter; Claude Code (and most TUIs) maps it to "insert
        // newline, don't submit". ponytail: relies on Claude's meta-enter binding; if a
        // shell needs a literal LF instead, bytes [0x0a] is the fallback.
        // No glyph on purpose: `arrow.turn.down.left` IS the keyboard's return key, and
        // this cap does the opposite (newline, no submit) right next to it.
        ShortcutKey(id: "snl",     label: "⇧⏎",    kind: .bytes, bytes: [0x1b, 0x0d]),
        // Manual repaint: same size-jiggle the server does on reattach/foreground.
        // Claude Code (and other TUIs) sometimes leave stale/missing glyphs until a
        // SIGWINCH — this is the button form of "resize the window to fix it".
        ShortcutKey(id: "redraw",  label: "redraw", kind: .redraw, systemImage: "arrow.clockwise"),
    ]

    static var defaults: [ShortcutKey] {
        ["paste", "pasteImg", "insert", "ctlc", "stab", "snl", "esc", "left", "right", "up", "down", "pgup", "pgdn"]
            .compactMap { id in catalog.first { $0.id == id } }
    }

    static func load() -> [ShortcutKey] {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let keys = try? JSONDecoder().decode([ShortcutKey].self, from: data),
              !keys.isEmpty
        else { return defaults }
        // Keep the user's SET and ORDER, but take each key's definition from the
        // catalog: a saved bar from an older build otherwise pins the old bytes/kind
        // forever (an image-paste key stuck on plain ctrl-V, say).
        return keys.map { saved in catalog.first { $0.id == saved.id } ?? saved }
    }

    static func save(_ keys: [ShortcutKey]) {
        guard let data = try? JSONEncoder().encode(keys),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: storageKey)
    }
}

/// The key strip at the bottom of the terminal: resting on the safe area with the
/// keyboard down, riding its top when it's up. Owned by the terminal view controller
/// and pinned in its own hierarchy (NOT an `inputAccessoryView` — the keyboard's remote
/// input window swallowed touches there). One row when the keys fit, else two rows that
/// scroll horizontally together. Reads its keys from `Shortcuts.load()`; call `reload()`
/// after the editor changes them.
final class ShortcutBar: UIView {
    private static let inset: CGFloat = 4       // above and below the caps
    private static let capHeight: CGFloat = 36
    private static let spacing: CGFloat = 6     // between caps, and between the rows
    var onKey: ((ShortcutKey) -> Void)?
    var ctrlArmed = false { didSet { refreshCtrl() } }
    private weak var ctrlButton: KeyCapButton?
    private weak var container: UIView?
    private var caps: [KeyCapButton] = []
    private var rows: [UIStackView] = []        // [top, bottom]
    private var arrangedWidth: CGFloat = -1     // width the caps were last split for
    /// The bar's height IS its row count, so the owner never needs a number: flipping
    /// it re-asks Auto Layout for `intrinsicContentSize`.
    private(set) var rowCount = 1 {
        didSet { if rowCount != oldValue { invalidateIntrinsicContentSize() } }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.inset * 2 + Self.capHeight))
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

    /// 1 row = 44 (4 + 36 + 4), 2 rows = 86 (4 + 36 + 6 + 36 + 4).
    override var intrinsicContentSize: CGSize {
        let n = CGFloat(rowCount)
        return CGSize(width: UIView.noIntrinsicMetric,
                      height: Self.inset * 2 + Self.capHeight * n + Self.spacing * (n - 1))
    }

    /// Split the caps across the rows for the current width — only when the width
    /// actually changed (rotation) or the key set was rebuilt; every other layout pass
    /// is a no-op. Runs BEFORE `super` so the moved caps lay out in this same pass.
    override func layoutSubviews() {
        if bounds.width != arrangedWidth, rows.count == 2 {
            arrangedWidth = bounds.width
            let k = Self.rowSplit(widths: caps.map { $0.intrinsicContentSize.width },
                                  spacing: Self.spacing, available: bounds.width - 16)
            // addArrangedSubview re-parents: a cap leaves whichever row held it.
            for (i, cap) in caps.enumerated() { rows[i < k ? 0 : 1].addArrangedSubview(cap) }
            rows[1].isHidden = k == caps.count   // hidden → the stack gives row 1 the full height
            rowCount = rows[1].isHidden ? 1 : 2
        }
        super.layoutSubviews()
    }

    /// How many caps (in configured order) go in the TOP row. All fit in one row → all
    /// of them. Otherwise the split that makes the longer of the two rows shortest, so
    /// the rows come out balanced and the bar scrolls as little as possible. Ties go to
    /// the LARGER k — the top row is the fuller one, the way text wraps.
    static func rowSplit(widths: [CGFloat], spacing: CGFloat, available: CGFloat) -> Int {
        func span(_ w: ArraySlice<CGFloat>) -> CGFloat {
            w.reduce(0, +) + spacing * CGFloat(max(0, w.count - 1))
        }
        let n = widths.count
        guard n > 1, span(widths[...]) > available else { return n }
        var best = 1, bestSpan = CGFloat.infinity
        for k in 1..<n {
            let s = max(span(widths[..<k]), span(widths[k...]))
            if s <= bestSpan { best = k; bestSpan = s }
        }
        return best
    }

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

        // Both rows live in ONE scroll view, so they scroll together as a block. The
        // column is as wide as its longer row (.leading, not .fill).
        rows = (0..<2).map { _ in
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = Self.spacing
            row.alignment = .fill     // uniform cap height whatever each cap's content is
            return row
        }
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = Self.spacing
        stack.distribution = .fillEqually
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.inset),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        caps = Shortcuts.load().map { key in
            let b = makeButton(key)
            if key.kind == .ctrl { ctrlButton = b }
            return b
        }
        arrangedWidth = -1        // new caps → split again on the next layout pass
        setNeedsLayout()
        refreshCtrl()
    }

    // Neon keycaps, matching Prosper's theme palette (theme-default/theme.json):
    // dark card fill, electric-cyan hairline border + glow, bright-cyan glyphs.
    private enum Neon {
        static let blue       = UIColor(hex: 0x21CCFF)   // electric cyan border/glow
        static let blueBright = UIColor(hex: 0x75EBFF)   // glyph highlight
        static let card       = UIColor(hex: 0x131923)   // keycap fill
        static let pressed    = UIColor(hex: 0x24405A)   // keycap fill under the finger
        static let text       = UIColor(hex: 0xE8F2FC)   // primary text
    }
    private static let capFont: UIFont = {
        let base = UIFont.systemFont(ofSize: 15, weight: .medium)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: d, size: 15)
    }()
    private func makeButton(_ key: ShortcutKey) -> KeyCapButton {
        var cfg = UIButton.Configuration.plain()
        cfg.baseForegroundColor = Neon.blueBright
        cfg.contentInsets = .init(top: 5, leading: 12, bottom: 5, trailing: 12)
        if let sym = key.systemImage {
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
        let b = KeyCapButton(configuration: cfg)
        b.idleFill = Neon.card
        b.pressedFill = Neon.pressed
        // Neon halo.
        b.layer.shadowColor = Neon.blue.cgColor
        b.layer.shadowOpacity = 0.5
        b.layer.shadowRadius = 5
        b.layer.shadowOffset = .zero
        b.layer.masksToBounds = false
        // Tap on touch-DOWN, like the keyboard: feedback has to land under the finger,
        // not on release. The key itself still fires on touchUpInside.
        b.addAction(UIAction { [weak self] _ in self?.tap() }, for: .touchDown)
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
        cfg.baseForegroundColor = ctrlArmed ? UIColor(hex: 0x05080D) : Neon.blueBright
        b.configuration = cfg
        b.pressedFill = ctrlArmed ? Neon.blueBright : Neon.pressed
        b.idleFill = ctrlArmed ? Neon.blue : Neon.card      // applies the fill
        b.idleGlow = ctrlArmed ? 0.9 : 0.5
    }

    /// One generator, kept warm: creating one per press costs the first tap its latency.
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private func tap() {
        haptics.impactOccurred(intensity: 0.7)   // lighter than a full impact — key-sized
        haptics.prepare()                        // stay warm for the next key
    }
}

/// A keycap that answers the finger: the fill lifts, the cap sinks a hair and the halo
/// flares on touch-down, then springs back — the keyboard's own press language. Purely
/// visual; the haptic is fired by the bar, which owns the one warm generator.
final class KeyCapButton: UIButton {
    /// Resting fill. Setting it re-applies immediately, so the ctrl cap can flip between
    /// armed and idle without knowing whether it's mid-press.
    var idleFill: UIColor = .clear { didSet { applyFill() } }
    var pressedFill: UIColor = .clear
    /// Resting halo strength — armed ctrl glows harder than the rest.
    var idleGlow: Float = 0.5 { didSet { if !isHighlighted { layer.shadowOpacity = idleGlow } } }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            applyFill()
            layer.shadowOpacity = isHighlighted ? 1 : idleGlow
            // Down fast, back slower: an instant release reads as a bounce, and a slow
            // press-in reads as lag. allowUserInteraction so a fast run of keys isn't
            // swallowed by the animation.
            let down = isHighlighted
            UIView.animate(withDuration: down ? 0.05 : 0.13, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = down ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            }
        }
    }

    private func applyFill() {
        guard var cfg = configuration else { return }
        let want = isHighlighted ? pressedFill : idleFill
        guard cfg.background.backgroundColor != want else { return }
        cfg.background.backgroundColor = want
        configuration = cfg
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

    /// Written through `TerminalPrefs` rather than @AppStorage so the clamp and the
    /// flush apply to the stepper too — one writer for the one stored size.
    @State private var fontSize = Double(TerminalPrefs.fontSize)

    var body: some View {
        NavigationStack {
            List {
                Section("Text size") {
                    Stepper(value: $fontSize,
                            in: Double(TerminalPrefs.range.lowerBound)...Double(TerminalPrefs.range.upperBound),
                            step: Double(TerminalPrefs.step)) {
                        Text("\(fontSize, specifier: "%.1f") pt").font(.body.monospaced())
                    }
                    Button("Reset text size") { fontSize = Double(TerminalPrefs.defaultSize) }
                }
                .onChange(of: fontSize) { v in TerminalPrefs.fontSize = CGFloat(v) }
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
