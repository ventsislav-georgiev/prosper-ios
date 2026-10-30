import SwiftUI
import UIKit

@main
struct ProsperApp: App {
    // Device-token callbacks and notification taps for live status (`LiveStatus`).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // The per-session bell is gone; drop the switches it persisted.
        UserDefaults.standard.removeObject(forKey: "sessionAlerts.v1")
        #if DEBUG
        // ponytail: run the cheap assert-based self-checks once at launch so a broken
        // backoff schedule / Machine migration / wakeId derivation trips in dev.
        _backoffSelfCheck()
        _wakeSelfCheck()
        _machineSelfCheck()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // Screenshot hook (env-gated, never set for real users): jump straight
            // to a screen so App Store captures are deterministic.
            if uiScreen == "demo-terminal" {
                NavigationStack {
                    TerminalScreen(transport: DemoTransport(),
                                   session: DchSession(name: "demo", alias: "Demo session"))
                }
            } else {
                HomeView()
            }
        }
    }
}

/// Optional deep-link target for reproducible screenshots. Unset in normal use.
let uiScreen = ProcessInfo.processInfo.environment["PROSPER_UI_SCREEN"]

/// Navigation routes for the Remote Terminal feature. `connect` = the machine
/// picker; `sessions` = the dch session list for a machine (id, or the demo sentinel),
/// optionally opening one session once it is listed (a tapped alert), `tap` telling one
/// tap's screen from the last one's; `settings` = the account screen.
enum Route: Hashable {
    case connect
    case sessions(MachineRef, open: String? = nil, tap: UUID? = nil)
    case settings
}

/// What `Route.sessions` points at: a saved Machine (by id) or the offline demo.
/// `id`-based so renames/reorders don't break an in-flight navigation.
enum MachineRef: Hashable {
    case machine(UUID)
    case demo
}

/// App home. A list of Prosper features; tap one to open it. Remote Terminal
/// (the dch/dtach client over Tailscale) is the first and currently only one.
/// Tapping it jumps straight to the first machine's session list (auto-connect),
/// or the machine picker if there's no machine saved yet.
struct HomeView: View {
    @StateObject private var store = MachineStore()
    @StateObject private var account = AccountStore()
    @ObservedObject private var live = LiveStatus.shared
    @State private var path: NavigationPath
    @State private var showHelp = false
    @State private var notificationsDenied = false   // Turn On met an earlier "Don't Allow"

    init() {
        var p = NavigationPath()
        switch uiScreen {                        // screenshot deep-links (env-gated)
        case "connect": p.append(Route.connect)
        case "demo-sessions": p.append(Route.sessions(.demo))
        default: break
        }
        _path = State(initialValue: p)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                #if !targetEnvironment(macCatalyst)
                if account.isSignedIn && !live.asked && !live.enabled { notificationsCard }
                #endif
                NavigationLink(value: store.machines.first.map { Route.sessions(.machine($0.id)) } ?? Route.connect) {
                    Label("Remote Terminal", systemImage: "terminal")
                }
                NavigationLink(value: Route.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .navigationTitle("Prosper")
            .toolbar { helpButton($showHelp) }
            .sheet(isPresented: $showHelp) { HelpView() }
            // iOS asks only once; after a denial Turn On shows no prompt, so say so.
            .alert("Notifications are off", isPresented: $notificationsDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Later", role: .cancel) {}
            } message: {
                Text("Notifications are off for Prosper. Allow them in the Settings app, then turn on Live status in Prosper's Settings.")
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .connect:
                    ConnectScreen(store: store) { ref in go(.sessions(ref)) }
                case .sessions(let ref, let open, let tap):
                    sessionList(for: ref, open: open, tap: tap)
                case .settings:
                    SettingsView(account: account)
                }
            }
        }
        // The Live Activity's link and a tapped "needs you" alert: that Mac's sessions
        // (and the session, for an alert), or just home when no saved Mac matches.
        .onOpenURL { url in if let t = LiveTarget(url: url) { live.target = t } }
        .onReceive(live.$target) { t in
            guard let t else { return }
            live.target = nil
            // Already in that session (an alert tapped in Notification Center): stay put.
            guard t.banners(over: live.attached) else { return }
            if let r = t.route(in: store.machines) { go(r) } else { path = NavigationPath() }
        }
    }

    /// Asked once, after sign-in: Turn On or Not now, and never again after Not now
    /// (Settings keeps the switch).
    private var notificationsCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Turn on notifications", systemImage: "bell.badge").font(.headline)
                Text("Prosper notifies you only when a session needs you, and shows a live card on the Lock Screen while agents work on your Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button("Turn On") { Task { if !(await live.turnOn()) { notificationsDenied = true } } }
            Button("Not now") { live.notNow() }.foregroundStyle(.secondary)
        }
    }

    /// Pick a machine from the picker → collapse back to a single Home → Sessions level
    /// (so Back from the new session list returns Home, never machine→machine→…).
    private func go(_ route: Route) {
        path = NavigationPath()
        path.append(route)
    }

    @ViewBuilder private func sessionList(for ref: MachineRef, open: String?, tap: UUID?) -> some View {
        // "Change" PUSHES the picker on top of Sessions (Home → Sessions → Machines),
        // so Back from Machines returns to Sessions — the expected hierarchy.
        switch ref {
        case .demo:
            SessionListView(transport: DemoTransport(), title: demoTitle, machine: nil,
                            store: store, account: account, onChangeMachine: { path.append(Route.connect) })
        case .machine(let id):
            if let m = store.machines.first(where: { $0.id == id }) {
                // `.id(ref)` because SwiftUI reuses a destination view of the same type at
                // the same depth: without it, switching machines kept the previous machine's
                // @State — its transport (so the new machine's row dialed the OLD Mac), its
                // half-finished `trying` address, and its leftover error text. A new tap is
                // a fresh list too, so its session opens even if an earlier tap opened it.
                SessionListView(transport: ProsperTransport(host: m.addresses.first ?? m.name),
                                title: m.name, machine: m, store: store, account: account,
                                onChangeMachine: { path.append(Route.connect) }, openSession: open)
                    .id(Route.sessions(ref, open: open, tap: tap))
            } else {
                ConnectScreen(store: store) { r in go(.sessions(r)) }
            }
        }
    }
}

