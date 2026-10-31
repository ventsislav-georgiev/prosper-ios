import UIKit

/// Speech-to-text from the system keyboards' toolbar (#598). A keyboard has no microphone,
/// so its mic key hops to Prosper (`prosper://dictate?id=`), which starts the mic in the
/// foreground and keeps it ready in the background (`DictationService`). Back in the host,
/// the keyboard drives it over the App Group: its `Request` file and Darwin pings one way,
/// the app's `State` file (a heartbeat, the finished phrases, the unfinished tail) and a
/// `changed` ping the other. English only, on both keyboards: Apple has no Bulgarian engine.
enum Dictation {
    enum Ping: String, CaseIterable {
        case start, stop, cancel, changed
        var name: String { "eu.illegible.prosperios.dictation." + rawValue }
    }

    /// The app writes its state every second while the mic is ready; older than this, it's gone.
    static let stale: TimeInterval = 3
    /// A warm start the app hasn't taken up by then: it's gone after all, so the key hops.
    static let ackLimit: TimeInterval = 1.5
    /// Done's last phrase not back by then: the tail as last shown goes in instead.
    static let finishLimit: TimeInterval = 2
    /// Phrases of a dictation that ended this recently still go in when the keyboard is back.
    static let leftover: TimeInterval = 60
    /// A dictation with no new words for this long ends as Done (`DictationService`).
    static let quiet: TimeInterval = 30

    /// The keyboard's: the dictation it asked for, and how many of its phrases it has typed,
    /// so a reloaded keyboard types each exactly once.
    struct Request: Codable, Equatable {
        var id = UUID()
        var date: Date
        var applied = 0
    }

    /// The app's, for the request `id`. `phrases` only grow while it runs.
    struct State: Codable, Equatable {
        enum Phase: String, Codable {
            /// Permissions, the model, the mic: on its way to `listening`.
            case preparing, listening, finishing
            /// `id` is over; the mic stays ready for the next.
            case ready
            /// The mic is off: the ready period ran out, Stop, a call or Siri (`note`).
            case off
        }
        var id: UUID?
        var phase: Phase
        var heartbeat: Date
        var phrases: [String] = []
        var tail = ""
        var note: String?

        /// The app is running with the mic on: a start needs no hop.
        func warm(at now: Date) -> Bool {
            phase != .off && abs(now.timeIntervalSince(heartbeat)) < Dictation.stale
        }
    }

    /// The two files in a directory of the App Group's container.
    struct Store {
        let dir: URL

        static func shared() -> Store? {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardSettings.suiteName)
                .map { Store(dir: $0.appendingPathComponent("Dictation", isDirectory: true)) }
        }

        var request: Request? {
            get { read("request.json") }
            nonmutating set { write(newValue, "request.json") }
        }
        var state: State? {
            get { read("state.json") }
            nonmutating set { write(newValue, "state.json") }
        }

        private func read<T: Decodable>(_ name: String) -> T? {
            (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }

        private func write<T: Encodable>(_ value: T?, _ name: String) {
            let url = dir.appendingPathComponent(name)
            guard let value else { try? FileManager.default.removeItem(at: url); return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
    }

    static func url(_ id: UUID) -> URL { URL(string: "prosper://dictate?id=\(id.uuidString)")! }

    /// The request a `prosper://dictate` link carries.
    static func id(from url: URL) -> UUID? {
        guard url.scheme == "prosper", url.host == "dictate" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "id" }?.value.flatMap(UUID.init(uuidString:))
    }

    /// A phrase as it goes in after `before`: a space between words, none at a line's or a
    /// bracket's start, nor before punctuation.
    static func spaced(_ phrase: String, after before: String) -> String {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = before.last, let first = p.first, !last.isWhitespace,
              !"([{\"'“‘/".contains(last), !",.;:!?)]}”’".contains(first) else { return p }
        return " " + p
    }

    /// The user's English, the first English in their languages, else US English.
    static func english(_ preferred: [String]) -> String {
        preferred.first { $0 == "en" || $0.hasPrefix("en-") } ?? "en-US"
    }
}

/// Darwin notifications: system-wide, no payload, delivered on the main run loop. Observing
/// lasts as long as the object.
final class DarwinPings {
    private let handle: (Dictation.Ping) -> Void
    private static var center: CFNotificationCenter { CFNotificationCenterGetDarwinNotifyCenter() }

