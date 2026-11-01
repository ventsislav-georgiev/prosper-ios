import UIKit

/// Fix, Rewrite and Summarize in the keyboard (#612), by Apple's on-device model (Foundation
/// Models, iOS 26), which the controller injects (`SuggestionBar.rewrite`): nothing here imports
/// it, so the app and iOS 16–25 never touch it. The text is the selection, or else the paragraph
/// before the caret where the context shows all of it (`plan`); the write reads the field again
/// and refuses what it can't prove (`replace`). It never deletes text the model wasn't given:
/// any doubt is Insert only.
enum Rewrite {
    enum Command: String, CaseIterable {
        case fix, rewrite, summarize
        /// Clean Up Dictation's (`SuggestionBar.cleanUp`), at Done: never a panel row.
        case dictation
        /// The panel's rows.
        static var allCases: [Command] { [.fix, .rewrite, .summarize] }

        var title: String {
            switch self {
            case .fix: return "Fix"
            case .rewrite: return "Rewrite"
            case .summarize: return "Summarize"
            case .dictation: return "Clean Up Dictation"
            }
        }

        var detail: String {
            switch self {
            case .fix: return "Spelling, grammar and punctuation"
            case .rewrite: return "Clearer and more natural"
            case .summarize: return "Short, the main points"
            case .dictation: return "Punctuation, capitals, fillers"
            }
        }

        var symbol: String {
            switch self {
            case .fix: return "text.badge.checkmark"
            case .rewrite: return "wand.and.stars"
            case .summarize: return "text.alignleft"
            case .dictation: return "mic"
            }
        }

        /// The model's instructions: the text's own language, and the text alone back.
        var instructions: String {
            let only = " Keep the text's language. Reply with the text only: no quotes, notes or headings."
            switch self {
            case .fix:
                return "Correct the spelling, grammar and punctuation of the user's text. Keep its wording, meaning and tone." + only
            case .rewrite:
                return "Rewrite the user's text so it reads clearer and more natural. Keep its meaning and tone." + only
            case .summarize:
                return "Summarize the user's text in a few short sentences." + only
            case .dictation:
                return "The user's text was dictated. Fix its punctuation and capitalization, correct words that were clearly misheard, and remove filler words such as \"um\" and \"uh\". Keep every other word and the meaning: don't rephrase, add or drop anything else." + only
            }
        }
    }

    /// The model's state (`SystemLanguageModel.Availability`), mapped by the controller.
    enum Availability: Equatable {
        case available, deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady

        /// The panel's one line in its rows' place: why, and what to do; nil while available.
        var reason: String? {
            switch self {
            case .available: return nil
            case .deviceNotEligible: return "This iPhone doesn't support Apple Intelligence"
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings"
            case .modelNotReady: return "The model is still downloading — try again soon"
            }
        }
    }

    /// A failed request the controller could name (#660): its line in the panel. Anything else
    /// thrown shows `failed`. Nothing here sees the model's own errors.
    struct Failure: Error, Equatable { var line: String }
    static let failed = "That didn't work. Try again, or with less text"

