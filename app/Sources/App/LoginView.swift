import SwiftUI

/// Magic-link login sheet (PLAN §3). Enter email → "Send magic link" → poll with a
/// spinner + Cancel → on 410 offer resend. On success it adopts the credentials into
/// `AccountStore` and calls `onSignedIn` (used by the Wake flow to continue inline).
struct LoginView: View {
    @ObservedObject var account: AccountStore
    var onSignedIn: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var phase: Phase = .entry
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?

    private enum Phase: Equatable { case entry, sending, waiting, expired }
    private let client = AuthClient()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Sign in to use Remote Wake — we email a one-time link, no password. The terminal and demo work without signing in.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    TextField("you@example.com", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .disabled(phase == .sending || phase == .waiting)
                } header: { Text("Email") }

                if let error { Section { Text(error).foregroundStyle(.red).font(.callout) } }

                Section { actionRow }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { cancel(); dismiss() }
                }
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder private var actionRow: some View {
        switch phase {
        case .entry, .sending:
            Button {
                Task { await sendLink() }
            } label: {
                HStack {
                    Text("Send magic link")
                    if phase == .sending { Spacer(); ProgressView() }
                }
            }
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || phase == .sending)

        case .waiting:
            HStack {
                ProgressView()
                Text("Open the link in your email…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { cancel() }
            }

        case .expired:
            VStack(alignment: .leading, spacing: 8) {
                Text("That link expired before it was opened.").font(.callout)
                Button("Resend link") { Task { await sendLink() } }
            }
        }
    }

    private func sendLink() async {
        error = nil
        phase = .sending
        do {
            let pickup = try await client.start(email: email.trimmingCharacters(in: .whitespaces))
            phase = .waiting
            startPolling(pickup: pickup)
        } catch {
            phase = .entry
            self.error = error.localizedDescription
        }
    }

    private func startPolling(pickup: String) {
        pollTask?.cancel()
        pollTask = Task {
            // Poll every ~2s until ready, expired, or cancelled.
            while !Task.isCancelled {
                do {
                    if let s = try await client.poll(pickup: pickup) {
                        account.adopt(s)
                        onSignedIn()
                        dismiss()
                        return
                    }
                } catch AuthError.expired {
                    phase = .expired
                    return
                } catch {
                    self.error = error.localizedDescription
                    phase = .entry
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func cancel() {
        pollTask?.cancel()
        if phase == .waiting { phase = .entry }
    }
}
