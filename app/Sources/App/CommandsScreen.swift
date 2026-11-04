import SwiftUI
import UIKit

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
