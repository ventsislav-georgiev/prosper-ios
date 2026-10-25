import UIKit

/// One key on the shortcut bar above the keyboard. `bytes` are sent verbatim to the
/// remote pty; `.ctrl`, `.alt` and `.shift` are sticky modifiers (tap: the next key,
/// double tap: locked) for typed letters and the bar's own keys;
/// `.pasteText` injects the iOS clipboard string; `.insertText` opens a compose
/// sheet whose text is sent as one paste; `.redraw` jiggles the pty size so the
/// remote TUI repaints.
struct ShortcutKey: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case bytes, ctrl, alt, shift, pasteText, pasteImage, insertText, redraw }
    var id: String
    var label: String
    var kind: Kind
    var bytes: [UInt8] = []
    /// SF Symbol name. When set, the keycap shows the icon instead of `label`
    /// (label still used in the editor list + accessibility).
    var systemImage: String? = nil
}

/// Shortcut-bar config: catalog of available keys, the user's chosen set (persisted
/// as JSON in the App Group, `shared`), and the default set. The app's bar and the
/// system keyboard's toolbar (`SuggestionBar.addToolbar`) both read it.
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
        ShortcutKey(id: "alt",     label: "alt",   kind: .alt),
        ShortcutKey(id: "shift",   label: "shift", kind: .shift),
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
        ShortcutKey(id: "pasteImg", label: "paste img", kind: .pasteImage, bytes: [0x16], systemImage: "person.crop.artframe"),
        // Compose locally, send once: the sheet (`InsertTextVC`) hands the whole text
        // to the pty as one bracketed paste — no per-keystroke round-trip.
        ShortcutKey(id: "insert",  label: "insert", kind: .insertText, systemImage: "text.cursor"),
        // ESC+CR = meta/option-enter; Claude Code (and most TUIs) maps it to "insert
        // newline, don't submit". ponytail: relies on Claude's meta-enter binding; if a
        // shell needs a literal LF instead, bytes [0x0a] is the fallback.
        // The same bytes as the compact keyboard's return key (iPhone); where the system
        // keyboard is up, return submits and this is the only newline.
        ShortcutKey(id: "snl",     label: "⇧⏎",    kind: .bytes, bytes: TerminalKeyboard.newlineBytes),
        // Plain CR: submit. The compact keyboard's return types a newline, so this is the
        // only way to send — Slack's paper plane, and mandatory (`sendID`).
        ShortcutKey(id: "enter",   label: "send",  kind: .bytes, bytes: [0x0d], systemImage: "paperplane.fill"),
        // Manual repaint: same size-jiggle the server does on reattach/foreground.
        // Claude Code (and other TUIs) sometimes leave stale/missing glyphs until a
        // SIGWINCH — this is the button form of "resize the window to fix it".
        ShortcutKey(id: "redraw",  label: "redraw", kind: .redraw, systemImage: "arrow.clockwise"),
    ]

    /// The send key: every bar has it, and the editor can't remove it.
    static let sendID = "enter"

    /// Two rows of eight on a phone, columns paired: paste/esc, paste img/ctrl, ↑/←, ↓/→,
    /// tab/pgup, shift/pgdn, home/end, insert/send.
    static var defaults: [ShortcutKey] {
        ["paste", "pasteImg", "up", "down", "tab", "shift", "home", "insert",
         "esc", "ctrl", "left", "right", "pgup", "pgdn", "end", "enter"]
            .compactMap { id in catalog.first { $0.id == id } }
    }

    /// The default bar before ctrl/alt/shift were sticky and enter became send. A saved
    /// bar that is exactly this was never customized, so it loads as today's default.
    static let previousDefaultIDs = ["paste", "pasteImg", "up", "down", "stab", "snl", "enter",
                                     "esc", "ctlc", "left", "right", "pgup", "pgdn", "insert"]

    /// The App Group's defaults (`KeyboardSettings.store`), so the keyboard extension reads
    /// what the editor wrote. A bar the app kept in its own defaults before is copied over,
    /// once (the group's then wins), and left where it was for an older build; the app's
    /// own defaults if there's no group.
    static func shared() -> UserDefaults {
        guard let group = KeyboardSettings.store() else { return .standard }
        if group.string(forKey: storageKey) == nil, let old = UserDefaults.standard.string(forKey: storageKey) {
            group.set(old, forKey: storageKey)
        }
        return group
    }

    /// The saved bar from `store`; nil (the extension without Full Access) is the default set.
    static func load(_ store: UserDefaults? = shared()) -> [ShortcutKey] {
        guard let raw = store?.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let keys = try? JSONDecoder().decode([ShortcutKey].self, from: data),
              !keys.isEmpty
        else { return defaults }
        if keys.map(\.id) == previousDefaultIDs { return defaults }
        // Keep the user's SET and ORDER, but take each key's definition from the
        // catalog: a saved bar from an older build otherwise pins the old bytes/kind
        // forever (an image-paste key stuck on plain ctrl-V, say). A bar without the
        // send key gets it at the end — it is the only way to submit.
        var loaded = keys.map { saved in catalog.first { $0.id == saved.id } ?? saved }
        if !loaded.contains(where: { $0.id == sendID }), let send = catalog.first(where: { $0.id == sendID }) {
            loaded.append(send)
        }
        return loaded
    }

    static func save(_ keys: [ShortcutKey], to store: UserDefaults = shared()) {
        guard let data = try? JSONEncoder().encode(keys),
              let s = String(data: data, encoding: .utf8) else { return }
        store.set(s, forKey: storageKey)
    }

    /// What a key does on the system keyboard's toolbar, in another app's text field.
    enum HostKey: Equatable {
        /// Pressed on the keyboard, as its own key would be.
        case key(TerminalKeyboard.Key)
        /// Characters sideways, negative left (`TerminalKeyboard.caret`).
        case caret(Int)
        /// Lines, negative up (`TerminalKeyboard.line`, the space bar's walk).
        case line(Int)
        /// To the line's start (-1) or end (1), as far as the context shows it.
        case lineEdge(Int)
    }

    /// The toolbar's action for a catalog id; nil hides the key there. The terminal-only
    /// ones (escape sequences, modifiers, control keys, image paste, insert, redraw) mean
    /// nothing in a text field. Paste is the bar's own (`Suggestions.State.paste`), which
    /// shows the suggestions whenever a fresh clip waits.
    static func hostKey(_ id: String) -> HostKey? {
        switch id {
        case "left": return .caret(-1)
        case "right": return .caret(1)
        case "up": return .line(-1)
        case "down": return .line(1)
        case "home": return .lineEdge(-1)
        case "end": return .lineEdge(1)
        case "tab": return .key(.char("\t"))
        case "slash": return .key(.char("/"))
        case "pipe": return .key(.char("|"))
        case "snl", sendID: return .key(.ret)
        default: return nil
        }
    }
}

