import SwiftUI

@main
struct ProsperApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

/// App home. A list of Prosper features; tap one to open it. Remote Terminal
/// (the dch/dtach client over Tailscale) is the first and currently only one.
struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    RemoteTerminalView()
                } label: {
                    Label("Remote Terminal", systemImage: "terminal")
                }
            }
            .navigationTitle("Prosper")
        }
    }
}

/// Remote Terminal entry → session list. Host or IP of the Prosper dch-server
/// (Tailscale MagicDNS name or raw IP). No auth — Tailscale is the trust boundary.
struct RemoteTerminalView: View {
    @AppStorage("lastHost") private var host = ""
    @State private var connected = false

    var body: some View {
        Form {
            Section("Host") {
                TextField("my-mac.tailnet.ts.net or 100.x.y.z", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Connect") { connected = true }
                    .disabled(host.isEmpty)
            }
        }
        .navigationTitle("Remote Terminal")
        .navigationDestination(isPresented: $connected) {
            SessionListView(transport: ProsperTransport(host: host), host: host)
        }
    }
}

struct SessionListView: View {
    let transport: SessionTransport
    let host: String
    @State private var sessions: [DchSession] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(sessions) { s in
                NavigationLink(s.title) { TerminalScreen(transport: transport, session: s) }
            }
        }
        .navigationTitle(host)
        .toolbar {
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .task { await refresh() }
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
}
