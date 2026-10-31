import SwiftUI

/// What "Create agent session" runs, set in Settings. Blank means the default.
enum AgentCommand {
    static let key = "agentCommand"
    static let defaultCommand = "headroom wrap claude --chrome"

    /// The argv dch spawns for `setting`. dch execs it without a shell, on the GUI app's
    /// PATH and in its cwd `/`, and drops the session when it exits. So: the user's
    /// `$SHELL` as a login, interactive shell (PATH and aliases from the rc files), `cd`
    /// home (`builtin`, past any `cd` function from the rc files, such as zoxide's), the
    /// command `eval`ed from `$1` (passed as an argument, never quoted into the script),
    /// then `exec` a login shell so the session stays at a prompt. A Ctrl-C that
    /// kills the agent would abort that `exec`; `trap : INT` needs to be a handler, since
    /// an ignore (`trap '' INT`) doesn't stop it.
    static func argv(_ setting: String) -> [String] {
        let typed = plain(setting.trimmingCharacters(in: .whitespacesAndNewlines))
        let shell = "\"${SHELL:-/bin/zsh}\""
        return ["/bin/sh", "-c",
                "exec \(shell) -lic 'builtin cd; trap : INT; eval \"$1\"; exec \"$0\" -l' \(shell) \"$1\"",
                "sh", typed.isEmpty ? defaultCommand : typed]
    }

    /// Undo smart punctuation: the iOS keyboard (and Catalyst's substitutions) type
    /// `--` as `—`, `...` as `…` and quotes as curly ones, even with autocorrection off.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2014}", with: "--")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: "[\u{201C}\u{201D}\u{201E}]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[\u{2018}\u{2019}]", with: "'", options: .regularExpression)
    }

    /// The session `name` would attach to, as listed: dch names ignore case, so `Demo`
    /// attaches to a running `demo` and the agent command never runs. Nil when free or blank.
    static func taken(_ name: String, in sessions: [String]) -> String? {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        return sessions.first { $0.caseInsensitiveCompare(typed) == .orderedSame }
    }

    /// Create the agent session `name` and detach once it has drawn. dch's master exists
    /// from the first output on (17-164 ms after spawn); a client closed sooner leaves no
    /// session. Closing only detaches: the session keeps running for the attach that follows.
    static func start(_ setting: String, name: String, on transport: SessionTransport) async throws -> String {
        let stream = try await transport.create(name: name, command: argv(setting), cols: 80, rows: 24)
        for await _ in stream.output { break }
        stream.close()
        return name
    }
}

