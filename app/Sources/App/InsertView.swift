import Combine
import UIKit

/// Compose locally, send once. Typing into the terminal is a round-trip per key;
/// here the text is written with the native editor — cursor moves, selection,
/// undo — and only the finished text crosses the wire, as one paste (see
/// `TerminalHostVC.sendText`). Insert leaves Enter to the user; Insert & Send
/// presses it once the paste has landed. While the session refuses input (`accepts`
/// false: `.failed`) Retry stands in for both and the text stays; once input is back they return.
final class InsertTextVC: UIViewController, UITextViewDelegate {
    private let editor = UITextView()
    private let accepts: AnyPublisher<Bool, Never>
    private var acceptsSub: AnyCancellable?
    private let onRetry: () -> Void
    private let onInsert: (String, _ send: Bool) -> Void

    init(accepts: AnyPublisher<Bool, Never>, onRetry: @escaping () -> Void,
         onInsert: @escaping (String, _ send: Bool) -> Void) {
        self.accepts = accepts
        self.onRetry = onRetry
        self.onInsert = onInsert
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Insert"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        // first item sits rightmost. The items are set once and only shown or hidden:
        // re-assigning them stops iOS drawing the prompt, and hidden items take no room,
        // so while failed Retry stands alone and nothing folds into a More menu at 402 pt.
        let send = [
            UIBarButtonItem(title: "Insert & Send", style: .done, target: self, action: #selector(insertAndSend)),
            UIBarButtonItem(title: "Insert", style: .plain, target: self, action: #selector(insert)),
        ]
        let retry = UIBarButtonItem(title: "Retry", style: .plain, target: self, action: #selector(retry))
        navigationItem.rightBarButtonItems = send + [retry]
        acceptsSub = accepts.sink { [weak self] on in
            send.forEach { $0.isHidden = !on }
            retry.isHidden = on
            self?.navigationItem.prompt = on ? nil : "Session failed. Retry before sending."
        }

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
    @objc private func retry() { onRetry() }

    @objc private func insert() { finish(send: false) }
    @objc private func insertAndSend() { finish(send: true) }

    private func finish(send: Bool) {
        let text = editor.text ?? ""
        if !text.isEmpty { onInsert(text, send) }
        dismiss(animated: true)
    }
}
