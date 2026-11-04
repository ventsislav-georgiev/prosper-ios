import Combine
import UIKit

/// #615: the Mac's palette commands, run from the phone. The list and each run go over a
/// connection of their own; a run waits for its reply before the next one can start.
/// #735: here, not in the app's Sources/App, as the keyboards run them too (`CommandPanel`).
@MainActor
final class CommandsSession: ObservableObject {
    /// One run's reply under its command: the result, or the error in plain words.
    struct Outcome: Equatable {
        var id: String
        var result: CommandResult?
        var error: String?
    }

    /// The Mac's cap on an argument, in UTF-8 bytes ("argument too long" past it).
    static let limit = 1024
    /// These act on the Mac at once and the Mac never asks, so the phone does.
    /// Extension commands ("<extensionID>/<commandID>") always ask too (#727).
    static let confirmed: Set<String> = ["toggles.lock", "toggles.displayoff", "openlid.toggle",
                                         "fans.auto", "fans.manual"]
    static func asks(_ id: String) -> Bool { confirmed.contains(id) || id.contains("/") }
    /// #740: a reply worth typing (the panel's Insert): an extension's, or one taking text that
    /// doesn't act on the Mac (calc, units, currency). The Mac's other built-ins only say what they
    /// did ("Screen locked", "Manual · 1800 rpm"), and its reply carries no kind to tell them by.
    static func inserts(_ c: MacCommand) -> Bool { c.id.contains("/") || c.argument != nil && !confirmed.contains(c.id) }

    @Published private(set) var commands: [MacCommand]?   // nil until the first list lands
    @Published private(set) var listError: String?
    @Published private(set) var loading = false
    @Published private(set) var running: String?           // the id whose reply is awaited
    @Published private(set) var outcome: Outcome?
    @Published var drafts: [String: String] = [:]           // by id, for the ones taking text
    @Published var confirming: MacCommand?
    private var transport: SessionTransport?
    /// #735: the keyboard's way to the Mac (`reach`), walked at the panel's fetch or its first run:
    /// the transport that answered and the list it answered with.
    private let reacher: (() async throws -> (SessionTransport, [MacCommand]))?
    /// #735: where a list fetched goes for the keyboards (`CommandStore`), and from which Mac.
    let cache: (store: CommandStore, machine: Machine)?
    /// #735: the keyboard's wait for a run's reply, then "The Mac didn't answer."; the app's waits on.
    var deadline: Duration = .seconds(30)
    /// The run whose reply still counts: one past the deadline is dropped.
    private var runs = 0

    init(transport: SessionTransport, cache: (store: CommandStore, machine: Machine)? = nil) {
        self.transport = transport
        reacher = nil
        self.cache = cache
    }

    /// #735: the keyboard's, on the cached list: the Mac reached by `reach` at the first run. Each
    /// run that lands goes first in the Recent and fetches the list again (`settle`).
    init(cached: CommandStore.Cache, store: CommandStore,
         reach: @escaping () async throws -> (SessionTransport, [MacCommand])) {
        reacher = reach
        cache = (store, cached.machine)
        commands = cached.commands
    }

    /// The transport, and the list when reaching it fetched one (#735).
    private func link() async throws -> (SessionTransport, [MacCommand]?) {
        if let transport { return (transport, nil) }
        guard let reacher else { throw TransportError.notConnected }
        let (t, list) = try await reacher()
        transport = t
        return (t, list)
    }

    /// #735: the keyboard panel's as it opens: the cached list stays while it's fetched again.
    func refresh() {
        loading = true
        Task { await load() }
    }

    /// A failed read keeps the last list, the error over it.
    func load() async {
        loading = true
        defer { loading = false }
        do {
            let (t, fetched) = try await link()
            let list: [MacCommand]
            if let fetched { list = fetched } else { list = try await t.commands() }
            commands = list
            listError = nil
            if let cache { cache.store.save(.init(machine: cache.machine, commands: list)) }   // #735
        } catch {
            listError = Self.copy(error.localizedDescription)
        }
    }

