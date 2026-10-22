import UIKit

/// The Prosper keyboard in every other app: the terminal's compact keyboard
/// (`TerminalKeyboard`, Sources/Keys) typing into the host field through
/// `textDocumentProxy`. No `sendBytes`, so return types "\n".
///
/// Launched by the system under a tight memory cap: one view, no network, no pasteboard,
/// nothing held beyond the keyboard itself.
final class KeyboardViewController: UIInputViewController {
    private let keyboard = TerminalKeyboard()

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboard.target = textDocumentProxy
        // iOS keeps its own strip under a custom keyboard (globe and dictation on Face ID
        // iPhones), so the app's home-gesture pad would only add an empty band.
        keyboard.bottomInset = 6
        keyboard.doubleSpacePeriod = true
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboard)
        NSLayoutConstraint.activate([
            // The top is where a bar above the keys would attach.
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
    }

    private func sync() {
        keyboard.showsGlobe = needsInputModeSwitchKey
        keyboard.returnTitle = TerminalKeyboard.returnTitle(for: textDocumentProxy.returnKeyType ?? .default)
        keyboard.autoCapitalize()
    }
}
