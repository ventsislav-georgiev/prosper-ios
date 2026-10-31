import UIKit

/// The Prosper keyboard in every other app: the terminal's compact keyboard
/// (`TerminalKeyboard`, Sources/Keys) typing into the host field through
/// `textDocumentProxy`. No `sendBytes`, so return types "\n".
///
/// Above the keys, `SuggestionBar`: suggestions, autocorrect and learning as iOS's own
/// keyboard has them, which a custom keyboard doesn't get (Sources/Keys/Suggestions.swift),
/// or at its toggle the toolbar, keys from the app's own list for it (`addToolbar`).
///
/// Launched by the system under a tight memory cap: two views, no network, the pasteboard
/// only with Full Access (the bar's and the toolbar's Paste), nothing held beyond the
/// keyboard, the shared spell checker and what it learned. The clipboard history (#597)
/// lives on disk in the App Group, shared by both extensions (`ClipboardHistory`). Dictation
/// (#598) hops to Prosper for the mic, then talks to it there (`DictationClient`).
///
/// Two extensions run this controller, both "Prosper", English and Bulgarian: each takes
/// its letters and dictionary from its own Info.plist's `PrimaryLanguage`.
final class KeyboardViewController: UIInputViewController {
    private static let layout = TerminalKeyboard.Layout(extension: .main)
    private let keyboard = TerminalKeyboard(layout: KeyboardViewController.layout)
    private let bar = SuggestionBar(suggestions: Suggestions(layout: KeyboardViewController.layout))

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboard.target = textDocumentProxy
        keyboard.clock = { ProcessInfo.processInfo.systemUptime }
        // iOS keeps its own strip under a custom keyboard (globe and dictation on Face ID
        // iPhones), so the app's home-gesture pad would only add an empty band; this one
        // catches the space taps that land low (`extensionBottomInset`).
        keyboard.bottomInset = TerminalKeyboard.extensionBottomInset
        keyboard.offersEmoji = false
        bar.inputModeList = { [weak self] in self?.handleInputModeList(from: $0, with: $1) }
        bar.suggestions.pasteboard = { [weak self] in self?.hasFullAccess == true ? .general : nil }
        bar.history = ClipboardHistory.shared()
        bar.snippets = SnippetStore.shared()
        bar.quicklinks = QuicklinkStore.shared()
        // The stored settings before attach's first refresh: Save Copies is on by default (#601).
        bar.suggestions.settings = KeyboardSettings.current(fullAccess: hasFullAccess)
        // iOS 26's speech engines only; the app has no fallback below it.
        if #available(iOS 26, *), let store = Dictation.Store.shared() {
            let dictation = DictationClient(store: store)
            dictation.open = { [weak self] url, done in self?.openApp(url, done) ?? done(false) }
            bar.dictation = dictation
        }
        bar.attach(keyboard)
        bar.host(keyboard, in: view)
        // The app's editor writes them to the App Group: without Full Access, the defaults.
        bar.addToolbar { [weak self] in Shortcuts.Bar.toolbar.load(self?.hasFullAccess == true ? Shortcuts.shared() : nil) }
        // Contact names and text replacements; needs no Full Access. Once per controller.
        requestSupplementaryLexicon { lexicon in
            // The lexicon arrives on a background queue; the bar and its state are main-only.
            DispatchQueue.main.async { [weak self] in
                self?.bar.suggestions.load(lexicon.entries.map { ($0.userInput, $0.documentText) })
                self?.bar.refresh()
            }
        }
    }

    /// The app's Keyboard settings are read here, so a change there applies the next time
    /// the keyboard shows. Without Full Access the group is out of reach: the defaults.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let settings = KeyboardSettings.current(fullAccess: hasFullAccess)
        keyboard.settings = settings
        bar.suggestions.settings = settings
        bar.toolbar?.reload()
        bar.showClips(false)   // the keys first, as Gboard: a panel reads afresh at its key
        bar.dictation?.appear()
        sync()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        bar.dictation?.disappear()
    }

    /// AutoFill on the sibling Prosper keyboard just advanced here: advance once more, past
    /// it, toward Apple's keyboard (`KeyboardSettings.hops`).
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        TerminalKeyboard.undelayEdges(view.window)
        let mark = KeyboardSettings.takeHop()
        let login = Suggestions.isLoginField(textDocumentProxy)
        let own = Bundle.main.bundleIdentifier ?? ""
        if KeyboardSettings.hops(mark, own: own, now: Date(), login: login) {
            advanceToNextInputMode()
        }
    }

    /// The host moved to another field, or changed its text itself.
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        sync()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        keyboard.autoCapitalize()
        bar.refresh()
    }

    /// ponytail: Safari reports the previous field's traits for up to ~500 ms after
    /// `textDidChange` on a field switch. The bar and shift read them again after that
    /// (`SuggestionBar.hostChanged`, #599); the return key's title still reads them once.
    private func sync() {
        keyboard.showsGlobe = needsInputModeSwitchKey
        keyboard.returnTitle = TerminalKeyboard.returnTitle(for: textDocumentProxy.returnKeyType ?? .default)
        keyboard.autoCapitalize()
        bar.hostChanged()
    }

    /// Prosper, through the responder chain's `UIApplication`: an extension can't name
    /// `UIApplication.shared`, and `extensionContext.open` is a widget's only (#598).
    private func openApp(_ url: URL, _ done: @escaping (Bool) -> Void) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication { return app.open(url, options: [:], completionHandler: done) }
            responder = r.next
        }
        done(false)
    }
}
