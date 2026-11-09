import Combine   // MachineStore's @Published; no SwiftUI, so the keyboards don't link it (#735)
import Foundation
import OSLog

/// Identity reported by a Mac over the `0x08`/`0x18` handshake (PLAN §2a). Non-secret:
/// `wakeId` is only *actionable* with the owner's session (the server re-derives the
/// account tag from the authenticated email). `wakeId` is absent on Macs that have
/// never configured remote wake.
struct MachineInfo {
    let deviceId: String
    let hostname: String?
    let wakeId: String?
    var ops: Set<SessionVerb> = []   // #590: empty from an older Mac
    // #779: protocol 1.0's keys, each nil from a pre-#776 Prosper.
    var server: String? = nil   // "prosper" or "dch"
    var os: String? = nil       // "macOS 27.0", "Linux 6.8"
    var name: String? = nil     // the host's display name
    var proto: String? = nil    // "<major>.<minor>"; nil is 1.0

    /// #779: the newest protocol major this app speaks; a host on a newer one is refused.
    static let protoMajor = 1

    /// #779: `proto`'s major: "<major>.<minor>", both decimal. nil when it isn't that shape.
    static func major(_ proto: String) -> Int? {
        let parts = proto.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }) else { return nil }
        return Int(parts[0])
    }

    /// #779: false for a host on a newer major. Missing or unreadable reads as 1.0.
    static func supports(_ proto: String?) -> Bool {
        (proto.flatMap(major) ?? 1) <= protoMajor
    }
}

/// Cached remote-wake state for a Machine, mirrored from `GET /wake/:id/meta`
/// (PLAN §4). Kept on the Machine so the gating UI can decide whether to offer a
/// Wake button even before (or without) a fresh signed-in meta fetch.
struct WakeInfo: Codable, Equatable {
    var enabled: Bool
    var intervalAC: Int?
    var intervalBatt: Int?
}

/// A saved machine (PLAN §3): a display name plus an ordered, priority-ranked list of
/// addresses (any IP / domain / MagicDNS). Identity fields are filled opportunistically
/// from the handshake and overwritten on every successful connect (not first-write-wins),
/// so a re-keyed Mac self-heals.
struct Machine: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var addresses: [String]
    var serverDeviceId: String?
    var wakeId: String?
    var cachedWake: WakeInfo?
    /// #614: the handshake listed `library`; nil before one, or from an older Mac.
    var offersLibrary: Bool?
    // #779: from the handshake, as `serverDeviceId`; nil before one, or from an older Prosper.
    var server: String?
    var os: String?
    var hostName: String?   // the host's `name`, else its `hostname`
    var proto: String?

    /// #779: what the Machines screen and the session list call it: the name the user gave it
    /// (#628), or the host's own name when they gave none (blank, or an address: migrated ones).
    var label: String { name.isEmpty || addresses.contains(name) ? hostName ?? name : name }

    /// #779: "Linux 6.8 · dch" under a dch host; nil for Prosper.
    var osLine: String? { server == "dch" ? [os, "dch"].compactMap { $0 }.joined(separator: " · ") : nil }

    /// A handshake's identity, overwriting the last one. An absent wakeId keeps the old one (wake
    /// off, not configured), except on a dch host, which has no wake (#779). A host on a newer
    /// protocol offers no library.
    mutating func adopt(_ info: MachineInfo) {
        serverDeviceId = info.deviceId
        if let w = info.wakeId { wakeId = w } else if info.server == "dch" { wakeId = nil; cachedWake = nil }
        offersLibrary = MachineInfo.supports(info.proto) && info.ops.contains(.library)
        server = info.server
        os = info.os
        hostName = info.name ?? info.hostname
        proto = info.proto
    }
}

/// Persisted list of Machines (PLAN §3). Replaces the old newline `hostHistory`
/// string; migrates those entries into single-address Machines on first launch.
@MainActor
final class MachineStore: ObservableObject {
    @Published var machines: [Machine] { didSet { persist() } }

    private let key = "machines.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Machine].self, from: data) {
            machines = decoded
        } else {
            // One-time migration: fold the old newline-joined hostHistory into
            // single-address Machines (name == address). ponytail: read-and-drop the
            // legacy key so the migration runs exactly once.
            machines = MachineStore.migrate(hostHistory: defaults.string(forKey: "hostHistory"))
            defaults.removeObject(forKey: "hostHistory")
            persist()
        }
    }

    /// Build single-address Machines from a legacy newline hostHistory string.
    nonisolated static func migrate(hostHistory raw: String?) -> [Machine] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Machine(name: $0, addresses: [$0]) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(machines) { defaults.set(data, forKey: key) }
    }

    func add(_ m: Machine) { machines.append(m) }

    func remove(_ m: Machine) { machines.removeAll { $0.id == m.id } }

    /// Overwrite identity + cached wake for a machine after a handshake (PLAN §3:
    /// refresh-overwrite, not first-write-wins). No-op if the machine is gone.
    func update(_ id: UUID, _ body: (inout Machine) -> Void) {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return }
        body(&machines[i])
    }
}