/// The key strip at the bottom of the terminal: resting on the safe area with the
/// keyboard down, riding its top when it's up. Owned by the terminal view controller
/// and pinned in its own hierarchy (NOT an `inputAccessoryView` — the keyboard's remote
/// input window swallowed touches there). One row when the keys fit, else two rows that
/// scroll horizontally together. Reads its keys from `keys` (`Shortcuts.load()`); call
/// `reload()` after the editor changes them. `oneRow`: one row that scrolls, never two
/// (the keyboard extension's toolbar, whose strip has a fixed height).
final class ShortcutBar: UIView {
    private static let inset: CGFloat = 4       // above and below the caps
    private static let capHeight: CGFloat = 36
    private static let spacing: CGFloat = 6     // between caps, and between the rows
    var onKey: ((ShortcutKey) -> Void)?
    /// Each sticky modifier's state, set by the owner; a missing kind is off.
    var modes: [ShortcutKey.Kind: ShiftState.Mode] = [:] { didSet { refreshModifiers() } }
    var ctrlArmed: Bool { (modes[.ctrl] ?? .off) != .off }
    /// Off while the session refuses input: VoiceOver reads every cap as dimmed.
    var capsEnabled = true { didSet { refreshEnabled() } }
    private var modifierCaps: [ShortcutKey.Kind: KeyCapButton] = [:]
    private weak var container: UIView?
    private var caps: [KeyCapButton] = []
    private var rows: [UIStackView] = []        // [top, bottom], or [top] for `oneRow`
    private let keys: () -> [ShortcutKey]
    private let oneRow: Bool
    private var arrangedWidth: CGFloat = -1     // width the caps were last split for
    /// The bar's height IS its row count, so the owner never needs a number: flipping
    /// it re-asks Auto Layout for `intrinsicContentSize`.
    private(set) var rowCount = 1 {
        didSet { if rowCount != oldValue { invalidateIntrinsicContentSize() } }
    }

