import SwiftUI

@main
struct ProsperApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

/// Navigation routes for the Remote Terminal feature. `connect` = the machine
/// picker; `sessions` = the dch session list for a given host.
enum Route: Hashable {
    case connect
    case sessions(String)
}

// MARK: - Host history (newline-joined string in @AppStorage, most-recent first)

func hostList(_ raw: String) -> [String] { raw.split(separator: "\n").map(String.init) }

func recordHost(_ h: String, into raw: Binding<String>) {
    let t = h.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return }
    var list = hostList(raw.wrappedValue).filter { $0 != t }
    list.insert(t, at: 0)
    raw.wrappedValue = list.joined(separator: "\n")
}

func removeHost(_ h: String, from raw: Binding<String>) {
    raw.wrappedValue = hostList(raw.wrappedValue).filter { $0 != h }.joined(separator: "\n")
}

/// App home. A list of Prosper features; tap one to open it. Remote Terminal
/// (the dch/dtach client over Tailscale) is the first and currently only one.
/// Tapping it jumps straight to the last machine's session list (auto-connect),
/// or the machine picker if there's no history yet.
struct HomeView: View {
    @AppStorage("hostHistory") private var historyRaw = ""
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: hostList(historyRaw).first.map(Route.sessions) ?? Route.connect) {
                    Label("Remote Terminal", systemImage: "terminal")
                }
            }
            .navigationTitle("Prosper")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .connect:
                    ConnectScreen(historyRaw: $historyRaw) { host in
                        recordHost(host, into: $historyRaw)
                        path.append(Route.sessions(host))
                    }
                case .sessions(let host):
                    SessionListView(transport: ProsperTransport(host: host), host: host)
                }
            }
        }
    }
}

/// Machine picker: type a new host or pick a previously-connected one. Each
/// remembered host has a delete button; tapping a host connects to it.
struct ConnectScreen: View {
    @Binding var historyRaw: String
    let onConnect: (String) -> Void
    @State private var newHost = ""

    var body: some View {
        List {
            Section("Connect to a machine") {
                TextField("my-mac.tailnet.ts.net or 100.x.y.z", text: $newHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Connect") { onConnect(newHost) }
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let hosts = hostList(historyRaw)
            if !hosts.isEmpty {
                Section("Recent") {
                    ForEach(hosts, id: \.self) { h in
                        HStack {
                            Button(h) { onConnect(h) }
                                .foregroundStyle(.primary)
                            Spacer()
                            Button { removeHost(h, from: $historyRaw) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Machines")
    }
}

struct SessionListView: View {
    let transport: SessionTransport
    let host: String
    @State private var sessions: [DchSession] = []
    @State private var error: String?
    @State private var open: DchSession?          // programmatic push target
    @State private var renaming: DchSession?       // rename alert
    @State private var renameText = ""
    @State private var killing: DchSession?        // kill-confirm alert
    @State private var creating = false            // new-session alert
    @State private var newName = ""

    var body: some View {
        List {
            // Machine row → back to the picker to switch/manage connections.
            NavigationLink(value: Route.connect) {
                HStack {
                    Image(systemName: "desktopcomputer")
                    Text(host).font(.headline)
                    Spacer()
                    Text("Change").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(sessions) { s in row(s) }
        }
        .navigationTitle("Sessions")
        .toolbar {
            Button { newName = ""; creating = true } label: { Image(systemName: "plus") }
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
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
        .alert("Kill \(killing?.title ?? "")?", isPresented: Binding(get: { killing != nil },
                                                                     set: { if !$0 { killing = nil } })) {
            Button("Kill", role: .destructive) {
                if let k = killing { Task { try? await transport.kill(name: k.name); await refresh() } }
                killing = nil
            }
            Button("Cancel", role: .cancel) { killing = nil }
        } message: { Text("Ends the session and its running program. Can't be undone.") }
        .alert("New session", isPresented: $creating) {
            TextField("Name (optional)", text: $newName)
            Button("Create") { startNew() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Opens a fresh dch session on \(host).") }
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

    private func refresh() async {
        do { sessions = try await transport.listSessions(); error = nil }
        catch { self.error = error.localizedDescription }
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