/// Per-address deadline when walking a machine's addresses. A Mac that is asleep, off
/// the tailnet, or behind a stale LAN address does not refuse the connection — it says
/// nothing at all, so without a deadline the FIRST address swallows the whole attempt
/// and the rest are never tried.
let addressAttemptTimeout: TimeInterval = 5

/// Race `op` against a deadline. Used per address, so one dead address costs 5s, not the
/// whole connect.
func withDeadline<T>(seconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
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

/// True for the errors that mean "we walked away", not "it failed": leaving a screen
/// cancels its `.task`, and a cancelled deadline race throws `CancellationError`. Never
/// worth showing — a user who pressed Back has already been told what happened.
func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

/// Try `addresses` in priority order, each with its own `timeout`; the first to answer
/// wins (PLAN §3). `onTry` fires with each address as it is dialed, so the caller can
/// show which one is being attempted. Throws the last error when every address fails.
///
/// `probe` decides what "connected" means and is what the tests substitute; the shipping
/// callers use `connectFirstTransport`, which probes with a real round-trip.
func connectFirst<T>(_ addresses: [String], timeout: TimeInterval = addressAttemptTimeout,
                     onTry: @escaping @MainActor (String) -> Void = { _ in },
                     probe: @escaping (String) async throws -> T) async throws -> (T, String) {
    var lastError: Error = TransportError.hostUnreachable("no addresses")
    for addr in addresses where !addr.trimmingCharacters(in: .whitespaces).isEmpty {
        // Cancelled means the caller left the screen: stop dialing instead of walking the
        // remaining addresses on nobody's behalf, and report the cancel rather than the
        // timeout it caused.
        try Task.checkCancellation()
        await onTry(addr)
        do {
            return (try await withDeadline(seconds: timeout) { try await probe(addr) }, addr)
        } catch {
            // #827: a refusal is the host's answer; the next address reaches the same host.
            if isCancellation(error) || (error as? TransportError)?.isRefusal == true { throw error }
            Logger(subsystem: "eu.illegible.prosper", category: "transport")
                .error("\(addr, privacy: .public) failed: \(error, privacy: .public)")   // #801: the UI shows only the label
            lastError = error
        }
    }
    throw lastError
}

/// Walk a machine's addresses and return the transport that answered, the address it
/// answered on, and the session list that proved it — a full round-trip, so nothing
/// downstream has to re-prove reachability.
func connectFirstTransport(_ addresses: [String], timeout: TimeInterval = addressAttemptTimeout,
                           onTry: @escaping @MainActor (String) -> Void = { _ in })
    async throws -> (transport: ProsperTransport, address: String, sessions: [DchSession]) {
    let ((t, sessions), addr) = try await connectFirst(addresses, timeout: timeout, onTry: onTry) { addr in
        let t = ProsperTransport(host: addr)
        return (t, try await t.listSessions())
    }
    return (t, addr, sessions)
}

#if DEBUG
/// ponytail: one runnable check for the JSON round-trip + the hostHistory migration —
/// the only non-trivial logic here (persistence correctness + a one-shot migration).
func _machineSelfCheck() {
    // Migration: newline string → single-address machines, blanks dropped, order kept.
    let migrated = MachineStore.migrate(hostHistory: "mac-a\n\nmac-b \n")
    assert(migrated.count == 2)
    assert(migrated[0].name == "mac-a" && migrated[0].addresses == ["mac-a"])
    assert(migrated[1].name == "mac-b" && migrated[1].addresses == ["mac-b"])
    assert(MachineStore.migrate(hostHistory: nil).isEmpty)
    assert(MachineStore.migrate(hostHistory: "").isEmpty)

    // Codable round-trip preserves every field incl. nested WakeInfo.
    let m = Machine(name: "Studio", addresses: ["100.1.2.3", "studio.ts.net"],
                    serverDeviceId: "dev-xyz", wakeId: "abc123-studio",
                    cachedWake: WakeInfo(enabled: true, intervalAC: 300, intervalBatt: 600))
    let data = try! JSONEncoder().encode([m])
    let back = try! JSONDecoder().decode([Machine].self, from: data)
    assert(back == [m])
}
#endif