    init(keys: @escaping () -> [ShortcutKey] = { Shortcuts.load() }, oneRow: Bool = false) {
        self.keys = keys
        self.oneRow = oneRow
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
    /// Two rows → both caps of column i get that column's width, so the edges line up;
    /// one row → natural widths. A fitting row/grid has every column scaled by one factor
    /// (`filled`) so it spans the bar exactly — one row is kept only when it fits, so it is
    /// only ever widened; a two-row grid overflowing by under 6% is squeezed the same way,
    /// and a wider overflow keeps its widths and scrolls. The split always reads natural widths,
    /// never the widened or squeezed ones.
    override func layoutSubviews() {
        if bounds.width != arrangedWidth, rows.count == 2 {
            arrangedWidth = bounds.width
            let natural = caps.map(\.naturalWidth)
            let k = Self.rowSplit(widths: natural, spacing: Self.spacing, available: bounds.width - 16)
            let cols = Self.filled(k == caps.count ? natural
                : Self.columnWidths(top: Array(natural[..<k]), bottom: Array(natural[k...])),
                spacing: Self.spacing, available: bounds.width - 16,
                pixel: 1 / max(1, traitCollection.displayScale))
            // addArrangedSubview re-parents: a cap leaves whichever row held it.
            for (i, cap) in caps.enumerated() {
                rows[i < k ? 0 : 1].addArrangedSubview(cap)
                cap.columnWidth = cols[i < k ? i : i - k]
            }
            rows[1].isHidden = k == caps.count   // hidden → the stack gives row 1 the full height
            rowCount = rows[1].isHidden ? 1 : 2
        }
        super.layoutSubviews()
    }

    /// Column i of a two-row grid is as wide as the wider of its two caps. The longer
    /// row's tail has no partner, so those columns keep their cap's own width.
    static func columnWidths(top: [CGFloat], bottom: [CGFloat]) -> [CGFloat] {
        (0..<max(top.count, bottom.count)).map { i in
            max(i < top.count ? top[i] : 0, i < bottom.count ? bottom[i] : 0)
        }
    }

    /// The narrowest `filled` squeezes a bar instead of scrolling it: the default 8+8 grid
    /// needs 0.943 on a 375 pt phone; a squeezed cap takes it out of its side padding.
    static let minFillScale: CGFloat = 0.94

    /// Fits (`sum + spacing` < available), or would at `minFillScale` → scale every width
    /// by one factor so the span equals `available`, edges floored to the `pixel` grid so
    /// rounding never overshoots (a sub-pixel gap at the end is accepted). Overflows by
    /// more → unchanged, so it scrolls.
    static func filled(_ widths: [CGFloat], spacing: CGFloat, available: CGFloat,
                       pixel: CGFloat = 0.5) -> [CGFloat] {
        let sum = widths.reduce(0, +)
        let gaps = spacing * CGFloat(max(0, widths.count - 1))
        guard sum > 0, sum * minFillScale + gaps <= available else { return widths }
        let factor = (available - gaps) / sum
        // Floor the running edge, not each width: per-width floors would lose a pixel
        // per column; this loses under one pixel in total.
        var edge: CGFloat = 0, placed: CGFloat = 0
        return widths.map { w in
            edge += w * factor
            let next = (edge / pixel).rounded(.down) * pixel
            defer { placed = next }
            return next - placed
        }
    }

    /// How many caps (in configured order) go in the TOP row. All fit in one row → all
    /// of them (natural widths, no grid). Otherwise the split whose aligned grid — the
    /// `columnWidths` plus spacing, i.e. the bar's scroll content width — is narrowest,
    /// so the bar scrolls as little as possible. Ties go to the LARGER k — the top row
    /// is the fuller one, the way text wraps.
    static func rowSplit(widths: [CGFloat], spacing: CGFloat, available: CGFloat) -> Int {
        func span(_ w: [CGFloat]) -> CGFloat {
            w.reduce(0, +) + spacing * CGFloat(max(0, w.count - 1))
        }
        let n = widths.count
        guard n > 1, span(widths) > available else { return n }
        var best = 1, bestSpan = CGFloat.infinity
        for k in 1..<n {
            let s = span(columnWidths(top: Array(widths[..<k]), bottom: Array(widths[k...])))
            if s <= bestSpan { best = k; bestSpan = s }
        }
        return best
    }

    private func build() {
        guard let container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        modifierCaps = [:]

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.keyboardDismissMode = .none
        scroll.alwaysBounceHorizontal = true          // always draggable, even near-fit
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        // Both rows live in ONE scroll view, so they scroll together as a block. The
        // column is as wide as its longer row (.leading, not .fill).
        rows = (0..<(oneRow ? 1 : 2)).map { _ in
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

        caps = keys().map { key in
            let b = makeButton(key)
            if [.ctrl, .alt, .shift].contains(key.kind) { modifierCaps[key.kind] = b }
            return b
        }
        if oneRow { caps.forEach(rows[0].addArrangedSubview) }   // `layoutSubviews` splits only two
        arrangedWidth = -1        // new caps → split again on the next layout pass
        setNeedsLayout()
        refreshModifiers()
        refreshEnabled()
    }

    private func refreshEnabled() {
        caps.forEach { $0.accessibilityTraits = capsEnabled ? .button : [.button, .notEnabled] }
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
        cfg.contentInsets = .init(top: 5, leading: KeyCapButton.padding, bottom: 5, trailing: KeyCapButton.padding)
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
        if key.id == Shortcuts.sendID {                 // the send key's outer stroke, brighter
            cfg.background.strokeColor = Neon.blue
            cfg.background.strokeWidth = 1.5
        }
        let b = KeyCapButton(configuration: cfg)
        b.accessibilityLabel = key.label   // an icon cap would otherwise read its SF Symbol name
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
        if [.ctrl, .alt, .shift].contains(key.kind) {
            // Locked's bar: a short dark bar (the once glyph colour) under the label, inside
            // the filled cap — "stays on past the next key".
            let led = UIView()
            led.isUserInteractionEnabled = false
            led.backgroundColor = UIColor(hex: 0x05080D)
            led.layer.cornerRadius = 1
            led.isHidden = true
            led.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(led)
            NSLayoutConstraint.activate([
                led.widthAnchor.constraint(equalToConstant: 16),
                led.heightAnchor.constraint(equalToConstant: 2),
                led.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                led.topAnchor.constraint(equalTo: b.titleLabel!.lastBaselineAnchor, constant: 5),
            ])
            b.led = led
        }
        if key.id == Shortcuts.sendID {
            // The send key outshines the rest: a doubled neon border (an inner ring inside
            // the outer stroke) and a stronger halo.
            let ring = UIView()
            ring.isUserInteractionEnabled = false
            ring.layer.borderColor = Neon.blueBright.cgColor
            ring.layer.borderWidth = 1
            ring.layer.cornerRadius = 4.5
            ring.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(ring)
            NSLayoutConstraint.activate([
                ring.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 2.5),
                ring.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -2.5),
                ring.topAnchor.constraint(equalTo: b.topAnchor, constant: 2.5),
                ring.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -2.5),
            ])
            b.ring = ring
            b.layer.shadowRadius = 7
            b.idleGlow = 0.85
        }
        return b
    }

    /// once = solid cyan fill + dark glyph; locked = the once look plus the dark bar under
    /// the label and a slightly stronger halo; off = like the rest.
    private func refreshModifiers() {
        for (kind, b) in modifierCaps {
            guard var cfg = b.configuration else { continue }
            let mode = modes[kind] ?? .off
            let on = mode != .off
            cfg.baseForegroundColor = on ? UIColor(hex: 0x05080D) : Neon.blueBright
            cfg.background.strokeColor = Neon.blue.withAlphaComponent(on ? 1 : 0.55)
            b.configuration = cfg
            b.pressedFill = on ? Neon.blueBright : Neon.pressed
            b.idleFill = on ? Neon.blue : Neon.card      // applies the fill
            b.idleGlow = mode == .off ? 0.5 : mode == .once ? 0.9 : 1
            b.layer.shadowRadius = mode == .locked ? 6 : 5
            b.led?.isHidden = mode != .locked
            b.accessibilityValue = mode == .once ? "on" : mode == .locked ? "locked" : nil
        }
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
    /// Side padding around the glyph at natural width.
    static let padding: CGFloat = 8
    /// The bar's column width; once set the cap is exactly this wide — through its
    /// intrinsic size, so its required hugging holds instead of fighting a width
    /// constraint. Under the content's width (the bar squeezing to fit) the side padding
    /// gives up the difference, so the label never truncates.
    var columnWidth: CGFloat = 0 {
        didSet {
            guard columnWidth != oldValue else { return }
            let side = Self.padding - max(0, contentWidth - columnWidth) / 2
            if var cfg = configuration, cfg.contentInsets.leading != side {
                cfg.contentInsets.leading = side
                cfg.contentInsets.trailing = side
                configuration = cfg
            }
            invalidateIntrinsicContentSize()
        }
    }
    /// A modifier cap's locked light, and the send cap's inner ring; nil on other caps.
    var led: UIView?
    var ring: UIView?
    /// The width the cap's content wants, ignoring `columnWidth` — never narrower than the
    /// 36pt cap is tall, so a lone arrow or ^C starts square (a squeeze can still take it
    /// to about 34x36).
    var naturalWidth: CGFloat { max(contentWidth, 36) }
    /// Content plus full padding, whatever padding a squeeze left on the cap.
    private var contentWidth: CGFloat {
        let insets = configuration?.contentInsets ?? .zero
        return super.intrinsicContentSize.width - insets.leading - insets.trailing + 2 * Self.padding
    }
    override var intrinsicContentSize: CGSize {
        CGSize(width: columnWidth > 0 ? columnWidth : naturalWidth, height: super.intrinsicContentSize.height)
    }

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
