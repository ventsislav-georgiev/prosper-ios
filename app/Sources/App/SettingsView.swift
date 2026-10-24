import SwiftUI

/// What "Create agent session" runs, set in Settings. Blank means the default.
enum AgentCommand {
    static let key = "agentCommand"
    static let defaultCommand = "headroom wrap claude --chrome"

    /// The argv dch spawns for `setting`. dch execs it without a shell, on the GUI app's
    /// PATH, and drops the session when it exits. So: the user's `$SHELL` as a login,
    /// interactive shell (PATH and aliases from the rc files), the command `eval`ed from
    /// `$1` (passed as an argument, never quoted into the script), then `exec` a login
    /// shell so the session stays at a prompt. `trap : INT` keeps a Ctrl-C that kills
    /// the agent from aborting that `exec`; a handler, unlike an ignore, resets in the agent.
    static func argv(_ setting: String) -> [String] {
        let typed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        let shell = "\"${SHELL:-/bin/zsh}\""
        return ["/bin/sh", "-c",
                "exec \(shell) -lic 'trap : INT; eval \"$1\"; exec \"$0\" -l' \(shell) \"$1\"",
                "sh", typed.isEmpty ? defaultCommand : typed]
    }
}

/// Account settings (PLAN §3 / §6.3): sign in/out and the mandatory in-app Delete
/// Account (Apple 5.1.1(v)). Reachable from Home. Signing in is only needed for
/// Remote Wake — everything else works signed-out. Below them, the Prosper keyboard's
/// switches (`KeyboardSettings`), and the agent command (`AgentCommand`).
struct SettingsView: View {
    @ObservedObject var account: AccountStore
    @State private var showLogin = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var error: String?
    // Keyboard, in the App Group the keyboards read (`KeyboardSettings`).
    @AppStorage(KeyboardSettings.Key.autoCapitalization, store: KeyboardSettings.store())
    private var autoCapitalization = KeyboardSettings().autoCapitalization
    @AppStorage(KeyboardSettings.Key.autoCorrection, store: KeyboardSettings.store())
    private var autoCorrection = KeyboardSettings().autoCorrection
    @AppStorage(KeyboardSettings.Key.capsLock, store: KeyboardSettings.store())
    private var capsLock = KeyboardSettings().capsLock
    @AppStorage(KeyboardSettings.Key.predictiveText, store: KeyboardSettings.store())
    private var predictiveText = KeyboardSettings().predictiveText
    @AppStorage(KeyboardSettings.Key.characterPreview, store: KeyboardSettings.store())
    private var characterPreview = KeyboardSettings().characterPreview
    @AppStorage(KeyboardSettings.Key.periodShortcut, store: KeyboardSettings.store())
    private var periodShortcut = KeyboardSettings().periodShortcut
    @AppStorage(AgentCommand.key) private var agentCommand = ""

    var body: some View {
        List {
            Section {
                if account.isSignedIn {
                    LabeledContent("Signed in", value: account.email ?? "")
                    Button("Sign out") { Task { busy = true; await account.signOut(); busy = false } }
                        .disabled(busy)
                } else {
                    Button("Sign in") { showLogin = true }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Signing in enables Remote Wake — waking a sleeping Mac from your phone. The terminal and demo don't require an account.")
            }

            if account.isSignedIn {
                Section {
                    Button("Delete Account", role: .destructive) { confirmDelete = true }
                        .disabled(busy)
                } footer: {
                    Text("Permanently deletes your account and remote-wake settings from the server. This can't be undone.")
                }
            }

            Section {
                TextField(AgentCommand.defaultCommand, text: $agentCommand)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Agent command")
            } footer: {
                Text("Create agent session runs this in your login shell on the Mac, then leaves you at a shell when it exits. Empty uses the default.")
            }

            // Apple's Settings › General › Keyboard, in its order, for what Prosper's has.
            // Not on the Mac: no Prosper keyboard there to read them.
            #if !targetEnvironment(macCatalyst)
            Section {
                Toggle("Auto-Capitalization", isOn: $autoCapitalization)
                Toggle("Auto-Correction", isOn: $autoCorrection)
                Toggle("Enable Caps Lock", isOn: $capsLock)
                Toggle("Predictive Text", isOn: $predictiveText)
                Toggle("Character Preview", isOn: $characterPreview)
                Toggle("\u{201C}.\u{201D} Shortcut", isOn: $periodShortcut)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("The Prosper keyboard follows these in other apps once it has Full Access; without it, Auto-Capitalization is off and the rest on. In the terminal, Enable Caps Lock and Character Preview apply. Double tapping the space bar will insert a period followed by a space.")
            }
            #endif

            if let error { Section { Text(error).foregroundStyle(.red).font(.callout) } }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogin) { LoginView(account: account) }
        .sheet(isPresented: $confirmDelete) {
            DeleteAccountSheet(busy: $busy) { await delete() }
        }
    }

    private func delete() async {
        busy = true
        defer { busy = false }
        do { try await account.deleteAccount(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

/// Type-to-confirm account deletion (GitHub-style): the destructive button stays
/// disabled until the user types DELETE, so it can't be hit by a stray tap. Dismisses
/// itself after the work runs; on success the parent's Delete section disappears anyway.
struct DeleteAccountSheet: View {
    @Binding var busy: Bool
    var onConfirm: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var armed: Bool { text == "DELETE" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("This permanently deletes your account and all remote-wake settings from the server. It can't be undone.")
                        .font(.callout)
                }
                Section {
                    TextField("DELETE", text: $text)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .disabled(busy)
                } header: { Text("Type DELETE to confirm") }
                Section {
                    Button(role: .destructive) {
                        Task { await onConfirm(); dismiss() }
                    } label: {
                        HStack {
                            Text("Delete Account")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!armed || busy)
                }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(busy) }
            }
        }
        .interactiveDismissDisabled(busy)
    }
}