/// Display title for the offline demo machine row.
let demoTitle = "Demo"

/// Unobtrusive `?` toolbar item shared by Home and the machine picker.
@ToolbarContentBuilder
func helpButton(_ shown: Binding<Bool>) -> some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
        Button { shown.wrappedValue = true } label: { Image(systemName: "questionmark.circle") }
            .accessibilityLabel("How it works")
    }
}

/// Machine picker (PLAN §3): a list of saved Machines, each with one or more
/// priority-ordered addresses. Tapping a machine connects; an editor adds machines and
/// reorders their addresses by drag. The offline demo lives at the bottom.
struct ConnectScreen: View {
    @ObservedObject var store: MachineStore
    let onConnect: (MachineRef) -> Void
    @State private var editing: Machine?           // nil = sheet closed; .some = add/edit
    @State private var showHelp = false

    var body: some View {
        List {
            if store.machines.isEmpty {
                Section {
                    Text("Add your Mac to get started — its Tailscale name or IP, running Prosper.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(store.machines) { m in
                Section {
                    Button { onConnect(.machine(m.id)) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).font(.headline).foregroundStyle(.primary)
                                if let first = m.addresses.first {
                                    Text(first).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            WakeBadge(wake: m.cachedWake)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Button { editing = m } label: { Label("Edit", systemImage: "pencil") }
                        .font(.callout)
                    Button(role: .destructive) { store.remove(m) } label: { Label("Remove", systemImage: "trash") }
                        .font(.callout)
                }
            }
            Section {
                Button { editing = Machine(name: "", addresses: [""]) } label: {
                    Label("Add machine", systemImage: "plus")
                }
            } footer: {
                Text("Each machine's [Tailscale](https://tailscale.com) name(s) or IP(s), running Prosper. [How it works](prosper://help)")
            }
            // Secondary: an offline sample so the app is explorable before a real
            // machine is set up. Tucked at the bottom, out of the daily path.
            Section {
                Button { onConnect(.demo) } label: {
                    Label("Try the demo", systemImage: "play.circle")
                }
            } footer: { Text("Explore a sample session — no machine required.") }
        }
        .navigationTitle("Machines")
        .toolbar { helpButton($showHelp) }
        .sheet(isPresented: $showHelp) { HelpView() }
        .sheet(item: $editing) { m in MachineEditor(store: store, draft: m) }
        .environment(\.openURL, OpenURLAction { url in
            if url.absoluteString == "prosper://help" { showHelp = true; return .handled }
            return .systemAction
        })
    }
}

/// Add/edit a Machine: a name plus an editable, drag-reorderable address list (PLAN §3
/// — addresses are tried in priority order, so order matters).
struct MachineEditor: View {
    @ObservedObject var store: MachineStore
    @State var draft: Machine
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .active   // keep .onMove handles visible

    private var isNew: Bool { !store.machines.contains { $0.id == draft.id } }

    var body: some View {
        NavigationStack {
            List {
                Section("Name") {
                    TextField("Studio Mac", text: $draft.name)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(draft.addresses.indices, id: \.self) { i in
                        TextField("my-mac.tailnet.ts.net or 100.x.y.z", text: $draft.addresses[i])
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    .onMove { from, to in draft.addresses.move(fromOffsets: from, toOffset: to) }
                    .onDelete { draft.addresses.remove(atOffsets: $0) }
                    Button { draft.addresses.append("") } label: { Label("Add address", systemImage: "plus") }
                } header: { Text("Addresses (drag to set priority)") }
                footer: { Text("Tried top-to-bottom; the first that connects wins.") }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(isNew ? "Add machine" : "Edit machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Save") { save() }.disabled(!valid) }
            }
        }
        .interactiveDismissDisabled()   // swipe-down would discard unsaved reorder/name edits
    }

    private var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.addresses.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func save() {
        var m = draft
        m.name = m.name.trimmingCharacters(in: .whitespaces)
        m.addresses = m.addresses.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if isNew { store.add(m) } else { store.update(m.id) { $0 = m } }
        dismiss()
    }
}

struct SessionListView: View {
    @State var transport: SessionTransport
    let title: String
    let machine: Machine?              // nil for the demo
    @ObservedObject var store: MachineStore   // observed so handshake-populated cachedWake redraws the badge
    @ObservedObject var account: AccountStore
    var onChangeMachine: () -> Void = {}
    var openSession: String? = nil     // a tapped alert's session, opened once it is listed
    @State private var openTried = false
    @State private var sessions: [DchSession] = []
    @State private var error: String?
    @State private var notice: String?             // agent refusal; unlike `error`, gates nothing
    @State private var loading = false             // connect/list round-trip in flight
    @State private var trying: String?             // address being dialed right now
    @State private var unreachable: String?        // host-unreachable → offer Wake
    @State private var open: DchSession?          // programmatic push target
    @State private var renaming: DchSession?       // rename alert
    @State private var renameText = ""
    @State private var killing: DchSession?        // kill-confirm alert
    @State private var creating = false            // new-session alert
    @State private var newName = ""
    @State private var sleeping = false            // sleep round-trip in flight
    // #590: the Mac's verbs, from the handshake; empty (an older Mac, the demo) hides
    // Restart, the new Stop and the ⋯ menu.
    @State private var ops: Set<SessionVerb> = []
    // #590: name → "Restarting…"/"Stopping…" while its verb runs; "" is Restart all's line.
    @State private var running: [String: String] = [:]
    @State private var confirmingRestartAll = false
    @State private var stoppingAll: [String]?      // Stop all's confirm: the tab's names, counted when asked
    @State private var failed: (title: String, message: String)?   // a verb's error 0x13, as written
    @State private var showingHistory = false      // #589: the ⋯ menu's History sheet
    // The Sidekicks segment is chosen. Scene storage, so the list an alert or Live Activity
    // rebuilds (a new `.id`) comes back on the same tab.
    @SceneStorage("sessions.sidekickTab") private var sidekickTab = false
    @AppStorage(DchSession.sidekickKey) private var sidekickPattern = DchSession.sidekickDefault
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    // Live store snapshot so the badge tracks cachedWake after handshake (the `machine`
    // prop is a stale value-type copy captured at navigation time).
    private var liveMachine: Machine? {
        guard let id = machine?.id else { return nil }
        return store.machines.first { $0.id == id }
    }

    /// Name the address being dialed, so a machine with several addresses shows the
    /// fallback walking down the list instead of one silent spinner.
    private var connectLabel: String {
        guard let a = trying, a != title else { return "Connecting to \(title)…" }
        return "Connecting to \(title) — \(a)…"
    }

    var body: some View {
        List {
            // Machine row → back to the picker to switch/manage connections.
            Button { onChangeMachine() } label: {
                HStack {
                    Image(systemName: "desktopcomputer")
                    Text(title).font(.headline)
                    WakeBadge(wake: liveMachine?.cachedWake)
                    Spacer()
                    Text("Change").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            // Connecting: a real round-trip is in flight and nothing resolved yet.
            if loading && sessions.isEmpty && error == nil && unreachable == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(connectLabel).foregroundStyle(.secondary)
                }
            }
            // Host unreachable + a real machine → the Wake gating/waking card.
            if let msg = unreachable, let m = machine {
                Section {
                    WakeFailedView(machine: m, message: msg, account: account, machines: store) { t, _ in
                        transport = t
                        unreachable = nil
                        Task { await refresh() }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                }
            } else if let line = error ?? notice {
                Text(line).foregroundStyle(.secondary)
            }
            if let line = running[""] {
                HStack(spacing: 10) { ProgressView(); Text(line).foregroundStyle(.secondary) }
            }
            let split = DchSession.split(DchSession.ordered(sessions), pattern: sidekickPattern)
            if split.sidekicks.isEmpty {
                ForEach(split.primary) { s in row(s) }
            } else {
                // Own section, picker as its header: the machine card above stays in one piece.
                let shows = DchSession.showsSidekicks(split, tab: sidekickTab)
                Section {
                    ForEach(shows ? split.sidekicks : split.primary) { s in row(s) }
                } header: {
                    Picker("Sessions", selection: Binding(get: { shows }, set: { sidekickTab = $0 })) {
                        Text("Sessions (\(split.primary.count))").tag(false)
                        Text("Sidekicks (\(split.sidekicks.count))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .textCase(nil)
                }
            }
        }
        // The last sidekick gone (or the split turned off): back to Sessions for good.
        .onChange(of: DchSession.split(sessions, pattern: sidekickPattern).sidekicks.isEmpty) { empty in
            if empty { sidekickTab = false }
        }
        .navigationTitle("Sessions")
        .toolbar {
            // Only offer Sleep when remote wake is known-enabled — otherwise a tap would
            // strand the Mac asleep with no way to wake it back.
            if liveMachine?.cachedWake?.enabled == true {
                Button { Task { await sleepMachine() } } label: {
                    if sleeping { ProgressView() } else { Image(systemName: "moon") }
                }
                .disabled(sleeping || unreachable != nil || error != nil || loading)   // can't sleep an unreachable Mac
            }
            Button { newName = ""; notice = nil; creating = true } label: { Image(systemName: "plus") }
                .disabled(sleeping || unreachable != nil || error != nil || loading)   // no new session on an unreachable Mac
            controlsMenu
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(sleeping || loading)
        }
        .task { await refresh() }
        // Keyed on the scene phase: the poll exists only while the app is in front.
        .task(id: scenePhase == .active) { await pollStates() }
        // Programmatic push for tap-to-attach and newly created sessions.
        .navigationDestination(isPresented: Binding(get: { open != nil },
                                                    set: { if !$0 { open = nil } })) {
            if let open {
                // Tracked so that session's own "needs you" alert doesn't banner over it.
                TerminalScreen(transport: transport, session: open)
                    .onAppear {
                        LiveStatus.shared.attached = LiveTarget(macId: liveMachine?.serverDeviceId, session: open.name)
                    }
                    .onDisappear {
                        // Only our own: after a switch the next terminal's onAppear can run first.
                        if LiveStatus.shared.attached == LiveTarget(macId: liveMachine?.serverDeviceId, session: open.name) {
                            LiveStatus.shared.attached = nil
                        }
                    }
            }
        }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil },
                                                      set: { if !$0 { renaming = nil } })) {
            TextField("Alias", text: $renameText)
            Button("Save") { commitRename(renameText) }
            Button("Clear", role: .destructive) { commitRename("") }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("Empty alias reverts to the real name.") }
        .alert("Stop \(killing?.title ?? "")?", isPresented: Binding(get: { killing != nil },
                                                                     set: { if !$0 { killing = nil } })) {
            Button("Stop", role: .destructive) {
                if let k = killing { Task { try? await transport.kill(name: k.name); await refresh() } }
                killing = nil
            }
            Button("Cancel", role: .cancel) { killing = nil }
        } message: { Text("Ends the session and its running program. Can't be undone.") }
        .alert("Restart stale agents?", isPresented: $confirmingRestartAll) {
            Button("Restart") {
                run(SessionVerb.restart.failTitle(all: true), "Restarting stale agents…", [""]) { try await $0.restart(names: nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Each pauses for up to minutes.") }
        .alert("Stop \(stoppingAll?.count ?? 0) session\(stoppingAll?.count == 1 ? "" : "s")?",
               isPresented: Binding(get: { stoppingAll != nil }, set: { if !$0 { stoppingAll = nil } })) {
            Button("Stop", role: .destructive) {
                if let names = stoppingAll {
                    run(SessionVerb.stop.failTitle(all: true), "Stopping…", names) { try await $0.stop(names: names) }
                }
                stoppingAll = nil
            }
            Button("Cancel", role: .cancel) { stoppingAll = nil }
        }
        .alert(failed?.title ?? "", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failed?.message ?? "") }
        .sheet(isPresented: $showingHistory) {
            HistorySheet(transport: transport, canRevive: ops.contains(.revive)) { await refresh() }
        }
        .alert("New session", isPresented: $creating) {
            TextField("Name (optional)", text: $newName)
            Button("Create") { startNew() }
            Button("Create agent session") { Task { await startAgent() } }
                .disabled(existingName != nil)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Opens a fresh dch session on \(title).") }
    }

    /// At accessibility sizes the buttons go under the row, so the name and state keep
    /// the width.
    @ViewBuilder private func row(_ s: DchSession) -> some View {
        let label = SessionRow(session: s)
            .contentShape(Rectangle())
            .onTapGesture { open = s }
            .accessibilityAction { open = s }
        let buttons = HStack(spacing: 16) {
            Button { renaming = s; renameText = s.alias ?? "" } label: {
                Image(systemName: "pencil")
            }.buttonStyle(.borderless)
            if let text = running[s.name] {
                // #590: its verb runs; the row still opens, and every other row is free.
                HStack(spacing: 6) { ProgressView(); Text(text).font(.caption).foregroundStyle(.secondary) }
            } else {
                if ops.contains(.restart) {
                    Button {
                        run(SessionVerb.restart.failTitle(all: false), "Restarting…", [s.name]) { try await $0.restart(names: [s.name]) }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }.buttonStyle(.borderless).accessibilityLabel("Restart agent")
                }
                // #590: the Mac's Stop runs unasked (dch records it, so it can be revived);
                // an older Mac has only kill, which can't be undone, so that one asks.
                Button(role: .destructive) {
                    if ops.contains(.stop) {
                        run(SessionVerb.stop.failTitle(all: false), "Stopping…", [s.name]) { try await $0.stop(names: [s.name]) }
                    } else { killing = s }
                } label: {
                    Image(systemName: "xmark.circle")
                }.buttonStyle(.borderless).foregroundStyle(.red).accessibilityLabel("Stop")
            }
        }
        if typeSize.isAccessibilitySize {
            VStack(alignment: .trailing, spacing: 8) { label; buttons }
        } else {
            HStack(spacing: 16) { label; buttons }
        }
    }

    /// #590: the Mac's ⋯ (Agent Island): Restart all agents and Stop all in <tab>…, each on its op.
    /// #589: and History, on any of the Mac's verbs.
    @ViewBuilder private var controlsMenu: some View {
        if !ops.isEmpty {
            Menu {
                if ops.contains(.history) {
                    Button { showingHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                }
                if ops.contains(.restart) {
                    Button("Restart all agents") { confirmingRestartAll = true }
                        .disabled(sessions.isEmpty || running[""] != nil)
                }
                if ops.contains(.stop) {
                    let tab = shownTab, names = tab.sessions.map(\.name).filter { running[$0] == nil }
                    Button("Stop all in \(tab.name)…", role: .destructive) { stoppingAll = names }
                        .disabled(names.isEmpty)
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Session controls")
                .disabled(sleeping || unreachable != nil || error != nil)
        }
    }

    /// #590: the visible tab, for Stop all: its name and its sessions.
    private var shownTab: (name: String, sessions: [DchSession]) {
        let split = DchSession.split(sessions, pattern: sidekickPattern)
        return DchSession.showsSidekicks(split, tab: sidekickTab) ? ("Sidekicks", split.sidekicks) : ("Sessions", split.primary)
    }

    /// #590: run a verb, `rows` showing `text` until its one reply lands (minutes, for a
    /// restart), then re-list. Its error goes up as the Mac wrote it, under `title` (#589).
    private func run(_ title: String, _ text: String, _ rows: [String],
                     _ op: @escaping (SessionTransport) async throws -> [String]) {
        for n in rows { running[n] = text }
        let t = transport
        Task {
            if let f = await Self.attempt(title, on: t, op) { failed = f }
            for n in rows where running[n] == text { running[n] = nil }
            await refresh()
        }
    }

    /// #589: one verb's reply as its alert: nil when it went through (or was cancelled),
    /// else `title` over the Mac's message as written ("2 resumed, 1 failed").
    static func attempt(_ title: String, on t: SessionTransport,
                        _ op: (SessionTransport) async throws -> [String]) async -> (title: String, message: String)? {
        do { _ = try await op(t); return nil } catch {
            return isCancellation(error) ? nil : (title, error.localizedDescription)
        }
    }

    /// Poll the sessions' states while the app is in front.
    ///
    /// The row's working/idle/blocked label is the reason to open the list at all, and
    /// without the poll it stays frozen at whatever the last manual refresh saw. One small
    /// list round-trip every few seconds is cheaper than a user pressing refresh to find out.
    private func pollStates() async {
        // Only ever started while the app is in front (`.task(id:)` on the scene phase), so
        // going away cancels the loop outright instead of leaving a timer ticking.
        guard scenePhase == .active else { return }
        let poll = UInt64(SessionPoll.interval * 1_000_000_000)
        let backoff = UInt64(SessionPoll.failureBackoff * 1_000_000_000)
        // A fresh screen already has `.task { refresh() }` in flight, so wait a beat. Coming
        // back from the background has no such refresh, and the rows on screen are as stale
        // as the time away — poll those at once instead of showing yesterday's states for
        // another interval.
        var immediate = !sessions.isEmpty
        while !Task.isCancelled {
            if immediate { immediate = false } else { try? await Task.sleep(nanoseconds: poll) }
            guard !Task.isCancelled else { return }
            guard unreachable == nil, error == nil else { continue }
            guard let list = try? await transport.listSessions() else {
                try? await Task.sleep(nanoseconds: backoff)      // asleep Mac: stop hammering
                continue
            }
            // Don't touch `sessions` unless something actually moved: an equal array still
            // marks the state dirty and redraws every row.
            if !loading, list != sessions { sessions = list }
        }
    }

    private func commitRename(_ alias: String) {
        guard let r = renaming else { return }
        let a = alias.trimmingCharacters(in: .whitespaces)
        Task { try? await transport.rename(name: r.name, alias: a.isEmpty ? nil : a); await refresh() }
        renaming = nil
    }

    private func startNew() {
        open = DchSession(name: takeNewName(), alias: nil)
    }

    /// dch creates the session on first attach; a stable name keeps reconnects
    /// pinned to it. Generate one when the user doesn't name it.
    private func takeNewName() -> String {
        let typed = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        return typed.isEmpty ? "ses-\(String(Int(Date().timeIntervalSince1970), radix: 36))" : typed
    }

    /// The typed name when a session already has it: dch would attach to that one and
    /// never run the agent command.
    private var existingName: String? {
        AgentCommand.taken(newName, in: sessions.map(\.name))
    }

    /// Start a session running the Settings agent command (`AgentCommand`), then open it
    /// by name like any other. The demo has no agent to start, so it opens its sample
    /// agent session instead.
    private func startAgent() async {
        guard !(transport is DemoTransport) else {
            newName = ""
            open = DchSession(name: "claude", alias: "claude (sample)")
            return
        }
        // The button is disabled for a taken name; this covers an alert that ignores that.
        if let taken = existingName {
            newName = ""
            notice = "A session named \(taken) already exists, so the agent command would not run."
            return
        }
        let name = takeNewName()
        let setting = UserDefaults.standard.string(forKey: AgentCommand.key) ?? ""
        do {
            open = DchSession(name: try await withDeadline(seconds: 8) {
                try await AgentCommand.start(setting, name: name, on: transport)
            }, alias: nil)
        } catch {
            guard !isCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }

    /// Open a throwaway session that triggers `prosper://sleep` on the Mac, then
    /// drop it. `open` runs the URL through the local Prosper app (PowerSleepControl)
    /// which sleeps the machine; the session exits on its own and we close our end.
    /// The Mac then goes unreachable, so we pop back to the machine picker — staying
    /// on a session list whose host just fell asleep would only show dead rows.
    private func sleepMachine() async {
        sleeping = true
        defer { sleeping = false }
        do {
            let stream = try await withDeadline(seconds: 8) {
                try await transport.create(
                    name: nil, command: ["sh", "-c", "open prosper://sleep; exit 0;"], cols: 80, rows: 24)
            }
            stream.close()
            onChangeMachine()
        } catch {
            guard !isCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        loading = true
        trying = nil                 // never label this dial with the previous one's address
        defer { trying = nil }
        do {
            sessions = try await listWalkingAddresses()
            error = nil
            notice = nil
            unreachable = nil
            // Only a listed session: attaching to a name that's gone would create it anew.
            if !openTried, let name = openSession {
                openTried = true
                open = sessions.first { $0.name == name }
            }
            loading = false          // connected: stop spinning + re-enable +/refresh BEFORE the slow handshake
            await handshake()        // opportunistic, may take ~2s — must not gate the toolbar
        } catch let e as TransportError {
            loading = false
            // Host-unreachable on a real machine → surface the Wake card; other errors
            // (protocol/rejected) are plain text since waking won't help.
            if case .hostUnreachable = e, machine != nil {
                unreachable = e.localizedDescription
                error = nil
            } else {
                error = e.localizedDescription
                unreachable = nil
            }
        } catch {
            loading = false
            // Leaving the screen cancels this task; that is not a failure and must never
            // reach the UI as "Swift.CancellationError".
            guard !isCancellation(error) else { return }
            self.error = error.localizedDescription
            unreachable = nil
        }
    }

    /// List the sessions, walking the machine's addresses in priority order (PLAN §3).
    /// A wrong or asleep address answers with silence, not a refusal, so each gets its
    /// own 5s deadline and the transport is swapped to whichever address answered —
    /// attaching afterwards uses the live one, not the dead first entry.
    ///
    /// Always dialed from the machine's CURRENT addresses, never from the `transport` this
    /// screen was built with: that one is a snapshot, so a single-address machine kept
    /// talking to whatever host the snapshot named after the addresses were edited.
    private func listWalkingAddresses() async throws -> [DchSession] {
        guard let addresses = (liveMachine ?? machine)?.addresses, !addresses.isEmpty else {
            return try await transport.listSessions()      // the demo has no addresses
        }
        let hit = try await connectFirstTransport(addresses) { trying = $0 }
        transport = hit.transport
        return hit.sessions
    }

    /// Opportunistic identity handshake (PLAN §3): send 0x08, and if a 0x18 reply lands
    /// within the timeout, overwrite the machine's serverDeviceId/wakeId (refresh, not
    /// first-write-wins) and refresh cachedWake from /meta when signed in. Legacy Macs
    /// never reply → left untouched.
    private func handshake() async {
        guard let m = machine, let t = transport as? ProsperTransport else { return }
        guard let info = try? await t.machineInfo() else { return }
        ops = info.ops
        store.update(m.id) {
            $0.serverDeviceId = info.deviceId
            if let w = info.wakeId { $0.wakeId = w }
        }
        if let session = account.session, let wakeId = info.wakeId {
            let meta = await WakeClient(session: session).meta(wakeId: wakeId)
            store.update(m.id) { mm in
                switch meta {
                case .enabled(let batt, _): mm.cachedWake = WakeInfo(enabled: true, intervalAC: nil, intervalBatt: batt)
                case .disabled:          mm.cachedWake = WakeInfo(enabled: false, intervalAC: nil, intervalBatt: nil)
                case .unknown:           break
                }
            }
        }
    }
}

extension DchSession {
    /// Display order for the Sessions screen: by the shown title, case-insensitive and
    /// numeric-aware (s2 before s10), ties on `name`. Applied at render time so
    /// `sessions` (and the poll's equality check) stays in server order.
    static func ordered(_ list: [DchSession]) -> [DchSession] {
        list.sorted {
            let c = $0.title.localizedStandardCompare($1.title)
            return c == .orderedSame ? $0.name < $1.name : c == .orderedAscending
        }
    }

    /// Settings key and default for the sidekick name pattern.
    static let sidekickKey = "sidekickPattern"
    static let sidekickDefault = "-qa"

    /// Splits `list` into primary sessions and sidekicks: a sidekick's real `name` or its
    /// alias contains `pattern`, case-insensitive (sidekicks are often named by renaming). An
    /// empty pattern turns the split off. Order is kept.
    static func split(_ list: [DchSession], pattern: String) -> (primary: [DchSession], sidekicks: [DchSession]) {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return (list, []) }
        let isSidekick = { (s: DchSession) in [s.name, s.alias ?? ""].contains { $0.range(of: p, options: .caseInsensitive) != nil } }
        return (list.filter { !isSidekick($0) }, list.filter(isSidekick))
    }

    /// Whether the Sidekicks list shows: never without sidekicks, always when they are all
    /// there is (an empty Sessions tab reads as a Mac with no sessions), else the chosen tab.
    static func showsSidekicks(_ split: (primary: [DchSession], sidekicks: [DchSession]), tab: Bool) -> Bool {
        !split.sidekicks.isEmpty && (tab || split.primary.isEmpty)
    }
}

extension SessionVerb {
    /// #589: an error alert's title. A named row's verb is "Resume failed", "Restart failed",
    /// "Stop failed"; an all-run's is the action itself, as the island labels it ("Resume
    /// interrupted", "Restart all"), over the Mac's summary ("2 resumed, 1 failed").
    func failTitle(all: Bool) -> String {
        switch self {
        case .history: "History"
        case .revive:  all ? "Resume interrupted" : "Resume failed"
        case .restart: all ? "Restart all" : "Restart failed"
        case .stop:    all ? "Stop all" : "Stop failed"
        }
    }
}

extension DchHistoryRow {
    var title: String { alias ?? name }

    /// #589: the island's end words (#585); nothing the user did on purpose reads as a crash.
    /// "closed" (dch -k), "exited" / "exited (N)", "ended (signal N)" for TERM, HUP and INT,
    /// "crashed (signal N)" for any other signal, "vanished" ("" too); else as dch wrote it.
    static func endLabel(_ end: String) -> String {
        switch end {
        case "", "vanished": return "vanished"
        case "killed": return "closed"
        case "exit 0": return "exited"
        case "signal 15", "signal 1", "signal 2": return "ended (\(end))"
        default:
            if end.hasPrefix("signal ") { return "crashed (\(end))" }
            if end.hasPrefix("exit ") { return "exited (\(end.dropFirst(5)))" }
            return end
        }
    }

    /// #589: "Resume interrupted (N)", N the records dch's revive-all takes; nil (no button) at 0.
    static func resumeAllLabel(_ rows: [DchHistoryRow]) -> String? {
        let n = rows.filter(\.takes).count
        return n > 0 ? "Resume interrupted (\(n))" : nil
    }
}

/// #589: the Mac's History tab (Agent Island): ended sessions, newest first, each with
/// Resume (on `.revive`), and Resume interrupted over them. As on the Mac, neither asks
/// first nor opens the session: the resumed one shows up in the list. After every reply,
/// an error too, the history reloads and `changed` re-lists the sessions.
struct HistorySheet: View {
    let transport: SessionTransport
    let canRevive: Bool
    let changed: () async -> Void
    @State private var rows: [DchHistoryRow]?
    @State private var error: String?              // the history read's, as written (dch too old)
    // Names resuming; "" is Resume interrupted. ponytail: lost when the sheet closes (the
    // revive still runs and the list still re-lists); lift into SessionListView if it matters.
    @State private var running: Set<String> = []
    @State private var failed: (title: String, message: String)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                } else if let rows, rows.isEmpty {
                    Text("No ended sessions.").foregroundStyle(.secondary)
                } else if rows == nil {
                    ProgressView()
                }
                if canRevive, let rows {
                    if running.contains("") {
                        HStack(spacing: 10) { ProgressView(); Text("Resuming…").foregroundStyle(.secondary) }
                    } else if let label = DchHistoryRow.resumeAllLabel(rows) {
                        Button(label) { resume(nil) }
                            .accessibilityHint("Brings back the sessions that ended abnormally in the last 3 days")
                    }
                }
                ForEach(rows ?? [], id: \.name) { r in row(r) }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { await reload() }
            .refreshable { await reload() }
            .alert(failed?.title ?? "", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failed?.message ?? "") }
        }
    }

    private func row(_ r: DchHistoryRow) -> some View {
        let end = DchHistoryRow.endLabel(r.end)
        let seen = r.lastSeen > 0
            ? Date(timeIntervalSince1970: TimeInterval(r.lastSeen)).formatted(.relative(presentation: .named)) : nil
        let ran = Duration.seconds(r.runtime)
            .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).lineLimit(1)
                // #585: only a crash is coloured, the island's orange.
                (Text(end).foregroundColor(end.hasPrefix("crashed") ? .orange : .secondary)
                    + Text([seen, "ran \(ran)"].compactMap { $0 }.map { " · \($0)" }.joined()).foregroundColor(.secondary))
                    .font(.caption).lineLimit(1)
                if let cwd = r.cwd, !cwd.isEmpty {
                    Text(cwd).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if running.contains(r.name) {
                HStack(spacing: 6) { ProgressView(); Text("Resuming…").font(.caption).foregroundStyle(.secondary) }
            } else if canRevive {
                Button("Resume") { resume(r.name) }.buttonStyle(.borderless)
            }
        }
    }

    /// A record's Resume, or Resume interrupted (nil). Minutes, at worst: the row shows
    /// "Resuming…" meanwhile and every other row stays free.
    private func resume(_ name: String?) {
        let key = name ?? ""
        running.insert(key)
        let t = transport
        Task {
            if let f = await Self.resume(name, on: t) { failed = f }
            running.remove(key)
            await reload()
            await changed()
        }
    }

    /// One revive: a record's `{"name"}`, or `{"all":true}` for nil. nil when it went
    /// through, else its alert ("Resume failed" for a name, "Resume interrupted" for all).
    static func resume(_ name: String?, on t: SessionTransport) async -> (title: String, message: String)? {
        await SessionListView.attempt(SessionVerb.revive.failTitle(all: name == nil), on: t) { try await $0.revive(name: name) }
    }

    private func reload() async {
        do {
            rows = try await transport.history()
            error = nil
        } catch let e {
            if !isCancellation(e) { error = e.localizedDescription }
        }
    }
}

/// Small "remote-wake ready" chip shown on machine rows (picker + session header).
/// Renders only when wake is known-enabled; the minutes come from the cached battery
/// cadence we inferred from `/wake/:id/meta` (falls back to the AC cadence).
struct WakeBadge: View {
    let wake: WakeInfo?
    var body: some View {
        if let w = wake, w.enabled {
            let secs = w.intervalBatt ?? w.intervalAC
            HStack(spacing: 3) {
                Image(systemName: "sunrise.fill")
                Text(secs.map { "\(max(1, $0 / 60)) min" } ?? "Wake")
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .accessibilityLabel(secs.map { "Remote wake ready, checks every \($0 / 60) minutes" } ?? "Remote wake ready")
        }
    }
}

/// Stand-in transport (PLAN §12: build UI before the server exists).
final class MockTransport: SessionTransport {
    func listSessions() async throws -> [DchSession] {
        [DchSession(name: "prosper-main", alias: nil),
         DchSession(name: "bookplay-main", alias: "Bookplay")]
    }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream {
        throw TransportError.notConnected
    }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
        throw TransportError.notConnected
    }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}
