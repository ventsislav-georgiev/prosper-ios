import SwiftUI
import CryptoKit

// MARK: - WakeClient (GET /wake/:id/meta gating + POST /wake/:id trigger, PLAN §4)

/// Outcome of reading a Mac's wake meta — the three states the gating UI branches on.
enum WakeMeta: Equatable {
    case enabled(intervalBatt: Int, batteryFloor: Int?)   // wakeable; floor=nil means no floor set
    case disabled                                          // set up but currently off
    case unknown                                           // never configured / no identity
}

enum WakeTriggerError: Error, LocalizedError {
    case unidentified            // 400 invalid_id
    case notLinked               // 403 forbidden
    case needsLogin              // 401 unauthorized
    case rateLimited             // 429
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unidentified: return "Couldn't identify this Mac."
        case .notLinked:    return "This Mac isn't linked to your account."
        case .needsLogin:   return "Please sign in again."
        case .rateLimited:  return "Too many wake attempts, wait a minute."
        case .server(let m): return m
        }
    }
}

struct WakeClient {
    var base = serverBaseURL
    let session: String

    /// `GET /wake/:id/meta`. `known:false` → `.unknown`; `enabled:false` → `.disabled`;
    /// `enabled:true` → `.enabled(intervalBatt)`. Network errors fall back to `.unknown`.
    func meta(wakeId: String) async -> WakeMeta {
        var req = URLRequest(url: base.appendingPathComponent("/wake/\(wakeId)/meta"))
        req.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unknown
        }
        return WakeClient.parseMeta(o)
    }

    /// Pure meta classifier — split out so it's unit-checkable without a network call.
    static func parseMeta(_ o: [String: Any]) -> WakeMeta {
        guard (o["known"] as? Bool) == true else { return .unknown }
        guard (o["enabled"] as? Bool) == true else { return .disabled }
        let batt = (o["intervalBatt"] as? Int) ?? 300
        let floor = o["batteryFloor"] as? Int
        return .enabled(intervalBatt: batt, batteryFloor: floor)
    }

    /// `POST /wake/:id` body "1". Maps the documented status codes (PLAN §4).
    func arm(wakeId: String) async throws {
        var req = URLRequest(url: base.appendingPathComponent("/wake/\(wakeId)"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data("1".utf8)
        let (_, resp): (Data, URLResponse)
        do { (_, resp) = try await URLSession.shared.data(for: req) }
        catch { throw WakeTriggerError.server(error.localizedDescription) }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return
        case 400: throw WakeTriggerError.unidentified
        case 401: throw WakeTriggerError.needsLogin
        case 403: throw WakeTriggerError.notLinked
        case 429: throw WakeTriggerError.rateLimited
        case let c: throw WakeTriggerError.server("Wake failed (\(c)).")
        }
    }
}

/// Slack added to the battery cadence for the ETA — covers the dark-wake poll landing
/// plus the daemon promoting + the network coming back (PLAN §4: intervalBatt + ~45s).
let wakeSlackSeconds = 45

