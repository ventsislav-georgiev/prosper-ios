import Foundation
import SwiftUI

/// Identity reported by a Mac over the `0x08`/`0x18` handshake (PLAN §2a). Non-secret:
/// `wakeId` is only *actionable* with the owner's session (the server re-derives the
/// account tag from the authenticated email). `wakeId` is absent on Macs that have
/// never configured remote wake.
struct MachineInfo {
    let deviceId: String
    let hostname: String?
    let wakeId: String?
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

/// Try a machine's addresses in priority order; the first to connect wins (PLAN §3).
/// Returns a connected `ProsperTransport` and the address that worked, or throws the
/// last error if every address fails.
func connectFirst(_ addresses: [String]) async throws -> (ProsperTransport, String) {
    var lastError: Error = TransportError.hostUnreachable("no addresses")
    for addr in addresses {
        let t = ProsperTransport(host: addr)
        do {
            // listSessions does a full TCP round-trip, so a success proves reachability.
            _ = try await t.listSessions()
            return (t, addr)
        } catch {
            lastError = error
        }
    }
    throw lastError
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
