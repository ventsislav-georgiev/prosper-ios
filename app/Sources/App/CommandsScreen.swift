import SwiftUI
import UIKit

/// #615: the Mac's palette commands, run from the phone. The list and each run go over a
/// connection of their own; a run waits for its reply before the next one can start.
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
    static let confirmed: Set<String> = ["toggles.lock", "toggles.displayoff", "openlid.toggle"]

    @Published private(set) var commands: [MacCommand]?   // nil until the first list lands
    @Published private(set) var listError: String?
    @Published private(set) var loading = false
    @Published private(set) var running: String?           // the id whose reply is awaited
    @Published private(set) var outcome: Outcome?
    @Published var drafts: [String: String] = [:]           // by id, for the ones taking text
    @Published var confirming: MacCommand?
    private let transport: SessionTransport

    init(transport: SessionTransport) { self.transport = transport }

    /// A failed read keeps the last list, the error over it.
    func load() async {
        loading = true
        defer { loading = false }
        do {
            commands = try await transport.commands()
            listError = nil
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
        if Self.confirmed.contains(c.id), !confirmed { confirming = c; return false }
        confirming = nil
        running = c.id
        outcome = nil
        let t = transport
        Task { [weak self] in
            do {
                let r = try await t.runCommand(id: c.id, argument: argument)
                self?.settle(Outcome(id: c.id, result: Self.worded(c.id, r)))
            } catch {
                let m = error.localizedDescription
                self?.settle(Outcome(id: c.id, error: Self.copy(m)))
                if m == "not allowed" { await self?.load() }
            }
        }
        return true
    }

    private func settle(_ o: Outcome) {
        outcome = o
        running = nil
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

/// #615: the ⋯ menu's Commands sheet.
struct CommandsScreen: View {
    @StateObject private var session: CommandsSession
    @Environment(\.dismiss) private var dismiss

    init(session: CommandsSession) {
        _session = StateObject(wrappedValue: session)
    }

    var body: some View {
        NavigationStack {
            List {
                if let e = session.listError {
                    Section {
                        Text(e).font(.footnote).foregroundStyle(.red)
                        Button("Retry") { Task { await session.load() } }.disabled(session.loading)
                    }
                }
                // A run whose command left the list ("not allowed") still shows its reply.
                if let o = session.outcome, !(session.commands ?? []).contains(where: { $0.id == o.id }) {
                    Section { OutcomeView(outcome: o) }
                }
                if let commands = session.commands {
                    if commands.isEmpty {
                        Section {
                            Text("No commands yet — the Mac may still be starting.").foregroundStyle(.secondary)
                            Button("Refresh") { Task { await session.load() } }.disabled(session.loading)
                        }
                    }
                    ForEach(CommandsSession.groups(commands), id: \.ext) { group in
                        Section(group.ext) {
                            ForEach(group.commands) { CommandRow(command: $0, session: session) }
                        }
                    }
                } else if session.listError == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .refreshable { await session.load() }
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .alert(session.confirming.map { "\($0.title)?" } ?? "",
                   isPresented: Binding(get: { session.confirming != nil }, set: { if !$0 { session.confirming = nil } }),
                   presenting: session.confirming) { c in
                Button("Run") { session.run(c, confirmed: true) }
                Button("Cancel", role: .cancel) {}
            } message: { c in
                Text(c.id == "openlid.toggle"
                     ? "Changes whether the Mac stays awake with its lid closed, right away. The Mac may ask you to approve it."
                     : "This acts on the Mac right away.")
            }
        }
        .task { await session.load() }
    }
}

/// One command: a tap runs it, or its text field does on Return or the arrow. Its reply below.
private struct CommandRow: View {
    let command: MacCommand
    @ObservedObject var session: CommandsSession

    var body: some View {
        let busy = session.running != nil
        VStack(alignment: .leading, spacing: 8) {
            if let hint = command.argument {
                label
                HStack {
                    TextField(hint, text: Binding(get: { session.drafts[command.id] ?? "" },
                                                  set: { session.drafts[command.id] = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { session.run(command) }
                    if session.running == command.id {
                        ProgressView()
                    } else {
                        Button { session.run(command) } label: { Image(systemName: "arrow.right.circle.fill").font(.title2) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Run")
                            .disabled(busy || session.argument(command) == nil || session.tooLong(command))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                if session.tooLong(command) {
                    Text("Too long for the Mac: at most 1024 bytes. Shorten it to run.").font(.footnote).foregroundStyle(.red)
                }
            } else {
                Button { session.run(command) } label: {
                    HStack {
                        label
                        Spacer()
                        if session.running == command.id { ProgressView() }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            if let o = session.outcome, o.id == command.id { OutcomeView(outcome: o) }
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: CommandsSession.symbol(command.icon))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                if let s = command.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// A result's text big and its detail small, copied only from its button or a long-press; or
/// the error.
private struct OutcomeView: View {
    let outcome: CommandsSession.Outcome

    var body: some View {
        if let r = outcome.result {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.text).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let d = r.detail { Text(d).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { UIPasteboard.general.string = r.text } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy")
            }
            .contextMenu {
                Button { UIPasteboard.general.string = r.text } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
        } else if let e = outcome.error {
            Text(e).font(.footnote).foregroundStyle(.red)
        }
    }
}
