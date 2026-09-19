import UIKit

/// Compose locally, send once. Typing into the terminal is a round-trip per key;
/// here the text is written with the native editor — cursor moves, selection,
/// undo — and only the finished text crosses the wire, as one paste (see
/// `TerminalHostVC.sendText`). Enter is still the user's: the text is inserted at
/// the remote input, not submitted.
final class InsertTextVC: UIViewController, UITextViewDelegate {
    private let editor = UITextView()
    private let onInsert: (String) -> Void

    init(onInsert: @escaping (String) -> Void) {
        self.onInsert = onInsert
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Insert"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Insert", style: .done, target: self, action: #selector(insert))

        editor.font = .preferredFont(forTextStyle: .body)
        // Terminal input: no smart punctuation or capitalization rewriting a command.
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        editor.delegate = self
        editor.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        editor.becomeFirstResponder()
    }

    /// Once there is text, a stray swipe-down must not throw it away; Cancel is explicit.
    func textViewDidChange(_ tv: UITextView) {
        navigationController?.isModalInPresentation = !tv.text.isEmpty
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func insert() {
        let text = editor.text ?? ""
        if !text.isEmpty { onInsert(text) }
        dismiss(animated: true)
    }
}
