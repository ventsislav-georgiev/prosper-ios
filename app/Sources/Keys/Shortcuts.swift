import UIKit
import UniformTypeIdentifiers

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
/// as JSON in the App Group, `shared`), and the default set. The system keyboard's
/// toolbar (`SuggestionBar.addToolbar`) keeps its own list there (`Bar.toolbar`).
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

    /// The system keyboards' toolbar's text edits (`Bar.toolbar`, by `hostKey`, never the bytes),
    /// all the terminal's too (#603), as readline keystrokes. Readline's M-f stops at the word's
    /// end, so word end sends next word's. Delete all is delete line's ^E ^U: a terminal can't
    /// select or clear a whole multi-line input safely (Claude Code's esc esc opens its rewind
    /// menu; ^C interrupts). Copy line has no bytes: the terminal copies the caret's line off
    /// the screen (`TerminalHostVC.copyCaretLine`), and cut line copies it so, then deletes it.
    static let hostOnly: [ShortcutKey] = [
        ShortcutKey(id: "wordNext", label: "next word",     kind: .bytes, bytes: [0x1b, 0x66], systemImage: "chevron.right.2"),
        ShortcutKey(id: "wordEnd",  label: "word end",      kind: .bytes, bytes: [0x1b, 0x66], systemImage: "forward.end"),
        ShortcutKey(id: "wordBack", label: "previous word", kind: .bytes, bytes: [0x1b, 0x62], systemImage: "chevron.left.2"),
        ShortcutKey(id: "delWord",  label: "delete word",   kind: .bytes, bytes: [0x17], systemImage: "delete.left"),
        // ^U: readline and Claude Code's prompt delete to the line's start; zsh's kills the whole line.
        ShortcutKey(id: "delHome",  label: "delete to line start", kind: .bytes, bytes: [0x15], systemImage: "delete.left.fill"),
        ShortcutKey(id: "delEnd",   label: "delete to line end",   kind: .bytes, bytes: [0x0b], systemImage: "delete.right.fill"),
        ShortcutKey(id: "delLine",  label: "delete line",   kind: .bytes, bytes: [0x05, 0x15], systemImage: "strikethrough"),
        ShortcutKey(id: "delAll",   label: "delete all",    kind: .bytes, bytes: [0x05, 0x15], systemImage: "trash"),
        ShortcutKey(id: "copyLine", label: "copy line",     kind: .bytes, systemImage: "doc.on.doc"),
        ShortcutKey(id: "cutLine",  label: "cut line",      kind: .bytes, bytes: [0x05, 0x15], systemImage: "scissors"),
    ]

    /// The clipboard history (#597): the toolbar's, and the terminal's too (#603), where a
    /// picked clip goes to the pty as a paste (`TerminalHostVC.showClips`). No bytes: each bar
    /// acts on it by id. In the default toolbar, which fits a portrait phone without scrolling
    /// (`ShortcutCapTests.testDefaultToolbarFitsPortraitPhones`).
    static let clipboard = ShortcutKey(id: "clips", label: "clipboard history", kind: .bytes,
                                       systemImage: "list.clipboard")
    /// Speech-to-text (#598) by Prosper's mic (`DictationClient`): the toolbar's, and the
    /// terminal's too (#604), where the mic is the app's own (`TerminalHostVC.dictate`).
    /// In the default toolbar on iOS 26 only, where it runs.
    static let dictate = ShortcutKey(id: "mic", label: "dictate", kind: .bytes, systemImage: "mic")
    /// Snippets (#609): their panel, the toolbar's and the terminal's, where a pick goes to the pty
    /// as a paste (`TerminalHostVC.showSnippets`). In the default toolbar, as the clipboard.
    static let snippets = ShortcutKey(id: "snips", label: "snippets", kind: .bytes, systemImage: "text.quote")
    /// Quicklinks (#613): their panel, as the snippets', a pick typing the filled URL
    /// (`TerminalHostVC.showQuicklinks`). In the default toolbar, as the clipboard.
    static let quicklinks = ShortcutKey(id: "qlinks", label: "quicklinks", kind: .bytes, systemImage: "link")
    /// Fix, Rewrite and Summarize (#612): their panel (`AIPanel`), the toolbar's only: the
    /// terminal's text is a shell's. Added in the editor, as the clipboard.
    static let rewrite = ShortcutKey(id: "rewrite", label: "rewrite", kind: .bytes, systemImage: "wand.and.stars")
    /// The system keyboard toggle's menu (#691), in the terminal: `TerminalHostVC.showMenu`.
    /// Added in the editor, as the clipboard.
    static let menu = ShortcutKey(id: "menu", label: "menu", kind: .bytes, systemImage: "command")

    /// The terminal bar's own keys with no bytes, which `TerminalHostVC.handleKey` acts on by
    /// id. None on the Mac: no Prosper keyboard there fills the history, dictation is off there
    /// (#598), and the Mac's own Prosper expands its snippets in any window, this one too (#609),
    /// and opens its quicklinks (#613).
    /// The mic only where SpeechAnalyzer runs, iOS 26, as the toolbar's.
    static var terminalActions: [ShortcutKey] {
        #if targetEnvironment(macCatalyst)
        []
        #else
        guard #available(iOS 26, *) else { return [clipboard, snippets, quicklinks, menu] }
        return [clipboard, snippets, quicklinks, dictate, menu]
        #endif
    }

    /// The send key: every terminal bar has it, and the editor can't remove it there.
    static let sendID = "enter"

    /// Two rows of eight on a phone, columns paired: paste/esc, paste img/ctrl, ↑/previous
    /// word, ↓/next word, tab/pgup, →/pgdn, home/end, insert/send. The word keys are `hostOnly`,
    /// so the ids resolve from all the terminal bar offers.
    static let defaultIDs = ["paste", "pasteImg", "up", "down", "tab", "right", "home", "insert",
                             "esc", "ctrl", "wordBack", "wordNext", "pgup", "pgdn", "end", "enter"]
    static var defaults: [ShortcutKey] {
        defaultIDs.compactMap { id in Bar.terminal.catalog.first { $0.id == id } }
    }

    /// Past default bars, newest first: before the word keys (#690), and before ctrl/alt/shift
    /// were sticky and enter became send. A saved bar that is exactly one was never
    /// customised, so it loads as today's default.
    static let previousDefaultIDs = [
        ["paste", "pasteImg", "up", "down", "tab", "shift", "home", "insert",
         "esc", "ctrl", "left", "right", "pgup", "pgdn", "end", "enter"],
        ["paste", "pasteImg", "up", "down", "stab", "snl", "enter",
         "esc", "ctlc", "left", "right", "pgup", "pgdn", "insert"],
    ]
    /// The toolbars seeded from those bars (their keys a text field can use, less send), which
    /// were saved on first load: one exactly so was never customised either.
    static let previousToolbarIDs = [["paste", "up", "down", "tab", "home", "left", "right", "end"]]

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
        guard let keys = decode(store?.string(forKey: storageKey)), !keys.isEmpty else { return defaults }
        if previousDefaultIDs.contains(keys.map(\.id)) { return defaults }
        // Keep the user's SET and ORDER, but take each key's definition from the
        // catalog: a saved bar from an older build otherwise pins the old bytes/kind
        // forever (an image-paste key stuck on plain ctrl-V, say). A bar without the
        // send key gets it at the end — it is the only way to submit.
        var loaded = keys.map { saved in Bar.terminal.catalog.first { $0.id == saved.id } ?? saved }
        if !loaded.contains(where: { $0.id == sendID }), let send = catalog.first(where: { $0.id == sendID }) {
            loaded.append(send)
        }
        return loaded
    }

    static func save(_ keys: [ShortcutKey], to store: UserDefaults = shared(), key: String = storageKey) {
        guard let data = try? JSONEncoder().encode(keys),
              let s = String(data: data, encoding: .utf8) else { return }
        store.set(s, forKey: key)
    }

    private static func decode(_ raw: String?) -> [ShortcutKey]? {
        guard let data = raw?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ShortcutKey].self, from: data)
    }

    /// The two lists the editor edits: the terminal's bar, and the system keyboards' toolbar,
    /// which keeps its own in the same store under its own key.
    enum Bar {
        case terminal, toolbar

        var storageKey: String { self == .terminal ? Shortcuts.storageKey : "toolbarKeys" }
        /// What the editor offers: on the terminal, every toolbar key (#604), all the edits
        /// (nothing to hold back) and its actions; on the toolbar, the keys a text field can
        /// use (`hostKey`).
        var catalog: [ShortcutKey] {
            self == .terminal ? Shortcuts.catalog + hostOnly + terminalActions
                : (Shortcuts.catalog + hostOnly + [clipboard, snippets, quicklinks, dictate, rewrite]).filter { hostKey($0.id) != nil }
        }
        /// The toolbar's own (#690). The mic only on iOS 26, where it runs: below it the
        /// keyboard hides it (`SuggestionBar.addToolbar`), so the editor shouldn't list it.
        var defaults: [ShortcutKey] {
            guard self == .toolbar else { return Shortcuts.defaults }
            var ids = ["home", "wordBack", "wordNext", "end", "mic", "qlinks", "snips", "clips"]
            if #unavailable(iOS 26) { ids.removeAll { $0 == dictate.id } }
            return ids.compactMap { id in catalog.first { $0.id == id } }
        }
        /// Only the terminal's: there it is the only way to submit.
        var sendMandatory: Bool { self == .terminal }

        /// The toolbar's saved keys, as the catalog defines them; nil (no Full Access) is the
        /// default. None saved yet: seeded once, and saved, from a customised terminal bar's
        /// keys in the toolbar's catalog, plus paste; else the default.
        func load(_ store: UserDefaults? = shared()) -> [ShortcutKey] {
            guard self == .toolbar else { return Shortcuts.load(store) }
            guard let store else { return defaults }
            if let keys = decode(store.string(forKey: storageKey)) {
                if previousToolbarIDs.contains(keys.map(\.id)) { return defaults }
                return keys.compactMap { saved in catalog.first { $0.id == saved.id } }
            }
            let bar = Shortcuts.load(store)
            var seeded = defaults
            if bar.map(\.id) != Shortcuts.defaults.map(\.id) {
                seeded = bar.compactMap { k in catalog.first { $0.id == k.id } }
                if !seeded.contains(where: { $0.id == "paste" }), let paste = catalog.first(where: { $0.id == "paste" }) {
                    seeded.insert(paste, at: 0)
                }
            }
            save(seeded, to: store, key: storageKey)
            return seeded
        }
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
        /// The clip, through the system's Paste control (`ShortcutBar`'s `oneRow`), only with
        /// Full Access.
        case paste
        case edit(Edit)
        /// The clipboard history's panel in the keys' place, or the keys back (#597); only
        /// with Full Access.
        case clipboard
        /// Dictation's start, or its Done (#598); only with Full Access, on iOS 26.
        case dictate
        /// The snippets' panel in the keys' place, or the keys back (#609); only with Full Access.
        case snippets
        /// The quicklinks' panel in the keys' place, or the keys back (#613); only with Full Access.
        case quicklinks
        /// Fix, Rewrite and Summarize's panel, or the keys back (#612); only with Full Access, on
        /// iOS 26, the English layout.
        case rewrite
    }

    /// nvim's motions and deletes, and its yank and cut of a line (`SuggestionBar.edit`).
    enum Edit: Equatable {
        case wordNext, wordEnd, wordBack, deleteWord, deleteToStart, deleteToEnd, deleteLine, deleteAll
        case copyLine, cutLine
        /// Writes the pasteboard: Full Access only.
        var copies: Bool { self == .copyLine || self == .cutLine }
    }

    /// The toolbar's action for a catalog id; nil hides the key there. The terminal-only
    /// ones (escape sequences, modifiers, control keys, image paste, insert, redraw) mean
    /// nothing in a text field.
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
        case "paste": return .paste
        case clipboard.id: return .clipboard
        case dictate.id: return .dictate
        case snippets.id: return .snippets
        case quicklinks.id: return .quicklinks
        case rewrite.id: return .rewrite
        case "wordNext": return .edit(.wordNext)
        case "wordEnd": return .edit(.wordEnd)
        case "wordBack": return .edit(.wordBack)
        case "delWord": return .edit(.deleteWord)
        case "delHome": return .edit(.deleteToStart)
        case "delEnd": return .edit(.deleteToEnd)
        case "delLine": return .edit(.deleteLine)
        case "delAll": return .edit(.deleteAll)
        case "copyLine": return .edit(.copyLine)
        case "cutLine": return .edit(.cutLine)
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
/// (the keyboard extension's toolbar, whose strip has a fixed height), its paste key the
/// system's Paste control, which pastes into the bar (`onPaste`) with no Allow Paste prompt.
final class ShortcutBar: UIView {
    private static let inset: CGFloat = 4       // above and below the caps
    private static let capHeight: CGFloat = 36
    /// The scroll view reaches this far past the caps, the stack inset back by it, so a Mac
    /// theme's glow (radius 5) isn't cut into a band at its edges (#642). Nothing moves: the
    /// caps keep their frames, and the frame and content grow alike, so it scrolls as far.
    static let glowRoom: CGFloat = 8
    private static let spacing: CGFloat = 6     // between caps, and between the rows
    var onKey: ((ShortcutKey) -> Void)?
    /// The Paste control's clip (`oneRow`).
    var onPaste: (([NSItemProvider]) -> Void)?
    /// Each sticky modifier's state, set by the owner; a missing kind is off.
    var modes: [ShortcutKey.Kind: ShiftState.Mode] = [:] { didSet { refreshModifiers() } }
    var ctrlArmed: Bool { (modes[.ctrl] ?? .off) != .off }
    /// Off while the session refuses input: VoiceOver reads every cap as dimmed.
    var capsEnabled = true { didSet { refreshEnabled() } }
    private var modifierCaps: [ShortcutKey.Kind: KeyCapButton] = [:]
    private weak var container: UIView?
    private var caps: [KeyCapButton] = []
    /// Each key's cap by id, for the owner to lay over the bar around one (#654).
    private(set) var capByID: [String: UIView] = [:]
    private var rows: [UIStackView] = []        // [top, bottom]; `oneRow`'s bottom only with `twoRows`
    private let keys: () -> [ShortcutKey]
    private let oneRow: Bool
    /// `oneRow` in two rows (Numbers: Key, #625): the keys split where the longer row is
    /// shortest (`balancedSplit`), each row filled to the bar's width (#636).
    var twoRows = false { didSet { if twoRows != oldValue { arrangedWidth = -1; setNeedsLayout() } } }
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
        // On the keyboard's backdrop so the strip reads as part of it: `oneRow` on the
        // keyboard's own (#622), the app's in the theme's (`build`, #642). The system's chrome
        // blur followed the app's dark look, a dark band over Light keys and a grey one over True Black.
        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.container = content
        if oneRow { pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier]) }
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() { build() }

    override func paste(itemProviders: [NSItemProvider]) { onPaste?(itemProviders) }

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
    /// only ever widened; a two-row grid overflowing by under 8% is squeezed the same way,
    /// and a wider overflow keeps its widths and scrolls. The split always reads natural widths,
    /// never the widened or squeezed ones. `oneRow` is never widened: it keeps natural widths,
    /// left-aligned, unless it overflows by under 14% (`minRowScale`), then its caps squeeze
    /// to fit around the fixed 44 pt Paste cap. `twoRows` widens each row to span the bar (#636).
    override func layoutSubviews() {
        if bounds.width != arrangedWidth, oneRow {
            arrangedWidth = bounds.width
            let items = rows.flatMap(\.arrangedSubviews)
            let k = twoRows ? Self.balancedSplit(items.map { ($0 as? KeyCapButton)?.naturalWidth ?? 44 },
                                                 spacing: Self.spacing) : items.count
            for (i, item) in items.enumerated() { rows[i < k ? 0 : 1].addArrangedSubview(item) }
            rows[1].isHidden = k == items.count
            for row in rows {
                let caps = row.arrangedSubviews.compactMap { $0 as? KeyCapButton }
                let natural = caps.map(\.naturalWidth)
                let fixed = CGFloat(row.arrangedSubviews.count - caps.count)   // the Paste caps
                let available = bounds.width - 16 - fixed * (44 + Self.spacing)
                let span = natural.reduce(0, +) + Self.spacing * CGFloat(max(0, caps.count - 1))
                let cols = span <= available && !twoRows ? natural : Self.filled(natural, spacing: Self.spacing,
                    available: available, minScale: Self.minRowScale, pixel: 1 / max(1, traitCollection.displayScale))
                for (cap, w) in zip(caps, cols) { cap.columnWidth = w }
            }
        }
        if bounds.width != arrangedWidth, !oneRow {
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
    /// needs 0.927 on a 375 pt phone (#690); a squeezed cap takes it out of its side padding.
    static let minFillScale: CGFloat = 0.92
    /// `oneRow`'s: the default toolbar with Paste needs 0.873 on a 375 pt phone (an arrow cap
    /// 31.4 pt). A cap keeps 86% of its glyph plus 16 pt, so a glyph under 98 pt never truncates.
    static let minRowScale: CGFloat = 0.86

    /// Fits (`sum + spacing` < available), or would at `minScale` → scale every width
    /// by one factor so the span equals `available`, edges floored to the `pixel` grid so
    /// rounding never overshoots (a sub-pixel gap at the end is accepted). Overflows by
    /// more → unchanged, so it scrolls.
    static func filled(_ widths: [CGFloat], spacing: CGFloat, available: CGFloat,
                       minScale: CGFloat = minFillScale, pixel: CGFloat = 0.5) -> [CGFloat] {
        let sum = widths.reduce(0, +)
        let gaps = spacing * CGFloat(max(0, widths.count - 1))
        guard sum > 0, sum * minScale + gaps <= available else { return widths }
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

    /// `twoRows`' top row: the count whose longer row is the shortest, ties to the fuller top.
    static func balancedSplit(_ widths: [CGFloat], spacing: CGFloat) -> Int {
        guard widths.count > 1 else { return widths.count }
        func span(_ w: ArraySlice<CGFloat>) -> CGFloat { w.reduce(0, +) + spacing * CGFloat(max(0, w.count - 1)) }
        func longer(_ k: Int) -> CGFloat { max(span(widths[..<k]), span(widths[k...])) }
        return (1..<widths.count).min { longer($0) < longer($1) || (longer($0) == longer($1) && $0 > $1) }!
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
        if !oneRow { backgroundColor = Style.backdrop }
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
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8 - Self.glowRoom),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: Self.glowRoom - 8),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset - Self.glowRoom),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: Self.glowRoom - Self.inset),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Self.glowRoom),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Self.glowRoom),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Self.glowRoom),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Self.glowRoom),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -2 * Self.glowRoom),
        ])

        rows[1].isHidden = oneRow   // `layoutSubviews` shows it for `twoRows`
        caps = []
        capByID = [:]
        for key in keys() {
            if oneRow, key.kind == .pasteText {
                rows[0].addArrangedSubview(makePasteControl())
                continue
            }
            let b = makeButton(key)
            if [.ctrl, .alt, .shift].contains(key.kind) { modifierCaps[key.kind] = b }
            caps.append(b)
            capByID[key.id] = b
            if oneRow { rows[0].addArrangedSubview(b) }   // `layoutSubviews` splits only two
        }
        arrangedWidth = -1        // new caps → split again on the next layout pass
        setNeedsLayout()
        refreshModifiers()
        refreshEnabled()
    }

    private func refreshEnabled() {
        caps.forEach { $0.accessibilityTraits = capsEnabled ? .button : [.button, .notEnabled] }
    }

    // The keyboard's caps (#626): the theme's special fill, a hairline border, a crisp
    // bottom shadow, no glow; the accent only on send and a lit modifier. In the Toolbar
    // theme's colours (`bar`, #642), a Mac theme's neon outline and glow with it.
    private typealias Style = TerminalKeyboard.Style
    private var bar: Style.Palette { Style.bar }
    private static let capFont: UIFont = {
        let base = UIFont.systemFont(ofSize: 15, weight: .medium)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: d, size: 15)
    }()
    private func makeButton(_ key: ShortcutKey) -> KeyCapButton {
        let bar = self.bar
        var cfg = UIButton.Configuration.plain()
        cfg.baseForegroundColor = bar.icon
        cfg.contentInsets = .init(top: 5, leading: KeyCapButton.padding, bottom: 5, trailing: KeyCapButton.padding)
        if let sym = key.systemImage {
            cfg.image = UIImage(systemName: sym,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        } else {
            cfg.title = key.label
            cfg.titleTextAttributesTransformer = .init { var c = $0; c.font = Self.capFont; return c }
        }
        cfg.background.backgroundColor = bar.surface
        cfg.background.cornerRadius = Style.radius
        cfg.cornerStyle = .fixed     // .dynamic grows the radius with the text size; Paste's stays put
        cfg.background.strokeColor = bar.border
        cfg.background.strokeWidth = 1
        let send = key.id == Shortcuts.sendID   // the toolbar's action key: the accent (#626)
        if send {
            cfg.baseForegroundColor = bar.onAccent
            cfg.background.image = bar.washImage
            cfg.background.imageContentMode = .scaleToFill
        }
        let b = KeyCapButton(configuration: cfg)
        b.accessibilityLabel = key.label   // an icon cap would otherwise read its SF Symbol name
        b.idleFill = send ? bar.accent : bar.surface
        b.pressedFill = send ? bar.accent : bar.surfacePressed
        Self.shade(b, glow: bar.glow)
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
            led.backgroundColor = bar.onAccent
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
        return b
    }

    /// The keys' crisp 1 pt bottom shadow, no glow (#626), or a dark Mac theme's halo in
    /// `glow` (#642), which `trace` gives its path.
    static func shade(_ v: UIView, glow: UIColor? = nil) {
        v.layer.shadowColor = (glow ?? .black).cgColor
        v.layer.shadowOpacity = glow == nil ? 0.35 : 0.5
        v.layer.shadowRadius = glow == nil ? 0 : 5
        v.layer.shadowOffset = glow == nil ? CGSize(width: 0, height: 1) : .zero
        v.layer.shadowPath = nil
        v.layer.masksToBounds = false
        (v as? KeyCapButton)?.idleGlow = v.layer.shadowOpacity
    }

    /// A glowing cap's halo drawn from its rounded bounds (#642): without a `shadowPath` each
    /// is rendered offscreen every frame, past what 40 caps afford. Made again only for new bounds.
    static func trace(_ v: UIView) {
        guard v.layer.shadowRadius > 0, v.layer.shadowPath?.boundingBox != v.bounds else { return }
        v.layer.shadowPath = UIBezierPath(roundedRect: v.bounds, cornerRadius: Style.radius).cgPath
    }

    /// The system's secure Paste as a cap: a tap hands the clip to `paste(itemProviders:)`,
    /// where reading `UIPasteboard.string` raises Allow Paste on every tap. It draws blank
    /// under its content's size, or above Large text. With nothing on the pasteboard it takes, the
    /// system draws it disabled — a dimmed glyph on a faded fill, the base colours ignored —
    /// so the cap's frame is a view of ours behind it (`pasteCap`), the same either way.
    private func makePasteControl() -> UIView {
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconOnly
        config.baseForegroundColor = bar.icon
        config.baseBackgroundColor = bar.surface
        config.cornerStyle = .fixed
        config.cornerRadius = Style.radius - 1   // concentric inside the cap's, 1 pt in
        let control = UIPasteControl(configuration: config)
        control.maximumContentSizeCategory = .large
        control.target = self
        return pasteCap(around: control)
    }

    /// A cap like `makeButton`'s (fill, 1 pt border, radius, shadow) with `control` inside it,
    /// 1 pt in at the sides and as near 1 pt as its own height allows above and below, so
    /// the border shows. Nothing goes over the control: the secure control refuses taps
    /// when covered. Its intrinsic height (34.3 pt at Large) is required — under its
    /// content the control draws blank. 44 pt wide.
    private func pasteCap(around control: UIView) -> UIView {
        let cap = PasteCap()
        cap.backgroundColor = bar.surface
        cap.layer.cornerRadius = Style.radius
        cap.layer.borderWidth = 1
        cap.layer.borderColor = bar.border.cgColor
        Self.shade(cap, glow: bar.glow)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        cap.addSubview(control)
        let inset = control.topAnchor.constraint(equalTo: cap.topAnchor, constant: 1)
        inset.priority = .defaultHigh       // gives way to the control's height
        NSLayoutConstraint.activate([
            cap.widthAnchor.constraint(equalToConstant: 44),
            control.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 1),
            control.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -1),
            control.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: cap.topAnchor),
            inset,
        ])
        return cap
    }

    /// once = the accent's fill and its glyph colour (#626); locked = the once look plus a bar
    /// in that colour under the label; off = like the rest.
    private func refreshModifiers() {
        for (kind, b) in modifierCaps {
            guard var cfg = b.configuration else { continue }
            let mode = modes[kind] ?? .off
            let on = mode != .off
            cfg.baseForegroundColor = on ? bar.onAccent : bar.icon
            cfg.background.image = on ? bar.washImage : nil
            b.configuration = cfg
            b.pressedFill = on ? bar.accent : bar.surfacePressed
            b.idleFill = on ? bar.accent : bar.surface      // applies the fill
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

/// A keycap that answers the finger: the fill lifts, the cap sinks a hair and its shadow
/// deepens on touch-down, then springs back — the keyboard's own press language. Purely
/// visual; the haptic is fired by the bar, which owns the one warm generator.
final class KeyCapButton: UIButton {
    /// Resting fill. Setting it re-applies immediately, so the ctrl cap can flip between
    /// armed and idle without knowing whether it's mid-press.
    var idleFill: UIColor = .clear { didSet { applyFill() } }
    var pressedFill: UIColor = .clear
    /// Resting shadow strength.
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
    /// A modifier cap's locked light; nil on other caps.
    var led: UIView?
    /// The width the cap's content wants, ignoring `columnWidth` — never narrower than the
    /// 36pt cap is tall, so a lone arrow or ^C starts square (a squeeze can still take it
    /// to about 33x36, 31x36 in `oneRow`).
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

    override func layoutSubviews() {
        super.layoutSubviews()
        ShortcutBar.trace(self)
    }

    private func applyFill() {
        guard var cfg = configuration else { return }
        let want = isHighlighted ? pressedFill : idleFill
        guard cfg.background.backgroundColor != want else { return }
        cfg.background.backgroundColor = want
        configuration = cfg
    }
}

/// Paste's cap (`ShortcutBar.pasteCap`), its glow traced as a `KeyCapButton`'s (#642).
private final class PasteCap: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        ShortcutBar.trace(self)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red:   CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8)  & 0xff) / 255,
                  blue:  CGFloat( hex        & 0xff) / 255,
                  alpha: 1)
    }
}