    /// The draft as it would go: trimmed, nil when empty.
    func argument(_ c: MacCommand) -> String? {
        let text = (drafts[c.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Over `limit`: said inline, nothing sent.
    func tooLong(_ c: MacCommand) -> Bool { (argument(c)?.utf8.count ?? 0) > Self.limit }

    /// False when nothing went: a reply is awaited, the text is missing or too long, or it
    /// asks first (`confirming`) and isn't `confirmed` yet.
    @discardableResult func run(_ c: MacCommand, confirmed: Bool = false) -> Bool {
        guard running == nil else { return false }
        let argument = c.argument == nil ? nil : argument(c)
        if c.argument != nil, argument == nil || tooLong(c) { return false }
        if Self.asks(c.id), !confirmed { confirming = c; return false }
        confirming = nil
        running = c.id
        outcome = nil
        runs += 1
        let run = runs
        let work = Task { [weak self] in
            do {
                guard let t = try await self?.link().0 else { return }
                let r = try await t.runCommand(id: c.id, argument: argument)
                self?.settle(Outcome(id: c.id, result: Self.worded(c.id, r)), run: run)
            } catch {
                let m = error.localizedDescription
                guard self?.settle(Outcome(id: c.id, error: Self.copy(m)), run: run) == true else { return }
                if m == "not allowed" { await self?.load() }
            }
        }
        // #735: the keyboard's is gone with its panel; a reply that never comes mustn't hold the rows.
        if reacher != nil {
            Task { [weak self, deadline] in
                try? await Task.sleep(for: deadline)
                guard self?.settle(Outcome(id: c.id, error: "The Mac didn't answer."), run: run) == true else { return }
                work.cancel()
            }
        }
        return true
    }

    /// False for a reply no longer awaited: past the deadline, or after the next run started.
    @discardableResult private func settle(_ o: Outcome, run: Int) -> Bool {
        guard run == runs, running != nil else { return false }
        outcome = o
        running = nil
        // #735: the keyboard's: Recent, and the list again while the Mac answers.
        if reacher != nil, o.result != nil, let cache {
            cache.store.ran(o.id)
            Task { await load() }
        }
        return true
    }

    /// The Mac answers openlid.toggle before its lid helper does: requested, not done.
    static func worded(_ id: String, _ r: CommandResult) -> CommandResult {
        guard id == "openlid.toggle" else { return r }
        return CommandResult(text: "Requested: \(r.text)", detail: r.detail ?? "If the Mac asks to approve it, answer there.")
    }

    /// The Mac's refusals a person meets, in plain words; every other error as written.
    static func copy(_ message: String) -> String {
        switch message {
        case "no result": "No result for that input."
        case "not allowed": "That command isn't available on the Mac now. The list is refreshed."
        case "commands are off":
            "Commands are off on the Mac. Turn on Settings › Remote Terminal › Run commands from iPhone in Prosper on the Mac."
        default: message
        }
    }

    /// The commands by `ext`, each group where its first command is, the Mac's order kept within.
    static func groups(_ commands: [MacCommand]) -> [(ext: String, commands: [MacCommand])] {
        var out: [(ext: String, commands: [MacCommand])] = []
        for c in commands {
            if let i = out.firstIndex(where: { $0.ext == c.ext }) { out[i].commands.append(c) }
            else { out.append((c.ext, [c])) }
        }
        return out
    }

    /// The Mac's SF Symbol, or a generic one when it is missing or this iOS doesn't have it.
    static func symbol(_ icon: String?) -> String {
        if let icon, UIImage(systemName: icon) != nil { return icon }
        return "command"
    }
}

extension CommandsSession {
    /// #735: the keyboard's way to the cached Mac: its addresses in order, each 5 s to answer the
    /// list (0x28, the probe, as `connectFirstTransport`'s is the session list, which the keyboard
    /// never asks for). None answering is "Mac not reachable"; a refusal ("commands are off") as said.
    nonisolated static func reach(_ addresses: [String]) -> () async throws -> (SessionTransport, [MacCommand]) {
        {
            do {
                return try await connectFirst(addresses) { addr -> (SessionTransport, [MacCommand]) in
                    let t = ProsperTransport(host: addr)
                    return (t, try await t.commands())
                }.0
            } catch TransportError.hostUnreachable(_) {
                throw TransportError.server("Mac not reachable")
            }
        }
    }
}

/// The Mac's commands for the keyboards (#735): the list the app last fetched (`CommandsSession.load`),
/// with the Mac it came from, and the last four run from a keyboard, newest first. Two small JSON
/// files in the App Group's container (`Commands/`), read afresh as the menu and the panel open.
/// ponytail: one Mac, the one fetched last, as `MacLibrary`; per-Mac files if anyone runs two.
final class CommandStore {
    struct Cache: Codable, Equatable {
        var machine: Machine
        var commands: [MacCommand]
    }
    static let recentsKept = 4
    let dir: URL

    init(dir: URL) { self.dir = dir }

    /// The App Group's store, nil where the container isn't there.
    static func shared() -> CommandStore? { MacLibrary.sharedRoot().map { CommandStore(dir: $0.appendingPathComponent("Commands")) } }

    private var cacheURL: URL { dir.appendingPathComponent("commands.json") }
    private var recentURL: URL { dir.appendingPathComponent("recent.json") }

    func load() -> Cache? { try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL)) }

    func save(_ cache: Cache) { write(cache, to: cacheURL) }

    /// The app on a Mac (`SessionListView.handshake`): its list kept for the same Mac, none for another,
    /// so the menu's tile shows from the first connect and the panel fetches the list.
    func connected(_ machine: Machine) {
        let old = load()
        guard old?.machine != machine else { return }
        save(.init(machine: machine, commands: old?.machine.id == machine.id ? old?.commands ?? [] : []))
    }

    var recent: [String] { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: recentURL))) ?? [] }

    /// `id` run: first of the recents, which keep `recentsKept`.
    func ran(_ id: String) { write(Array(([id] + recent.filter { $0 != id }).prefix(Self.recentsKept)), to: recentURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

/// The Mac's commands in the keys' place (#735), as the snippets' panel: the menu's Commands tile
/// opens it, Insert or the keyboard button closes it. Recent on top, then each extension's under its
/// title, in the Mac's order. A tap runs one (`CommandsSession`), one that acts on the Mac at once
/// (`asks`) after Run in a row under it; one taking text takes the selection, else the search row
/// turns into its field (`KeysPanel.filter(asking:)`). The reply in a row under it, big, with Insert
/// for its text; an error in red. One run at a time: a spinner on its row, the others off.
final class CommandPanel: KeysPanel, UITableViewDataSource, UITableViewDelegate {
    enum Row: Equatable {
        case command(MacCommand)
        case confirm(MacCommand)
        case outcome(CommandsSession.Outcome)
    }
    static let recentTitle = "Recent"
    let session: CommandsSession
    /// The recents' ids as the panel opened: rows don't move under a finger after a run.
    let recent: [String]
    /// The host's selection: a text command's argument when there is one.
    var selected: () -> String? = { nil }
    /// Insert's: the reply's text into the host, the keys back (`SuggestionBar.showCommands`).
    var onInsert: ((String) -> Void)?
    private(set) var sections: [(title: String, rows: [Row])] = []
    /// The Recent's section, nil with none run that the Mac still lists.
    private(set) var recentSection: Int?
    /// The row last tapped, by its section's title: where its Run and its reply go.
    private(set) var focus: (section: String, id: String)?
    /// A run refused before the Mac: its text over the Mac's cap.
    private(set) var refusal: CommandsSession.Outcome?
    private var watch: AnyCancellable?
    /// The row under the tapped command as last drawn: a new one is scrolled to (#741).
    private var under: Row?
    /// Over the note while an empty list is fetched (`CommandsSession.refresh`).
    let spinner = UIActivityIndicatorView(style: .medium)

    init(session: CommandsSession, recent: [String]) {
        self.session = session
        self.recent = recent
        super.init(title: "Commands", empty: "", search: "Search commands")
        table.dataSource = self
        table.delegate = self
        spinner.color = Style.hint
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: empty.topAnchor, constant: -8),
        ])
        // A run's reply and the list fetched again land later: drawn on the next turn, after the change.
        watch = session.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        let commands = session.commands ?? []
        let recents = recent.compactMap { id in commands.first { $0.id == id } }
        let lists = (recents.isEmpty ? [] : [(Self.recentTitle, recents)]) + CommandsSession.groups(commands).map { ($0.ext, $0.commands) }
        sections = lists.map { title, list in (title, list.flatMap { rows($0, in: title) }) }
        // A reply whose command left the list ("not allowed") on top, untitled, as the app's screen has it.
        if let o = refusal ?? session.outcome, o.id == focus?.id, !commands.contains(where: { $0.id == o.id }) {
            sections.insert(("", [.outcome(o)]), at: 0)
        }
        // The fetch as the panel opened failed: said on top of the list it keeps, or in the note.
        if let e = session.listError, !commands.isEmpty { sections.insert(("", [.outcome(.init(id: "", error: e))]), at: 0) }
        recentSection = recents.isEmpty ? nil : sections.firstIndex { $0.title == Self.recentTitle }
        let mac = session.cache?.machine.name ?? "the Mac"
        let fetching = commands.isEmpty && session.loading
        empty.text = fetching ? "Fetching commands from \(mac)…" : session.listError ?? "No commands on \(mac)."
        empty.textColor = session.listError != nil && !fetching ? .systemRed : Style.hint
        empty.isHidden = !commands.isEmpty
        if fetching { spinner.startAnimating() } else { spinner.stopAnimating() }
        showSearch()
        table.reloadData()
        // #741: a Run or a reply new under the tapped command, the reply a turn after its run, clear of
        // the card's bottom and the keys' pad (`contentInset`, `SuggestionBar.showCommands`); else the list stays.
        let s = sections.firstIndex { $0.title == focus?.section }
        let row = s.flatMap { s in sections[s].rows.firstIndex { if case .command = $0 { false } else { true } }.map { IndexPath(row: $0, section: s) } }
        let new = row.map { sections[$0.section].rows[$0.row] }
        if let row, new != under {
            for _ in 0..<2 {   // the second on the row's own height, the first scrolled on its estimate
                layoutIfNeeded()
                table.scrollToRow(at: row, at: .none, animated: false)
            }
        }
        under = new
    }

    /// `c`'s row, and under it where it was tapped its Run or its reply.
    private func rows(_ c: MacCommand, in section: String) -> [Row] {
        guard focus?.section == section, focus?.id == c.id else { return [.command(c)] }
        if session.confirming?.id == c.id { return [.command(c), .confirm(c)] }
        if let o = refusal ?? session.outcome, o.id == c.id { return [.command(c), .outcome(o)] }
        return [.command(c)]
    }

    /// The groups' commands on their title, subtitle and extension; the Recent's are among them.
    override var searchable: [(row: IndexPath, fields: [String])] {
        sections.enumerated().flatMap { s, section -> [(row: IndexPath, fields: [String])] in
            guard s != recentSection else { return [] }
            return section.rows.enumerated().compactMap { r, row in
                guard case .command(let c) = row else { return nil }
                return (IndexPath(row: r, section: s), [c.title, c.subtitle ?? "", c.ext])
            }
        }
    }

    /// A command's tap: filter mode closed, then its text from the selection or the field, then the run.
    func tap(_ c: MacCommand, in section: String) {
        if filter != nil { filter(false) }
        focus = (section, c.id)
        refusal = nil
        session.confirming = nil
        if c.argument != nil {
            if let s = selected(), s.contains(where: { !$0.isWhitespace }) {
                session.drafts[c.id] = s
            } else {
                reload()
                guard let row = indexPath(c, in: section) else { return }
                return filter(true, asking: (c.argument ?? "", row, { [weak self] text in
                    guard text.contains(where: { !$0.isWhitespace }) else { return }   // the field stays
                    self?.filter(false)
                    self?.session.drafts[c.id] = text
                    self?.go(c)
                }))
            }
        }
        go(c)
    }

    /// Run, past the cap said here (`CommandsSession.limit`), else the session's: Run's row first for one that asks.
    func go(_ c: MacCommand, confirmed: Bool = false) {
        if session.tooLong(c) {
            refusal = .init(id: c.id, error: "Too long for the Mac: at most \(CommandsSession.limit) bytes.")
        } else {
            session.run(c, confirmed: confirmed)
        }
        reload()
    }

    func cancel() {
        session.confirming = nil
        reload()
    }

    private func indexPath(_ c: MacCommand, in section: String) -> IndexPath? {
        guard let s = sections.firstIndex(where: { $0.title == section }),
              let r = sections[s].rows.firstIndex(of: .command(c)) else { return nil }
        return IndexPath(row: r, section: s)
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title.isEmpty ? nil : sections[section].title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .command(let c): command(c, cell, running: session.running == c.id && focus?.section == sections[indexPath.section].title)
        case .confirm(let c): confirm(c, cell)
        case .outcome(let o): outcome(o, cell)
        }
        return cell
    }

    /// Its icon in the accent, the title over its subtitle or the text it asks for; off while another runs.
    private func command(_ c: MacCommand, _ cell: UITableViewCell, running: Bool) {
        let off = session.running != nil && !running
        var content = cell.defaultContentConfiguration()
        Self.card(cell, &content, off: off)
        content.image = UIImage(systemName: CommandsSession.symbol(c.icon))
        content.imageProperties.tintColor = off ? Style.hint : Style.accent
        content.text = c.title
        content.textProperties.font = .systemFont(ofSize: 15, weight: .medium)
        content.secondaryText = c.subtitle ?? c.argument.map { "\($0)…" }
        content.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = content
        if running {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = Style.hint
            spinner.startAnimating()
            cell.accessoryView = spinner
        }
        cell.selectionStyle = off ? .none : .default
        cell.accessibilityLabel = c.title
        cell.accessibilityValue = running ? "Running" : nil
        cell.accessibilityTraits.insert(.button)
        cell.accessibilityHint = c.argument == nil ? "Runs it on the Mac" : "Runs it on the selection, or asks for text"
        if off { cell.accessibilityTraits.insert(.notEnabled) }
    }

    /// "Run <title>?" and its Cancel and Run, for one that acts on the Mac at once.
    private func confirm(_ c: MacCommand, _ cell: UITableViewCell) {
        let label = Self.label("Run \(c.title)?", size: 15, weight: .medium, color: Style.label)
        let cancel = Self.button("Cancel", filled: false) { [weak self] in self?.cancel() }
        let run = Self.button("Run", filled: true) { [weak self] in self?.go(c, confirmed: true) }
        let row = UIStackView(arrangedSubviews: [label, cancel, run])
        row.spacing = 8
        row.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        Self.fill(cell, with: row)
    }

    /// The reply's text big and its detail small, Insert beside a text one (`inserts`, #740); or the error in red.
    private func outcome(_ o: CommandsSession.Outcome, _ cell: UITableViewCell) {
        var views: [UIView]
        if let r = o.result {
            let text = Self.label(r.text, size: 22, weight: .semibold, color: Style.label)
            let lines = UIStackView(arrangedSubviews: [text] + (r.detail.map { [Self.label($0, size: 13, weight: .regular, color: Style.hint)] } ?? []))
            lines.axis = .vertical
            lines.spacing = 2
            lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views = [lines]
            if r.text.contains(where: { !$0.isWhitespace }),
               session.commands?.first(where: { $0.id == o.id }).map(CommandsSession.inserts) == true {   // #740
                views.append(Self.button("Insert", filled: true) { [weak self] in self?.onInsert?(r.text) })
            }
            cell.accessibilityLabel = [r.text, r.detail].compactMap { $0 }.joined(separator: ", ")
        } else {
            views = [Self.label(o.error ?? "", size: 13, weight: .regular, color: .systemRed)]
            cell.accessibilityLabel = o.error
        }
        let row = UIStackView(arrangedSubviews: views)
        row.spacing = 8
        row.alignment = .center
        Self.fill(cell, with: row)
    }

    private static func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.numberOfLines = 0
        return l
    }

    private static func button(_ title: String, filled: Bool, _ tap: @escaping () -> Void) -> UIButton {
        var cfg: UIButton.Configuration = filled ? .filled() : .plain()
        cfg.title = title
        cfg.baseBackgroundColor = Style.accent
        cfg.baseForegroundColor = filled ? Style.onAccent : Style.accent
        cfg.cornerStyle = .capsule
        let b = UIButton(configuration: cfg)
        b.addAction(UIAction { _ in
            UIDevice.current.playInputClick()
            tap()
        }, for: .touchUpInside)
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    /// `row` in the cell's margins, on the card, taking no tap of its own.
    private static func fill(_ cell: UITableViewCell, with row: UIView) {
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(row)
        let m = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: m.topAnchor),
            row.bottomAnchor.constraint(equalTo: m.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: m.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: m.trailingAnchor),
        ])
    }

    /// Only a command's row, and none while one runs.
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard session.running == nil, case .command = sections[indexPath.section].rows[indexPath.row] else { return nil }
        return indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard session.running == nil, case .command(let c) = sections[indexPath.section].rows[indexPath.row] else { return }
        tap(c, in: sections[indexPath.section].title)
    }
}