    init(_ pings: [Dictation.Ping], handle: @escaping (Dictation.Ping) -> Void) {
        self.handle = handle
        for ping in pings {
            CFNotificationCenterAddObserver(Self.center, Unmanaged.passUnretained(self).toOpaque(), { _, observer, name, _, _ in
                guard let observer, let name,
                      let ping = Dictation.Ping.allCases.first(where: { $0.name == name.rawValue as String }) else { return }
                let me = Unmanaged<DarwinPings>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.handle(ping) }
            }, ping.name as CFString, nil, .deliverImmediately)
        }
    }

    deinit { CFNotificationCenterRemoveEveryObserver(Self.center, Unmanaged.passUnretained(self).toOpaque()) }

    static func post(_ ping: Dictation.Ping) {
        CFNotificationCenterPostNotification(center, CFNotificationName(ping.name as CFString), nil, nil, true)
    }
}

/// The keyboard's side of dictation (#598): the mic key, the listening strip, and each finished
/// phrase typed once. The app's heartbeat says whether a start can go straight to it or has to
/// hop. Done waits for the last phrase (`finishLimit`, then the tail as shown goes in); ✕ types
/// the finished phrases and drops the tail. Leaving mid-dictation (another app, the keyboard
/// down) is ✕, but not the hop to Prosper: back from it, the dictation goes on.
final class DictationClient {
    enum Strip: Equatable {
        case idle, opening, starting
        case listening(String)
        case finishing(String)
    }

    let store: Dictation.Store
    var now: () -> Date = Date.init
    var ping: (Dictation.Ping) -> Void = DarwinPings.post
    /// Opens Prosper (the controller's responder-chain open), then whether iOS did.
    var open: (URL, @escaping (Bool) -> Void) -> Void = { $1(false) }
    var insert: (String) -> Void = { _ in }
    var onStrip: (Strip) -> Void = { _ in }
    var hint: (String) -> Void = { _ in }
    /// Polls while a dictation runs (a lost ping, the timeouts); off in tests.
    var polls = true

    private(set) var strip = Strip.idle {
        didSet { if strip != oldValue { onStrip(strip) }; poll() }
    }
    private(set) var request: Dictation.Request?
    /// When the strip's current wait began (`ackLimit`, `finishLimit`).
    private var since = Date.distantPast
    /// The key opened Prosper: the keyboard going away now isn't the user leaving.
    private(set) var hopping = false
    private var pings: DarwinPings?
    private var timer: Timer?

    init(store: Dictation.Store) { self.store = store }

    /// The mic key: start, or Done while one runs.
    func tap() {
        switch strip {
        case .idle: start()
        case .starting, .listening: done()
        case .opening, .finishing: break
        }
    }

    func done() {
        guard request != nil else { return end() }
        ping(.stop)
        since = now()
        if case .listening(let tail) = strip { strip = .finishing(tail) } else { strip = .finishing("") }
        sync()
    }

    /// ✕: the finished phrases go in, the tail doesn't.
    func cancel() {
        guard request != nil else { return end() }
        if let s = mine() { apply(s) }
        ping(.cancel)
        end()
    }

    func appear() {
        hopping = false
        if pings == nil { pings = DarwinPings([.changed]) { [weak self] _ in self?.sync() } }
        guard let saved = store.request else { return end() }
        guard store.state?.id == saved.id else {   // never taken up: the hop failed
            store.request = nil
            return end()
        }
        request = saved
        strip = .starting
        sync()
    }

    func disappear() {
        pings = nil
        if !hopping, request != nil { cancel() }
        timer?.invalidate()
        timer = nil
    }

    /// The app's state for this request, read afresh: phrases typed, the strip follows.
    func sync() {
        guard request != nil else { return }
        let s = mine(), t = now()
        if let s { apply(s) }
        let live = s.map { $0.warm(at: t) && $0.phase != .ready } ?? false
        if let s, !live {   // over: Done's end, the mic off, or the app gone
            if s.phase != .ready {
                if case .finishing(let shown) = strip, !shown.isEmpty { insert(shown) }   // Done's, never finalized
                hint(s.note ?? "The mic stopped — tap it to start again")
            }
            return end()
        }
        switch strip {
        case .idle, .opening: break
        case .starting:
            if let s { strip = s.phase == .preparing ? .starting : .listening(s.tail) }
            else if t.timeIntervalSince(since) > Dictation.ackLimit { hop() }
        case .listening:
            if let s { strip = .listening(s.tail) } else { end() }   // another request took the mic
        case .finishing(let shown):
            if t.timeIntervalSince(since) > Dictation.finishLimit {
                if !shown.isEmpty { insert(shown) }
                end()
            } else if let s, !s.tail.isEmpty {
                strip = .finishing(s.tail)
            }
        }
    }