/// Account settings (PLAN §3 / §6.3): sign in/out and the mandatory in-app Delete
/// Account (Apple 5.1.1(v)). Reachable from Home. Signing in is only needed for
/// Remote Wake and live status — everything else works signed-out. Below them, the live
/// status switch (`LiveStatus`), the Prosper keyboard's switches (`KeyboardSettings`),
/// the agent command (`AgentCommand`) and the session rows' details (`RowDetails`).
struct SettingsView: View {
    @ObservedObject var account: AccountStore
    @ObservedObject private var live = LiveStatus.shared
    @State private var showLogin = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var notificationsOff = false
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
    @AppStorage(KeyboardSettings.Key.keySize, store: KeyboardSettings.store())
    private var keySize = KeyboardSettings().keySize
    @AppStorage(KeyboardSettings.Key.saveCopies, store: KeyboardSettings.store())
    private var saveCopies = KeyboardSettings().saveCopies
    @AppStorage(Dictation.ReadyPeriod.key) private var readyPeriod = Dictation.ReadyPeriod.ten
    @ObservedObject private var dictation = DictationService.shared
    @AppStorage(AgentCommand.key) private var agentCommand = ""
    @AppStorage(DchSession.sidekickKey) private var sidekickPattern = DchSession.sidekickDefault
    // Session list rows (`RowDetails`), on this device only.
    @AppStorage(RowDetails.Key.agents) private var rowAgents = RowDetails().agents
    @AppStorage(RowDetails.Key.openPRs) private var rowOpenPRs = RowDetails().openPRs
    @AppStorage(RowDetails.Key.merged) private var rowMerged = RowDetails().merged
    @AppStorage(RowDetails.Key.tasksDone) private var rowTasksDone = RowDetails().tasksDone
    @AppStorage(RowDetails.Key.inProgress) private var rowInProgress = RowDetails().inProgress
    @AppStorage(RowDetails.Key.queued) private var rowQueued = RowDetails().queued
    @AppStorage(RowDetails.Key.sessionName) private var rowSessionName = RowDetails().sessionName

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
                Text("Signing in enables Remote Wake — waking a sleeping Mac from your phone — and live status. The terminal and demo don't require an account.")
            }

            // Not on the Mac: no Live Activities there, and it is the Mac being watched.
            #if !targetEnvironment(macCatalyst)
            if account.isSignedIn {
                Section {
                    Toggle("Live status and alerts", isOn: Binding(get: { live.enabled }, set: { on in
                        Task {
                            busy = true
                            defer { busy = false }
                            if !on { await live.turnOff() }
                            else { notificationsOff = !(await live.turnOn()) }
                        }
                    }))
                    .disabled(busy)
                    if notificationsOff && !live.enabled {
                        Button("Notifications are off · Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    // Off in the Settings app: alerts still come, the card can't show.
                    if live.enabled && !live.activitiesAllowed {
                        Button("Live Activities are off · Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } footer: {
                    Text("An alert only when a session needs you, and a live card on the Lock Screen while agents work. Needs your Mac signed in to the same account.")
                }
            }
            #endif

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

            Section {
                Toggle("Agents", isOn: $rowAgents)
                Toggle("Open PRs", isOn: $rowOpenPRs)
                Toggle("Merged", isOn: $rowMerged)
                Toggle("Tasks done", isOn: $rowTasksDone)
                Toggle("In progress", isOn: $rowInProgress)
                Toggle("Queued", isOn: $rowQueued)
                Toggle("Session name", isOn: $rowSessionName)
            } header: {
                Text("Session list")
            } footer: {
                Text("Row details each session shows. Its title and state always show.")
            }

            Section {
                TextField("Sidekick pattern", text: $sidekickPattern)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Sidekicks")
            } footer: {
                Text("Sessions whose name or alias contains this, ignoring case, go under a Sidekicks tab in the session list. Empty shows every session together.")
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
                NavigationLink("Keys Beside Space") { BottomRowSettings() }
                Picker("Key Size", selection: $keySize) {
                    ForEach(KeyboardSettings.KeySize.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("The Prosper keyboard follows these in other apps once it has Full Access; without it, Auto-Capitalization is off, Key Size is Normal and the rest on. In the terminal, Enable Caps Lock, Character Preview, Keys Beside Space and Key Size apply. Key Size makes the rows taller in portrait, from the next time the keyboard shows.")
            }

            Section {
                NavigationLink("System Keyboard Toolbar") { ShortcutEditor(bar: .toolbar, sheet: false) }
                NavigationLink("Terminal Shortcut Keys") { ShortcutEditor(sheet: false) }
            } footer: {
                Text("The System Keyboard Toolbar shows above the Prosper keyboard in other apps when you tap the toolbar toggle at the leading edge of its strip. Terminal Shortcut Keys are the bar under the terminal. The toolbar list needs Full Access; without it, the keyboard shows the default keys.")
            }

            Section {
                Toggle("Save Copies Automatically", isOn: $saveCopies)
                Button("Open Prosper in iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } header: {
                Text("Clipboard History")
            } footer: {
                Text("On by default: the Prosper keyboard keeps what you copy in other apps, the latest copy each time it shows. Needs Full Access. iOS asks before each save unless Settings › Prosper › Paste from Other Apps is set to Allow.")
            }

            // The keyboards' mic key (#598).
            Section {
                Picker("Keep Mic Ready", selection: $readyPeriod) {
                    ForEach(Dictation.ReadyPeriod.allCases) { Text($0.title).tag($0) }
                }
                if dictation.warm {
                    Button("Stop the Mic", role: .destructive) { dictation.stop() }
                }
            } header: {
                Text("Dictation")
            } footer: {
                Text("Add Dictate to the System Keyboard Toolbar, then tap it in any app to type what you say, in English. The first tap opens Prosper to turn the mic on; tap ◀ to go back and keep talking. Prosper keeps the mic ready in the background for this long after you last dictate, with the orange dot showing, so the next tap starts at once. Needs Full Access and iOS 26.")
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

/// The bottom row's keys beside space: drag to reorder, around space too, switch one off
/// to hide it. Both keyboards read them (`KeyboardSettings.bottomRow`).
struct BottomRowSettings: View {
    @AppStorage(KeyboardSettings.Key.bottomOrder, store: KeyboardSettings.store())
    private var order = KeyboardSettings().bottomOrder
    @AppStorage(KeyboardSettings.Key.bottomHidden, store: KeyboardSettings.store())
    private var hidden = KeyboardSettings().bottomHidden
    private static let names: [Character: String] =
        [".": "Period", ",": "Comma", "/": "Slash", "?": "Question Mark", KeyboardSettings.emojiKey: "Emoji"]

    var body: some View {
        let keys = KeyboardSettings.order(order)
        List {
            Section {
                ForEach(keys, id: \.self) { k in
                    if k == " " {
                        Text("Space").foregroundStyle(.secondary)
                    } else {
                        let name = Self.names[k] ?? String(k)
                        Toggle(isOn: Binding(
                            get: { !hidden.contains(k) },
                            set: { on in hidden = hidden.filter { $0 != k } + (on ? "" : String(k)) })) {
                            HStack {
                                Text(name)
                                Text(String(k)).font(.body.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel(name)
                    }
                }
                .onMove { from, to in
                    var moved = keys
                    moved.move(fromOffsets: from, toOffset: to)
                    order = String(moved)
                }
            } footer: {
                Text("Space widens to take a hidden key's place. Only / is also a hold (on m), so hiding another key takes its character off the keyboard. Emoji is on this app's keyboard only; in other apps, the globe reaches iOS's own emoji.")
            }
        }
        .environment(\.editMode, .constant(.active))   // keep .onMove handles visible
        .navigationTitle("Keys Beside Space")
        .navigationBarTitleDisplayMode(.inline)
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
