import SwiftUI

@main
struct ProsperApp: App {
    init() {
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
/// picker; `sessions` = the dch session list for a machine (id, or the demo sentinel);
/// `settings` = the account screen.
enum Route: Hashable {
    case connect
    case sessions(MachineRef)
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
    @State private var path: NavigationPath
    @State private var showHelp = false

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
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .connect:
                    ConnectScreen(store: store) { ref in go(.sessions(ref)) }
                case .sessions(let ref):
                    sessionList(for: ref)
                case .settings:
                    SettingsView(account: account)
                }
            }
        }
    }

    /// Pick a machine from the picker → collapse back to a single Home → Sessions level
    /// (so Back from the new session list returns Home, never machine→machine→…).
    private func go(_ route: Route) {
        path = NavigationPath()
        path.append(route)
    }

    @ViewBuilder private func sessionList(for ref: MachineRef) -> some View {
        // "Change" PUSHES the picker on top of Sessions (Home → Sessions → Machines),
        // so Back from Machines returns to Sessions — the expected hierarchy.
        switch ref {
        case .demo:
            SessionListView(transport: DemoTransport(), title: demoTitle, machine: nil,
                            store: store, account: account, onChangeMachine: { path.append(Route.connect) })
        case .machine(let id):
            if let m = store.machines.first(where: { $0.id == id }) {
                SessionListView(transport: ProsperTransport(host: m.addresses.first ?? m.name),
                                title: m.name, machine: m, store: store, account: account,
                                onChangeMachine: { path.append(Route.connect) })
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
    @State private var sessions: [DchSession] = []
    @State private var error: String?
    @State private var loading = false             // connect/list round-trip in flight
    @State private var unreachable: String?        // host-unreachable → offer Wake
    @State private var open: DchSession?          // programmatic push target
    @State private var renaming: DchSession?       // rename alert
    @State private var renameText = ""
    @State private var killing: DchSession?        // kill-confirm alert
    @State private var creating = false            // new-session alert
    @State private var newName = ""
    @State private var sleeping = false            // sleep round-trip in flight

    // Live store snapshot so the badge tracks cachedWake after handshake (the `machine`
    // prop is a stale value-type copy captured at navigation time).
    private var liveMachine: Machine? {
        guard let id = machine?.id else { return nil }
        return store.machines.first { $0.id == id }
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
                    Text("Connecting to \(title)…").foregroundStyle(.secondary)
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
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            }
            ForEach(sessions) { s in row(s) }
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
            Button { newName = ""; creating = true } label: { Image(systemName: "plus") }
                .disabled(sleeping || unreachable != nil || error != nil || loading)   // no new session on an unreachable Mac
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(sleeping || loading)
        }
        .task { await refresh() }
        // Programmatic push for tap-to-attach and newly created sessions.
        .navigationDestination(isPresented: Binding(get: { open != nil },
                                                    set: { if !$0 { open = nil } })) {
            if let open { TerminalScreen(transport: transport, session: open) }
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
        .alert("New session", isPresented: $creating) {
            TextField("Name (optional)", text: $newName)
            Button("Create") { startNew() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Opens a fresh dch session on \(title).") }
    }

    @ViewBuilder private func row(_ s: DchSession) -> some View {
        HStack(spacing: 16) {
            Text(s.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { open = s }
            Button { renaming = s; renameText = s.alias ?? "" } label: {
                Image(systemName: "pencil")
            }.buttonStyle(.borderless)
            Button(role: .destructive) { killing = s } label: {
                Image(systemName: "xmark.circle")
            }.buttonStyle(.borderless).foregroundStyle(.red)
        }
    }

    private func commitRename(_ alias: String) {
        guard let r = renaming else { return }
        let a = alias.trimmingCharacters(in: .whitespaces)
        Task { try? await transport.rename(name: r.name, alias: a.isEmpty ? nil : a); await refresh() }
        renaming = nil
    }

    private func startNew() {
        let typed = newName.trimmingCharacters(in: .whitespaces)
        // dch creates the session on first attach; a stable name keeps reconnects
        // pinned to it. Generate one when the user doesn't name it.
        let name = typed.isEmpty ? "ses-\(String(Int(Date().timeIntervalSince1970), radix: 36))" : typed
        newName = ""
        open = DchSession(name: name, alias: nil)
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
            let stream = try await withTimeout(seconds: 8) {
                try await transport.create(
                    name: nil, command: ["sh", "-c", "open prosper://sleep; exit 0;"], cols: 80, rows: 24)
            }
            stream.close()
            onChangeMachine()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Race `op` against a deadline so a hung connect can't leave the button
    /// spinning forever. Mirrors the connect timeout the transport applies per-frame.
    private func withTimeout<T>(seconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TransportError.hostUnreachable("timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func refresh() async {
        loading = true
        do {
            sessions = try await transport.listSessions()
            error = nil
            unreachable = nil
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
            self.error = error.localizedDescription
            unreachable = nil
        }
    }

    /// Opportunistic identity handshake (PLAN §3): send 0x08, and if a 0x18 reply lands
    /// within the timeout, overwrite the machine's serverDeviceId/wakeId (refresh, not
    /// first-write-wins) and refresh cachedWake from /meta when signed in. Legacy Macs
    /// never reply → left untouched.
    private func handshake() async {
        guard let m = machine, let t = transport as? ProsperTransport else { return }
        guard let info = try? await t.machineInfo() else { return }
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