    /// The model's assets missing, in a bridged error's chain (#660 QA u): the simulator throws
    /// an NSError of GenerationError's domain, code -1, no Swift case, over a private framework's
    /// "no assets" error. Matched by domain only (that framework isn't imported): any
    /// UnifiedAssetFramework error, or ModelManagerError 1026, under `NSUnderlyingErrorKey` or
    /// `NSMultipleUnderlyingErrorsKey`, `depth` levels down at most.
    static func assetsMissing(_ error: Error, depth: Int = 4) -> Bool {
        let e = error as NSError
        if e.domain == "com.apple.UnifiedAssetFramework" || e.domain == "ModelManagerServices.ModelManagerError" && e.code == 1026 {
            return true
        }
        guard depth > 0 else { return false }
        let under = (e.userInfo[NSUnderlyingErrorKey] as? Error).map { [$0] } ?? []
        return (under + (e.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] ?? [])).contains { assetsMissing($0, depth: depth - 1) }
    }

    /// What a command works on, and the field as it read at the request, for the write's check.
    struct Source: Equatable {
        var text: String
        var selected: Bool
        /// Why Replace isn't offered, nil where it is: Insert only.
        var note: String?
        var before: String
        var after: String
    }

    /// Characters a command takes at most: the model's context is small, and so is a keyboard.
    static let cap = 4000
    /// UTF-16 units under any host's before-context window: Safari cuts it at about 300 (#553
    /// QA). A context without a break this long or longer may be a window's cut, never the start.
    static let window = 200
    static let selectToReplace = "Select the text to replace it"
    static let tooLong = "Over 4,000 characters: only part was used. Select less to replace it"

    /// The text a command takes, nil with none. The selection, if any; else the paragraph
    /// before the caret, its leading blanks left out (Safari's space after a break isn't in the
    /// text). Replace is offered for the paragraph only where the context proves it whole: the
    /// caret at its end (nothing after it on the line), and its start shown, after a break or
    /// at the field's start. A context with no break proves the field's start only short of
    /// `window` and holding a sentence's end before its last: a host that cuts the context at
    /// the caret's sentence (`sentenceBefore` in the tests) never shows one. Else the model gets
    /// the paragraph as shown, the caret's line on after it too, and only Insert is offered.
    ///
    /// ponytail: a lone sentence with no break before it reads the same as a host's cut, so it
    /// is Insert only, or a selection; a host whose window opens at an earlier sentence than the
    /// caret's would pass for the field's start, though the write still deletes only the text
    /// the model had.
    static func plan(before: String?, after: String?, selected: String?) -> Source? {
        let b = before ?? "", a = after ?? ""
        if let s = selected, !s.isEmpty {
            guard s.contains(where: { !$0.isWhitespace }) else { return nil }
            return s.count > cap ? Source(text: String(s.prefix(cap)), selected: true, note: tooLong, before: b, after: a)
                : Source(text: s, selected: true, note: nil, before: b, after: a)
        }
        let brk = b.lastIndex(where: \.isNewline)
        let text = String(b[(brk.map(b.index(after:)) ?? b.startIndex)...].drop { $0.isWhitespace })
        let rest = String(a.prefix { !$0.isNewline })
        guard (text + rest).contains(where: { !$0.isWhitespace }) else { return nil }
        let start = brk != nil || b.utf16.count < window && b.range(of: #"[.!?…][\s]+\S"#, options: .regularExpression) != nil
        guard start, rest.isEmpty else {
            let shown = text + rest
            return Source(text: String(shown.suffix(cap)), selected: false, note: selectToReplace, before: b, after: a)
        }
        return text.count > cap ? Source(text: String(text.suffix(cap)), selected: false, note: tooLong, before: b, after: a)
            : Source(text: text, selected: false, note: nil, before: b, after: a)
    }

    /// Replace, the field read again first; false, and nothing written, where it changed. A
    /// selection is typed over, no delete: only while it, and the text either side, are as
    /// they were. A paragraph only while the text before the caret still ends in it, Character
    /// for Character and unit for unit, and the text after is as it was: its Characters go in
    /// one batch, as `Suggestions.revert`'s do, then the result. No caret moves.
    static func replace(_ s: Source, with result: String, in doc: UITextDocumentProxy) -> Bool {
        guard s.note == nil else { return false }
        let out = fitted(result, to: s.text)
        if s.selected {
            guard same(doc.selectedText ?? "", s.text), same(doc.documentContextBeforeInput ?? "", s.before),
                  same(doc.documentContextAfterInput ?? "", s.after) else { return false }
            doc.insertText(out)
            return true
        }
        guard holds(s, in: doc) else { return false }
        for _ in 0..<s.text.count { doc.deleteBackward() }
        doc.insertText(out)
        return true
    }

    /// A paragraph's (and dictation's, #612) proof: nothing selected, the text after the caret as
    /// it was, and the text before it still ending in `s.text`, Character for Character and
    /// unit for unit.
    static func holds(_ s: Source, in doc: UITextDocumentProxy) -> Bool {
        (doc.selectedText ?? "").isEmpty && same(doc.documentContextAfterInput ?? "", s.after)
            && same(String((doc.documentContextBeforeInput ?? "").suffix(s.text.count)), s.text)
    }

    /// Not proven, nor disproven (#612): the field as `holds` asks, but its before-context, a
    /// host's window, shorter than `s.text` and its end. A dictation too long to check there.
    static func cut(_ s: Source, in doc: UITextDocumentProxy) -> Bool {
        let b = (doc.documentContextBeforeInput ?? "").utf16
        return (doc.selectedText ?? "").isEmpty && same(doc.documentContextAfterInput ?? "", s.after)
            && !b.isEmpty && b.count < s.text.utf16.count && s.text.utf16.reversed().starts(with: b.reversed())
    }

    /// Insert: the result at the caret, spaced as dictation's (`Dictation.spaced`); never a
    /// delete, so never over a selection, which `insertText` would type over (false).
    static func insert(_ result: String, in doc: UITextDocumentProxy) -> Bool {
        guard (doc.selectedText ?? "").isEmpty else { return false }
        doc.insertText(Dictation.spaced(result, after: doc.documentContextBeforeInput ?? ""))
        return true
    }

    /// The model's text in the source's place: trimmed, inside the source's own leading and
    /// trailing blanks, so a selection's space or a paragraph's break after it stays.
    static func fitted(_ result: String, to source: String) -> String {
        let lead = source.prefix { $0.isWhitespace }, trail = String(source.reversed().prefix { $0.isWhitespace }.reversed())
        return String(lead) + result.trimmingCharacters(in: .whitespacesAndNewlines) + trail
    }

    /// Unit for unit: Swift's `==` takes canonically equal text ("é" and "e" + U+0301) as one.
    private static func same(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
}

/// Fix, Rewrite and Summarize in the keys' place (#612), as the snippets' panel: the menu's
/// Rewrite tile or the toolbar's key opens it, the keyboard button closes it. Three rows; a tap
/// runs the model on the text (`Rewrite.plan`, read at the tap) under a spinner, ✕ cancels;
/// then the result, scrolling if long, with Replace (where `plan` proved the text), Insert and
/// Back to the rows. With the model unavailable, one line says why instead of the rows. Closing
/// it, or the keyboard going, cancels the request: a late answer writes nothing.
final class AIPanel: KeysPanel, UITableViewDataSource, UITableViewDelegate {
    let availability: Rewrite.Availability
    let rewrite: (Rewrite.Command, String) async throws -> String
    /// The field's text as a command would take it now, the bar's `Rewrite.plan`.
    var source: () -> Rewrite.Source? = { nil }
    /// Replace (true) or Insert tapped: the bar writes it (`SuggestionBar.write`).
    var onWrite: ((Rewrite.Source, String, _ replace: Bool) -> Void)?
    /// The request under way.
    private(set) var task: Task<Void, Never>?
    /// The result shown, and the source it's for.
    private(set) var result: (source: Rewrite.Source, text: String)?

    let cancelButton = UIButton(configuration: .plain())
    let spinner = UIActivityIndicatorView(style: .medium)
    let preview = UITextView()
    let note = UILabel()
    let replaceButton = UIButton(configuration: .filled())
    let insertButton = UIButton(configuration: .plain())
    let listButton = UIButton(configuration: .plain())
    let resultView: UIStackView
    /// Over the rows: why the last tap gave no result.
    private(set) var line: String?
    /// `line`'s, the table's header while there is one (`showList`).
    let lineLabel = UILabel()
    private let lineView = UIView()

    init(availability: Rewrite.Availability, rewrite: @escaping (Rewrite.Command, String) async throws -> String) {
        self.availability = availability
        self.rewrite = rewrite
        let buttons = UIStackView(arrangedSubviews: [listButton, UIView(), insertButton, replaceButton])
        buttons.spacing = 8
        resultView = UIStackView(arrangedSubviews: [preview, note, buttons])
        resultView.axis = .vertical
        resultView.spacing = 6
        super.init(title: "Rewrite", empty: availability.reason ?? "", trailing: [cancelButton])
        table.dataSource = self
        table.delegate = self
        cancelButton.configuration?.image = UIImage(systemName: "xmark")
        cancelButton.configuration?.baseForegroundColor = Style.icon
        cancelButton.accessibilityLabel = "Cancel"
        cancelButton.addAction(UIAction { [weak self] _ in self?.cancel() }, for: .touchUpInside)
        spinner.color = Style.hint
        preview.isEditable = false
        preview.backgroundColor = Style.surface
        preview.textColor = Style.label
        preview.font = .systemFont(ofSize: 15)
        preview.layer.cornerRadius = 14
        preview.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        lineLabel.font = .systemFont(ofSize: 13)
        lineLabel.textColor = Style.hint
        lineLabel.numberOfLines = 0
        lineLabel.translatesAutoresizingMaskIntoConstraints = false
        lineView.addSubview(lineLabel)
        lineView.preservesSuperviewLayoutMargins = true   // the rows' insets
        lineView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 4, trailing: 0)
        NSLayoutConstraint.activate([
            lineLabel.topAnchor.constraint(equalTo: lineView.layoutMarginsGuide.topAnchor),
            lineLabel.bottomAnchor.constraint(equalTo: lineView.layoutMarginsGuide.bottomAnchor),
            lineLabel.leadingAnchor.constraint(equalTo: lineView.layoutMarginsGuide.leadingAnchor),
            lineLabel.trailingAnchor.constraint(equalTo: lineView.layoutMarginsGuide.trailingAnchor),
        ])
        note.font = .systemFont(ofSize: 13)
        note.textColor = Style.hint
        note.numberOfLines = 2
        replaceButton.configuration?.title = "Replace"
        replaceButton.configuration?.baseBackgroundColor = Style.accent
        replaceButton.configuration?.baseForegroundColor = Style.onAccent
        insertButton.configuration?.title = "Insert"
        insertButton.configuration?.baseForegroundColor = Style.accent
        listButton.configuration?.title = "Back"
        listButton.configuration?.baseForegroundColor = Style.accent
        replaceButton.addAction(UIAction { [weak self] _ in self?.write(replace: true) }, for: .touchUpInside)
        insertButton.addAction(UIAction { [weak self] _ in self?.write(replace: false) }, for: .touchUpInside)
        listButton.addAction(UIAction { [weak self] _ in self?.showList() }, for: .touchUpInside)
        for v in [spinner, resultView] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: empty.centerYAnchor),
            resultView.topAnchor.constraint(equalTo: table.topAnchor),   // under the header
            resultView.leadingAnchor.constraint(equalTo: table.leadingAnchor),
            resultView.trailingAnchor.constraint(equalTo: table.trailingAnchor),
            resultView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        showList()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The rows, `line` over them, or the reason the model can't run in their place. The line
    /// is the table's header (#660), scrolled to the top with Fix under it: it scrolls with the
    /// rows, where a plain table's section footer floated, pinned to the card's bottom over
    /// them whenever they and it outgrew the card (QA H).
    func showList(_ line: String? = nil) {
        result = nil
        self.line = line
        empty.isHidden = availability.reason == nil
        table.isHidden = availability.reason != nil
        lineLabel.text = line
        table.tableHeaderView = line == nil ? nil : lineView
        table.reloadData()
        setNeedsLayout()
        layoutIfNeeded()
        table.contentOffset = CGPoint(x: 0, y: -table.adjustedContentInset.top)
        if let line, !table.isHidden { UIAccessibility.post(notification: .announcement, argument: line) }
        cancelButton.isHidden = true
        spinner.stopAnimating()
        resultView.isHidden = true
    }

    /// A row's tap: the model on the text the field shows now, under the spinner.
    func run(_ command: Rewrite.Command) {
        guard availability == .available, task == nil else { return }
        guard let source = source() else { return showList("Select text, or type a paragraph, first") }
        table.isHidden = true
        empty.isHidden = true
        cancelButton.isHidden = false
        spinner.startAnimating()
        let rewrite = self.rewrite
        task = Task { [weak self] in
            let out: String
            do { out = try await rewrite(command, source.text) } catch {
                guard !Task.isCancelled, let self else { return }
                self.task = nil
                return self.showList((error as? Rewrite.Failure)?.line ?? Rewrite.failed)
            }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            guard out.contains(where: { !$0.isWhitespace }) else { return self.showList(Rewrite.failed) }
            self.show(out, for: source)
        }
    }

    /// ✕: the request is dropped, the rows back.
    func cancel() {
        task?.cancel()
        task = nil
        showList()
    }

    private func show(_ text: String, for source: Rewrite.Source) {
        result = (source, text)
        cancelButton.isHidden = true
        spinner.stopAnimating()
        preview.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        preview.setContentOffset(.zero, animated: false)
        replaceButton.isHidden = source.note != nil
        note.text = source.note
        note.isHidden = source.note == nil
        resultView.isHidden = false
    }

    /// The bar refused the write (`SuggestionBar.write`): why, under the result.
    func refused(_ why: String) {
        note.text = why
        note.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: why)
    }

    private func write(replace: Bool) {
        guard let result else { return }
        onWrite?(result.source, result.text, replace)
    }

    /// The line's header fitted to the table's width, as it changes: a table header is sized by
    /// its frame alone, and set again for the table to take a new height.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard table.tableHeaderView === lineView else { return }
        let fit = lineView.systemLayoutSizeFitting(CGSize(width: table.bounds.width, height: 0),
                                                   withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let size = CGSize(width: table.bounds.width, height: ceil(fit.height))
        guard lineView.frame.size != size else { return }
        lineView.frame.size = size
        table.tableHeaderView = lineView
    }

    /// Off the keyboard (closed, or the keyboard went): the request goes with it.
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil { task?.cancel(); task = nil }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Rewrite.Command.allCases.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        Self.card(cell, &content)
        let command = Rewrite.Command.allCases[indexPath.row]
        content.image = UIImage(systemName: command.symbol)
        content.imageProperties.tintColor = Style.accent
        content.text = command.title
        content.textProperties.font = .systemFont(ofSize: 15, weight: .medium)
        content.secondaryText = line == nil ? command.detail : nil   // the line's room (#660 QA u)
        content.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.accessibilityLabel = command.title
        cell.accessibilityHint = command.detail
        cell.accessibilityTraits.insert(.button)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        run(Rewrite.Command.allCases[indexPath.row])
    }
}
