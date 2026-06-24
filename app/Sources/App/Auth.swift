import Foundation
import Security

/// Prosper account server. Only the remote-wake feature touches it — the terminal and
/// demo work fully signed-out (PLAN: login is optional).
let serverBaseURL = URL(string: "https://prosper.illegible.eu")!

// MARK: - AuthClient (passwordless magic-link, PLAN §3 / server auth.ts)

enum AuthError: Error, LocalizedError {
    case expired                 // pickup TTL elapsed (poll 410) — resend the link
    case invalidEmail
    case rateLimited
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .expired:       return "That link expired. Send a new one."
        case .invalidEmail:  return "Enter a valid email address."
        case .rateLimited:   return "Too many attempts. Wait a few minutes."
        case .server(let m): return m
        case .network(let m): return m
        }
    }
}

/// Credentials handed back on a completed login. `session` is the opaque Bearer used
/// for every authed request (server stores its hash); `token` is the one-time magic
/// verify token and is NOT persisted.
struct AuthSession { let session: String; let email: String }

struct AuthClient {
    var base = serverBaseURL

    /// Step 1: submit email → server emails a link, returns a `pickup` id to poll.
    func start(email: String) async throws -> String {
        let (data, code) = try await post("/auth/start", json: ["email": email])
        switch code {
        case 200:
            guard let pickup = (json(data)?["pickup"] as? String) else {
                throw AuthError.server("Malformed server response.")
            }
            return pickup
        case 400: throw AuthError.invalidEmail
        case 429: throw AuthError.rateLimited
        default:  throw AuthError.server("Couldn't start sign-in (\(code)).")
        }
    }

    /// Step 2: poll until the link is opened. `pending` → keep polling; `410` → expired.
    func poll(pickup: String) async throws -> AuthSession? {
        let (data, code) = try await post("/auth/poll", json: ["pickup": pickup])
        if code == 410 { throw AuthError.expired }
        guard code == 200, let o = json(data) else {
            throw AuthError.server("Couldn't complete sign-in (\(code)).")
        }
        guard (o["status"] as? String) == "ready" else { return nil }   // pending
        guard let session = o["session"] as? String, let email = o["email"] as? String else {
            throw AuthError.server("Malformed credentials.")
        }
        return AuthSession(session: session, email: email)
    }

    /// Revoke this session server-side (so a leaked Bearer can't outlive sign-out).
    func logout(session: String) async throws {
        _ = try await post("/auth/logout", json: nil, bearer: session)
    }

    // MARK: helpers

    private func post(_ path: String, json body: [String: Any]?, bearer: String? = nil)
        async throws -> (Data, Int) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
    }

    private func json(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

// MARK: - Keychain (the session Bearer + email, this-device-only)

/// Minimal Keychain store for the one credential we keep. WhenUnlockedThisDeviceOnly:
/// never syncs to iCloud, unreadable while locked.
enum Keychain {
    private static let service = "eu.illegible.prosperios.account"
    private static let account = "session"

    struct Stored: Codable { var email: String; var session: String }

    static func save(_ s: Stored) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Stored? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

// MARK: - AccountStore (signed-in state + authed request credential)

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var email: String?
    @Published private(set) var session: String?

    private let client = AuthClient()

    var isSignedIn: Bool { session != nil }

    init() {
        if let s = Keychain.load() { email = s.email; session = s.session }
    }

    /// Adopt fresh credentials (from a completed login) and persist them.
    func adopt(_ s: AuthSession) {
        email = s.email
        session = s.session
        Keychain.save(.init(email: s.email, session: s.session))
    }

    /// Revoke server-side, await it, THEN clear local state (PLAN §3: don't drop the
    /// Keychain until the server confirms — a half-done sign-out leaves a live session).
    func signOut() async {
        if let s = session { try? await client.logout(session: s) }
        clearLocal()
    }

    /// Delete the account server-side; only clear the Keychain on success so a failed
    /// call leaves the user signed in to retry (PLAN §6.3 / Apple 5.1.1(v)).
    func deleteAccount() async throws {
        guard let s = session else { clearLocal(); return }
        var req = URLRequest(url: serverBaseURL.appendingPathComponent("/account/delete"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw AuthError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = o?["error"] as? String
            throw AuthError.server("Couldn't delete account (\(msg ?? String(code))).")
        }
        clearLocal()
    }

    private func clearLocal() {
        email = nil
        session = nil
        Keychain.clear()
    }
}