/// Contract-pinning test fixture only — NOT a runtime path. wakeId always comes from the
/// handshake (server owns devTag; we can't derive it from email alone). Mirrors the
/// server's `acctTag`: SHA-256(trim+lowercase email) → lowercase hex, first 16 chars.
func wakeAcctTag(email: String) -> String {
    let digest = SHA256.hash(data: Data(email.trimmingCharacters(in: .whitespaces).lowercased().utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
}

// MARK: - Wake button / waking overlay

/// Drop-in failed-state UI for a Machine: gates on wake meta, offers a Wake button,
/// runs the waking countdown, and silently reconnects. `onConnected` fires when a TCP
/// connect succeeds during waking (the success signal) so the caller can resume.
struct WakeFailedView: View {
    let machine: Machine
    let message: String
    @ObservedObject var account: AccountStore
    let machines: MachineStore
    var onConnected: (ProsperTransport, String) -> Void

    @State private var meta: WakeMeta?            // nil = still loading
    @State private var deadline: Date?            // set while waking
    @State private var now = Date()
    @State private var error: String?
    @State private var showLogin = false
    @State private var waitTask: Task<Void, Never>?
    @State private var armedOnce = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            if let deadline {
                wakingBody(deadline: deadline)
            } else {
                gatingBody
            }
        }
        .padding(16)
        .frame(maxWidth: 340)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onReceive(timer) { now = $0 }
        .task { await loadMeta() }
        .onDisappear { waitTask?.cancel() }
        .sheet(isPresented: $showLogin) {
            LoginView(account: account) { Task { await triggerWake() } }
        }
    }

    // MARK: gating (PLAN §4 — three outcomes)

    @ViewBuilder private var gatingBody: some View {
        Label(message, systemImage: "exclamationmark.triangle").font(.callout)
        switch meta {
        case .enabled(let batt, let floor):
            let n = batt + wakeSlackSeconds
            Button { Task { await triggerWake() } } label: {
                Text("Wake \(machine.name)")
            }
            .buttonStyle(.borderedProminent)
            Text("Expected ~\(n) s").font(.caption).foregroundStyle(.secondary)
            if let floor {
                Text("May not wake if on battery below \(floor)%.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .disabled:
            Text("Remote wake isn't enabled on this Mac — turn it on in Prosper → Settings → Power.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case .unknown:
            Text("Connect once while the Mac is awake to enable remote wake.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case nil:
            ProgressView()
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
    }

    // MARK: waking (PLAN §4 — countdown + silent reconnect + timeout)

    @ViewBuilder private func wakingBody(deadline: Date) -> some View {
        let total = max(1, deadline.timeIntervalSince(armedAt))
        let elapsed = max(0, now.timeIntervalSince(armedAt))
        if now < deadline {
            let fraction = min(1, elapsed / total)
            let remaining = max(0, Int((total - elapsed).rounded()))
            ZStack {
                Circle().stroke(.orange.opacity(0.15), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(AngularGradient(colors: [.orange, .yellow, .orange], center: .center),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.9), value: fraction)
                VStack(spacing: 1) {
                    Image(systemName: "sunrise.fill").font(.title3).foregroundStyle(.orange)
                    Text("\(remaining)").font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                    Text("sec left").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 128, height: 128)
            .padding(.vertical, 4)
            Text("Waking \(machine.name)…").font(.headline)
            Text("Usually ready in ~\(Int(total.rounded())) s")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Cancel") { stopWaiting() }.font(.callout).padding(.top, 2)
        } else {
            Label("Still asleep.", systemImage: "moon.zzz").font(.headline)
            Text("It may be powered off, off the network, have remote wake disabled, or in deep standby (which can stretch the wake cadence several times over).")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Wake again") { Task { await triggerWake() } }   // fresh token
                    .buttonStyle(.borderedProminent)
                Button("Help") { stopWaiting() }
            }.font(.callout)
        }
    }

    // armedAt = deadline minus the computed window; derived so we don't store both.
    private var armedAt: Date {
        guard let deadline, case .enabled(let batt, _) = meta else { return now }
        return deadline.addingTimeInterval(-Double(batt + wakeSlackSeconds))
    }

    // MARK: actions

    private func loadMeta() async {
        // Signed in → authoritative server read; else fall back to the cached meta.
        if let session = account.session, let id = wakeId() {
            let live = await WakeClient(session: session).meta(wakeId: id)
            // Cache wins over .unknown: a TTL-expired server record doesn't mean wake is off —
            // it just means the Mac hasn't checked in recently. The cached enabled flag is the
            // stronger "was set up" signal. (Fix 3)
            if live == .unknown, let c = machine.cachedWake, c.enabled {
                meta = .enabled(intervalBatt: c.intervalBatt ?? 300, batteryFloor: nil)
            } else {
                meta = live
            }
        } else if let c = machine.cachedWake {
            meta = c.enabled ? .enabled(intervalBatt: c.intervalBatt ?? 300, batteryFloor: nil) : .disabled
        } else {
            meta = .unknown
        }
    }

    private func triggerWake() async {
        error = nil
        guard let session = account.session else { showLogin = true; return }
        guard let id = wakeId() else { error = WakeTriggerError.unidentified.localizedDescription; return }
        guard case .enabled(let batt, _) = meta else { return }
        do {
            try await WakeClient(session: session).arm(wakeId: id)
            let n = Double(batt + wakeSlackSeconds)
            deadline = Date().addingTimeInterval(n)
            startWaiting()
        } catch WakeTriggerError.needsLogin {
            // ponytail: drop in-memory session only — don't revoke/clear Keychain on a
            // possible clock-skew 401; user can explicitly sign out from Settings. (Fix 2)
            showLogin = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Silently retry the TCP connect every ~5s, walking the address priority list. The
    /// FIRST successful connect is the success signal (PLAN §4 — server never clears the
    /// wake token, so don't poll GET /wake). Stops at the deadline; onConnected fires
    /// even after timeout UI shows (a late wake is still a win).
    private func startWaiting() {
        waitTask?.cancel()
        let addresses = machine.addresses
        let dl = deadline
        waitTask = Task {
            while !Task.isCancelled, let dl {
                if let (t, addr) = try? await connectFirst(addresses) {
                    onConnected(t, addr)
                    return
                }
                let remaining = dl.timeIntervalSinceNow
                guard remaining > 0 else { break }
                let sleep = min(5.0, remaining)
                try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
            }
        }
    }

    private func stopWaiting() {
        waitTask?.cancel()
        deadline = nil
    }

    /// The handshake-supplied wakeId. A never-handshaked Mac has no wakeId (we can't
    /// know its devTag from the email alone), so this is nil and the gate stays
    /// `.unknown` — the "connect once while awake" hint. `wakeAcctTag` exists for
    /// callers that only need the ownership tag, not a full id.
    private func wakeId() -> String? { machine.wakeId }
}

#if DEBUG
/// ponytail: golden acctTag (must match the server's wakeId.mjs) + the meta classifier
/// — the two money paths (ownership derivation + gating branch).
func _wakeSelfCheck() {
    // Golden: matches Node `crypto.subtle.digest('SHA-256', utf8('a@b.com'))[:16 hex]`.
    assert(wakeAcctTag(email: "a@b.com") == "fb98d44ad7501a95")
    // Normalizes (trim+lowercase) before hashing — same id for messy input.
    assert(wakeAcctTag(email: "  A@B.COM ") == wakeAcctTag(email: "a@b.com"))

    // Meta classifier: the three gating states.
    assert(WakeClient.parseMeta(["known": false]) == .unknown)
    assert(WakeClient.parseMeta(["known": true, "enabled": false]) == .disabled)
    assert(WakeClient.parseMeta(["known": true, "enabled": true, "intervalBatt": 600])
           == .enabled(intervalBatt: 600, batteryFloor: nil))
    assert(WakeClient.parseMeta(["known": true, "enabled": true, "intervalBatt": 600, "batteryFloor": 20])
           == .enabled(intervalBatt: 600, batteryFloor: 20))
}
#endif
