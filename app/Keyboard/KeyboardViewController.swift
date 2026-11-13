import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The Prosper keyboard in every other app: the terminal's compact keyboard
/// (`TerminalKeyboard`, Sources/Keys) typing into the host field through
/// `textDocumentProxy`. No `sendBytes`, so return types "\n".
///
/// Above the keys, `SuggestionBar`: suggestions, autocorrect and learning as iOS's own
/// keyboard has them, which a custom keyboard doesn't get (Sources/Keys/Suggestions.swift),
/// or at its toggle the toolbar, keys from the app's own list for it (`addToolbar`).
///
/// Launched by the system under a tight memory cap: two views, the network only for a Mac
/// command run from the menu with Full Access (#735: `CommandPanel`, the list and run verbs
/// alone, no polling), the pasteboard only with Full Access (the bar's and the toolbar's
/// Paste), nothing held beyond the keyboard, the shared spell checker and what it learned.
/// The clipboard history (#597) lives on disk in the App Group, shared by both extensions
/// (`ClipboardHistory`). Dictation (#598) hops to Prosper for the mic, then talks to it there
/// (`DictationClient`). Fix, Rewrite and Summarize (#612) run Apple's on-device model, out of
/// process: weak-linked, iOS 26 only.
///
/// Two extensions run this controller, Prosper and Prosper (Bulgarian), each its Info.plist's
/// `PrimaryLanguage`, so the system globe can switch language (#640). Prosper always has the
/// app's Languages setting, Prosper (Bulgarian) when Bulgarian is in it, else Bulgarian only;
/// switched from the toggle's menu and the language key, the last pick kept in the App Group
/// (#624). After a globe hop each opens in its own language (`KeyboardSettings.languages`).
final class KeyboardViewController: UIInputViewController {
    private static let fixed = TerminalKeyboard.Layout(extension: .main)
    /// Prosper, not a language's own extension: its Info.plist names English, as
    /// `Layout(primaryLanguage:)` reads anything not Bulgarian (#640).
    private static let main = fixed == .english
    /// Past `viewDidAppear`: a language change now is the user's switch, not the pick at
    /// appear, so an extension AutoFill only passes through records nothing (#640).
    private var onScreen = false
    private let keyboard = TerminalKeyboard(layout: KeyboardViewController.fixed)
    private let bar = SuggestionBar(suggestions: Suggestions(layout: KeyboardViewController.fixed))

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboard.target = textDocumentProxy
        keyboard.clock = { ProcessInfo.processInfo.systemUptime }
        // iOS keeps its own strip under a custom keyboard (globe and dictation on Face ID
        // iPhones), so the app's home-gesture pad would only add an empty band; this one
        // catches the space taps that land low (`extensionBottomInset`).
        keyboard.bottomInset = TerminalKeyboard.extensionBottomInset
        keyboard.offersEmoji = false
        keyboard.allowsNumbersKey = true   // Numbers: Key (#625); the app's keyboard keeps its row
        bar.inputModeList = { [weak self] in self?.handleInputModeList(from: $0, with: $1) }
        bar.nextKeyboard = { [weak self] in self?.advanceToNextInputMode() }   // the toggle's menu (#623)
        bar.hideKeyboard = { [weak self] in self?.dismissKeyboard() }   // the menu's caption row (#734)
        bar.languageChanged = { [weak self] layout in
            self?.primaryLanguage = layout.primaryLanguage   // the host's dictation and spell check
            if self?.onScreen == true, self?.hasFullAccess == true { KeyboardSettings.activeLanguage = layout }
        }
        bar.suggestions.pasteboard = { [weak self] in self?.hasFullAccess == true ? .general : nil }
        bar.shared = { [weak self] in self?.hasFullAccess == true ? KeyboardSettings.store() : nil }   // the toggle's pick (#648)
        bar.history = ClipboardHistory.shared()
        bar.snippets = SnippetStore.shared()
        bar.quicklinks = QuicklinkStore.shared()
        bar.commandStore = CommandStore.shared()   // #735
        // The stored settings before attach's first refresh: Save Copies is on by default (#601).
        bar.loadSettings(fullAccess: hasFullAccess)   // not attached yet: the bar's alone
        // The memory's store before attach's first refresh too: the clips auto-save checks (#659).
        bar.suggestions.memory.reload(shared: bar.shared())
        // iOS 26's speech engines only; the app has no fallback below it.
        if #available(iOS 26, *), let store = Dictation.Store.shared() {
            let dictation = DictationClient(store: store)
            dictation.open = { [weak self] url, done in self?.openApp(url, done) ?? done(false) }
            bar.dictation = dictation
        }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { Self.model(bar) }
        #endif
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
        let settings = bar.loadSettings(fullAccess: hasFullAccess)   // the keys' and the bar's (#958)
        keyboard.fullAccess = hasFullAccess   // the emoji recents' store (#629)
        let languages = KeyboardSettings.languages(fixed: Self.fixed, main: Self.main, settings: settings,
                                                   fullAccess: hasFullAccess)
        keyboard.languages = languages.all
        keyboard.layout = languages.shown
        keyboard.showNumpad(false, animated: false)   // the letters first in each field, as iOS
        bar.toolbar?.reload()
        bar.showClips(false)   // the keys first, as Gboard: a panel reads afresh at its key
        bar.toolbarOverAutofill = false   // AutoFill first in a new field (#623)
        bar.dictation?.appear()
        bar.appear()   // what the other Prosper keyboard learned, and the Paste poll (#659)
        sync()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onScreen = false
        bar.dictation?.disappear()
        bar.disappear()   // a rewrite under way is dropped (#612)
    }

    #if canImport(FoundationModels)
    /// The bar's model (#612): a session a request, the command's instructions, the permissive
    /// guardrails meant for transforming the user's own text. An error the panel can name is
    /// thrown as its line (`Rewrite.Failure`, #660), any other as it came: the generic line.
    @available(iOS 26, *)
    private static func model(_ bar: SuggestionBar) {
        bar.rewrite = { command, text in
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            do {
                return try await LanguageModelSession(model: model, instructions: command.instructions).respond(to: text).content
            } catch {
                guard let line = line(error, availability()) else { throw error }
                throw Rewrite.Failure(line: line)
            }
        }
        bar.rewriteAvailability = availability
    }

    @available(iOS 26, *)
    private static func availability() -> Rewrite.Availability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable: return .modelNotReady   // and any reason a later iOS adds
        }
    }

    /// A failed request's line (#660), nil for the generic one: the model's availability, read
    /// again after the error, first (the simulator reports `.available` with no assets), then
    /// iOS 26.0's errors, then a bridged chain with the assets missing (`Rewrite.assetsMissing`).
    /// Those cases are deprecated in the iOS 27 SDK and CI builds on 26's; 27's new error types
    /// fall to the generic line.
    @available(iOS 26, *)
    static func line(_ error: Error, _ availability: Rewrite.Availability) -> String? {
        if let reason = availability.reason { return reason }
        switch error as? LanguageModelSession.GenerationError {
        case .assetsUnavailable?: return Rewrite.Availability.modelNotReady.reason
        case .exceededContextWindowSize?: return "Too long for the model. Select less"
        case .guardrailViolation?, .refusal?: return "The model won't change this text"
        case .unsupportedLanguageOrLocale?: return "The model doesn't support this text's language"
        default: return Rewrite.assetsMissing(error) ? Rewrite.Availability.modelNotReady.reason : nil
        }
    }
    #endif

    /// AutoFill on the sibling Prosper keyboard just advanced here: advance once more, past
    /// it, toward Apple's keyboard (`KeyboardSettings.hops`). Else this extension is the one
    /// shown, in its language, for the next to appear to tell a globe hop (#640).
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        TerminalKeyboard.undelayEdges(view.window)
        let mark = KeyboardSettings.takeHop()
        let login = Suggestions.isLoginField(textDocumentProxy)
        let own = Bundle.main.bundleIdentifier ?? ""
        if KeyboardSettings.hops(mark, own: own, now: Date(), login: login) {
            advanceToNextInputMode()
        } else {
            onScreen = true
            KeyboardSettings.shown(Self.fixed, in: keyboard.layout, fullAccess: hasFullAccess)
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
