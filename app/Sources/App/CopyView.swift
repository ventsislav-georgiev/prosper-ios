import UIKit

/// Copy mode. The session's text — scrollback and screen — in a native, read-only
/// text view, so selecting is the system's: drag handles, double-tap a word,
/// triple-tap a line, Select All. The selection lands in the editor below, and the
/// editor's text IS the clipboard: trim prompts or joined newlines there before
/// pasting elsewhere. "One line" joins the terminal-wrapped lines of a selection
/// back into one command (`TerminalMath.oneLine`).
final class CopyTextVC: UIViewController, UITextViewDelegate {
    /// Remembered across copy sessions: on next time if the user left it on.
    static let oneLineKey = "copyOneLine"

    private let text: String
    private let cols: Int
    private let source = UITextView()
    private let editor = UITextView()
    private let caption = UILabel()
    private var scrolled = false
    /// The last selection as selected, so the toggle can recompute or restore it.
    private var selection: String?
    private var oneLine = UserDefaults.standard.bool(forKey: CopyTextVC.oneLineKey)
    private lazy var oneLineItem: UIBarButtonItem = {
        let b = UIBarButtonItem(image: UIImage(systemName: "arrow.right.to.line"), style: .plain,
                                target: self, action: #selector(toggleOneLine))
        b.accessibilityLabel = "One line"
        return b
    }()

    init(text: String, cols: Int) {
        self.text = text
        self.cols = cols
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Copy"
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Select All", style: .plain, target: self, action: #selector(selectAllText))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done)),
            oneLineItem,
        ]
        oneLineItem.isSelected = oneLine

        let font = TerminalFont.mono(size: TerminalPrefs.fontSize)
        source.text = text
        source.font = font
        source.textColor = .white
        source.backgroundColor = .black
        source.isEditable = false
        source.alwaysBounceVertical = true
        source.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        source.delegate = self

        editor.font = font
        editor.textColor = .white
        editor.backgroundColor = UIColor(white: 0.12, alpha: 1)
        editor.layer.cornerRadius = 8
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.delegate = self

        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = .secondaryLabel
        updateCaption()

        for v in [source, caption, editor] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            source.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            source.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            source.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            caption.topAnchor.constraint(equalTo: source.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            editor.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 4),
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            editor.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.22),
            // Rides the keyboard: the guide's top is the safe-area bottom while hidden.
            editor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
    }

    /// Open at the end of the text — the prompt and the latest output, where copying
    /// almost always starts — not at the top of the scrollback.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !scrolled, source.bounds.height > 0 else { return }
        scrolled = true
        // UITextView (TextKit 2) lays long text out lazily: contentSize and even the
        // end's caret rect are estimates until then, and scrollRangeToVisible at the
        // end still landed screens short on a long buffer. Lay out the whole document
        // — SwiftTerm keeps 500 lines of scrollback, so this is cheap — and let the
        // view take the real contentSize before pinning to its bottom.
        if let tlm = source.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        source.setNeedsLayout()
        source.layoutIfNeeded()
        let inset = source.adjustedContentInset
        let bottom = source.contentSize.height - source.bounds.height + inset.bottom
        source.setContentOffset(CGPoint(x: 0, y: max(-inset.top, bottom)), animated: false)
    }

    // MARK: - Selection → editor → clipboard

    func textViewDidChangeSelection(_ tv: UITextView) {
        guard tv === source, tv.selectedRange.length > 0,
              let r = tv.selectedTextRange, let s = tv.text(in: r) else { return }
        selection = s
        fillEditor()
    }

    /// The editor gets the selection, joined when "One line" is on. Recomputed from
    /// the raw selection, so toggling off restores it.
    private func fillEditor() {
        guard let selection else { return }
        editor.text = oneLine ? TerminalMath.oneLine(selection, cols: cols) : selection
        sync()
    }

    @objc private func toggleOneLine() {
        oneLine.toggle()
        oneLineItem.isSelected = oneLine
        UserDefaults.standard.set(oneLine, forKey: Self.oneLineKey)
        fillEditor()
        updateCaption()
    }

    func textViewDidChange(_ tv: UITextView) {
        if tv === editor { sync() }
    }

    /// The editor's text is the clipboard. Empty leaves the clipboard alone, so
    /// opening copy mode and closing it never wipes what was copied before.
    private func sync() {
        if !editor.text.isEmpty { UIPasteboard.general.string = editor.text }
        updateCaption()
    }

    private func updateCaption() {
        let n = editor.text.count
        caption.text = (n == 0
            ? "Select text above. What's in this box is what gets pasted."
            : "On the clipboard · \(n) characters") + (oneLine ? " · one line" : "")
    }

    @objc private func selectAllText() {
        source.selectedRange = NSRange(location: 0, length: source.text.utf16.count)
        textViewDidChangeSelection(source)
    }

    @objc private func done() { dismiss(animated: true) }
}
