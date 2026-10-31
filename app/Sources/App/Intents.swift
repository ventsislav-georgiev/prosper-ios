import AppIntents
import Foundation

/// A dch session on a saved Mac, for the Shortcuts app (#611). The id carries both, so a
/// saved shortcut opens its session with the Mac asleep: the app shows the Wake card then.
struct SessionEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Session"
    static var defaultQuery = SessionQuery()

    var machine: UUID
    var name: String
    var title: String
    var mac: String

    /// "<machine>/<name>": a UUID holds no slash, a dch name may.
    var id: String { "\(machine.uuidString)/\(name)" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(mac)")
    }
}

struct SessionQuery: EntityQuery {
    /// Settable for tests: the live list, as the app's session list dials it.
    static var list: (Machine) async throws -> [DchSession] = { try await connectFirstTransport($0.addresses).sessions }

    /// From the ids alone, no dialing: a shortcut runs with the Mac asleep too.
    func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        let machines = ShareInbox.machines()
        return identifiers.compactMap { id in
            guard let slash = id.firstIndex(of: "/"), let m = UUID(uuidString: String(id[..<slash])) else { return nil }
            let name = String(id[id.index(after: slash)...])
            return SessionEntity(machine: m, name: name, title: name, mac: machines.first { $0.id == m }?.name ?? "")
        }
    }

    /// The live sessions of every saved Mac, in the session list's order; a Mac that
    /// doesn't answer lists none.
    func suggestedEntities() async throws -> [SessionEntity] {
        let machines = ShareInbox.machines()
        let lists = await withTaskGroup(of: (Int, [DchSession]).self) { g in
            for (i, m) in machines.enumerated() { g.addTask { (i, (try? await Self.list(m)) ?? []) } }
            return await g.reduce(into: [Int: [DchSession]]()) { $0[$1.0] = $1.1 }
        }
        return machines.indices.flatMap { i in
            DchSession.ordered(lists[i] ?? []).map {
                SessionEntity(machine: machines[i].id, name: $0.name, title: $0.title, mac: machines[i].name)
            }
        }
    }
}

/// A session's terminal.
struct OpenSessionIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Session"
    static var description = IntentDescription("Opens a session's terminal in Prosper.")

    @Parameter(title: "Session") var target: SessionEntity

    @MainActor func perform() async throws -> some IntentResult {
        IntentLink.open(SessionsSnapshot.link(machine: target.machine, session: target.name))
        return .result()
    }
}

/// Text pasted at a session's prompt, never run: Share › Prosper's path (#610), the item
/// handed over through the App Group as the share sheet hands it.
struct SendTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Text to Session"
    static var description = IntentDescription("Opens a session in Prosper and pastes the text at its prompt, without pressing Return.")
    static var openAppWhenRun = true

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true)) var text: String
    @Parameter(title: "Session") var session: SessionEntity

    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$text) to \(\.$session)") }

    @MainActor func perform() async throws -> some IntentResult {
        let item = ShareItem(target: ShareTarget(machine: session.machine, session: session.name), text: text)
        if let url = ShareInbox.post(item) { IntentLink.open(url) }
        return .result()
    }
}

/// The Shortcuts app's ready-made actions. No Clipboard History: the app has no screen of
/// its own for it, only the terminal bar's panel.
struct ProsperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSessionIntent(), phrases: ["Open a session in \(.applicationName)"],
                    shortTitle: "Open Session", systemImageName: "terminal")
        AppShortcut(intent: SendTextIntent(), phrases: ["Send text to a session in \(.applicationName)"],
                    shortTitle: "Send Text", systemImageName: "text.cursor")
        AppShortcut(intent: DictateIntent(), phrases: ["Dictate with \(.applicationName)"],
                    shortTitle: "Dictate", systemImageName: "mic")
        AppShortcut(intent: OpenLastSessionIntent(), phrases: ["Open my last session in \(.applicationName)"],
                    shortTitle: "Last Session", systemImageName: "clock.arrow.circlepath")
    }
}

extension SessionsSnapshot {
    /// What the widget shows of `sessions`, as listed just now.
    init(machine: Machine, sessions: [DchSession]) {
        self.init(machine: machine.id, mac: machine.name,
                  rows: sessions.map { Row(name: $0.name, title: $0.title, state: SessionStateStyle($0.state)) })
    }
}
