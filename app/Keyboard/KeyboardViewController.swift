import UIKit

/// The Prosper keyboard in every other app: the terminal's compact keyboard
/// (`TerminalKeyboard`, Sources/Keys) typing into the host field through
/// `textDocumentProxy`. No `sendBytes`, so return types "\n".
///
/// Above the keys, `SuggestionBar`: suggestions, autocorrect and learning as iOS's own
/// keyboard has them, which a custom keyboard doesn't get (Sources/Keys/Suggestions.swift).
///
/// Launched by the system under a tight memory cap: two views, no network, the pasteboard
/// only with Full Access (the bar's Paste), nothing held beyond the keyboard, the shared
/// spell checker and what it learned.
final class KeyboardViewController: UIInputViewController {
    private let keyboard = TerminalKeyboard()
    private let bar = SuggestionBar()

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboard.target = textDocumentProxy
        // iOS keeps its own strip under a custom keyboard (globe and dictation on Face ID
        // iPhones), so the app's home-gesture pad would only add an empty band.
        keyboard.bottomInset = 6
        keyboard.doubleSpacePeriod = true
        bar.nextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        bar.suggestions.pasteboard = { [weak self] in self?.hasFullAccess == true ? .general : nil }
        bar.attach(keyboard)
        bar.host(keyboard, in: view)
        // Contact names and text replacements; needs no Full Access. Once per controller.
        requestSupplementaryLexicon { [weak self] lexicon in
            self?.bar.suggestions.load(lexicon.entries.map { ($0.userInput, $0.documentText) })
            self?.bar.refresh()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sync()
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

    /// ponytail: Safari reports the previous field's traits (return key, capitalization,
    /// and so textContentType, which picks the login key button) for up to ~500 ms after
    /// `textDidChange` on a field switch; this reads them once. A re-sync after a short
    /// delay would catch up if a stale bar ever shows on device.
    private func sync() {
        keyboard.showsGlobe = needsInputModeSwitchKey
        keyboard.returnTitle = TerminalKeyboard.returnTitle(for: textDocumentProxy.returnKeyType ?? .default)
        keyboard.autoCapitalize()
        bar.refresh()
    }
}