    private func start() {
        let r = Dictation.Request(date: now())
        store.request = r
        request = r
        since = now()
        if store.state?.warm(at: now()) == true {
            ping(.start)
            strip = .starting
        } else {
            hop()
        }
    }

    private func hop() {
        guard let request else { return }
        hopping = true
        strip = .opening
        open(Dictation.url(request.id)) { [weak self] opened in
            guard let self, !opened else { return }
            // The request stays: Prosper opened by hand soon takes it up (`DictationService`).
            self.strip = .idle
            self.hint("Open Prosper to start the mic")
        }
    }

    private func mine() -> Dictation.State? {
        store.state.flatMap { $0.id != nil && $0.id == request?.id ? $0 : nil }
    }

    /// The phrases past `applied`, in one insert, then counted: each goes in once, a reloaded
    /// keyboard reading the count back. None once the dictation is long over (`leftover`).
    private func apply(_ s: Dictation.State) {
        guard var r = request, s.phrases.count > r.applied,
              abs(now().timeIntervalSince(s.heartbeat)) < Dictation.leftover else { return }
        insert(s.phrases[r.applied...].joined(separator: " "))
        r.applied = s.phrases.count
        request = r
        store.request = r
    }

    private func end() {
        if request != nil { store.request = nil }
        request = nil
        strip = .idle
    }

    private func poll() {
        guard polls else { return }
        if strip == .idle || pings == nil {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.sync() }
        }
    }
}

/// The strip over the suggestion bar while dictating (#598): a red dot, the words not yet
/// typed, Done and ✕.
final class DictationStrip: UIView {
    let label = UILabel()
    let doneButton = UIButton(configuration: .plain())
    let cancelButton = UIButton(configuration: .plain())
    private let dot = UIView()

    init(done: @escaping () -> Void, cancel: @escaping () -> Void) {
        super.init(frame: .zero)
        backgroundColor = TerminalKeyboard.Style.backdrop
        isHidden = true
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 5
        dot.isAccessibilityElement = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 16)
        label.lineBreakMode = .byTruncatingHead   // the latest words show
        doneButton.configuration?.title = "Done"
        doneButton.configuration?.baseForegroundColor = ShortcutBar.Neon.blueBright
        doneButton.addAction(UIAction { _ in done() }, for: .touchUpInside)
        cancelButton.configuration?.image = UIImage(systemName: "xmark")
        cancelButton.configuration?.baseForegroundColor = .white
        cancelButton.accessibilityLabel = "Cancel dictation"
        cancelButton.addAction(UIAction { _ in cancel() }, for: .touchUpInside)
        // ✕ and Done hug the edges; the dot and words sit centred between them, a long tail
        // filling the middle (#600).
        let status = UIStackView(arrangedSubviews: [dot, label])
        status.spacing = 8
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        let middle = UIView()
        middle.addSubview(status)
        let row = UIStackView(arrangedSubviews: [cancelButton, middle, doneButton])
        row.spacing = 4
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let centred = status.centerXAnchor.constraint(equalTo: centerXAnchor)
        centred.priority = .defaultLow - 1   // below the label's own width: a long tail shifts, not shrinks
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            middle.heightAnchor.constraint(equalTo: row.heightAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: middle.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: middle.trailingAnchor),
            status.centerYAnchor.constraint(equalTo: middle.centerYAnchor),
            centred,
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])
        for b in [cancelButton, doneButton] { b.setContentHuggingPriority(.required, for: .horizontal) }
        middle.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ strip: DictationClient.Strip) {
        isHidden = strip == .idle
        doneButton.isHidden = strip == .opening
        switch strip {
        case .idle: label.text = nil
        case .opening: label.text = "Opening Prosper…"
        case .starting: label.text = "Starting the mic…"
        case .listening(let tail): label.text = tail.isEmpty ? "Listening…" : tail
        case .finishing(let tail): label.text = tail + "…"
        }
        dot.isHidden = strip == .idle || strip == .opening
        if case .listening = strip {
            if dot.layer.animation(forKey: "pulse") == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.3
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.isRemovedOnCompletion = false   // survives the keyboard going to the background
                dot.layer.add(pulse, forKey: "pulse")
            }
        } else {
            dot.layer.removeAnimation(forKey: "pulse")
        }
        UIAccessibility.post(notification: .layoutChanged, argument: label)
    }
}
