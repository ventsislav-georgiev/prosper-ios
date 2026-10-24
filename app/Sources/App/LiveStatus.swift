import Foundation
import OSLog
import Security
import SwiftUI
import UIKit
import UserNotifications
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

// Live session status by push (contract v1): the Prosper Worker holds the APNs key and
// pushes this phone a quiet Live Activity per Mac, plus a loud alert only when a session
// needs the user. The phone's part is handing the Worker its tokens and routing taps.

/// The APNs environment the tokens belong to: Debug builds are signed for the sandbox,
/// Release (TestFlight) for production.
enum PushEnv {
    static func name(debug: Bool) -> String { debug ? "sandbox" : "production" }
    #if DEBUG
    static let current = name(debug: true)
    #else
    static let current = name(debug: false)
    #endif
}

enum PushKind: String {
    case alert                         // the APNs device token
    case laStart = "la_start"          // Live Activity push-to-start (iOS 17.2+)
    case laUpdate = "la_update"        // one activity's update token
}

/// `POST`/`DELETE /push/tokens` on the account server, with the magic-link Bearer.
struct PushTokens {
    var base = serverBaseURL
    let session: String
    let deviceId: String
    var env = PushEnv.current
    /// Sends one request and returns the status code. Tests substitute it.
    var send: (URLRequest) async throws -> Int = { req in
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }
    /// Seconds before each try. A token lost to one dropped request is a card the Worker
    /// can't update, so network errors and 5xx get two more tries; a 4xx won't change.
    var retryDelays: [UInt64] = [0, 2, 6]
    /// Checked before every POST try: false once the switch is off, so a repost or a retry
    /// still under way can't hand the Worker a token after turnOff's DELETE.
    var live: @MainActor () -> Bool = { true }

    /// The Worker's checks, mirrored so a bad value fails here instead of as a 400: tokens
    /// are lowercase hex, 16-512 characters.
    static func isValidToken(_ t: String) -> Bool {
        (16...512).contains(t.count) && t.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// 1-128 characters of [A-Za-z0-9._:-]; `Activity.id` is a UUID string.
    static func isValidActivityId(_ s: String) -> Bool {
        (1...128).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }
    }

    /// `activity_id` and `mac_id` belong to `la_update` alone; the Worker refuses them on
    /// the other kinds, so they are never sent there.
    @discardableResult
    func post(_ kind: PushKind, token: String, activityId: String? = nil, macId: String? = nil) async -> Bool {
        guard Self.isValidToken(token) else { return false }
        var body = ["device_id": deviceId, "kind": kind.rawValue, "token": token, "env": env]
        if kind == .laUpdate {
            guard let activityId, Self.isValidActivityId(activityId), let macId, !macId.isEmpty else { return false }
            body["activity_id"] = activityId
            body["mac_id"] = macId
        }
        return await call("POST", body, while: live)
    }

    /// Without `kind`, every token of this device. A 404 means the Worker already dropped
    /// it (it clears a Mac's activity rows itself after an end), which is as good.
    @discardableResult
    func delete(_ kind: PushKind? = nil, activityId: String? = nil) async -> Bool {
        var body = ["device_id": deviceId]
        body["kind"] = kind?.rawValue
        if let activityId {
            guard Self.isValidActivityId(activityId) else { return false }
            body["activity_id"] = activityId
        }
        return await call("DELETE", body)
    }

    private func call(_ method: String, _ body: [String: String],
                      while live: @MainActor () -> Bool = { true }) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("/push/tokens"))
        req.httpMethod = method
        // Three tries at URLSession's 60 s default would stall sign-out for minutes.
        req.timeoutInterval = 10
        req.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        for delay in retryDelays {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
            guard await live() else { return false }
            guard let code = try? await send(req) else { continue }
            guard code < 500 else { continue }
            // A refusal is an answer, not a blip: a 403 on la_update is a Mac this account
            // hasn't activated, and that card just stales out to "status unavailable".
            if code >= 400 {
                Logger(subsystem: "eu.illegible.prosper", category: "push")
                    .error("\(method, privacy: .public) /push/tokens \(body["kind"] ?? "all", privacy: .public): \(code)")
            }
            return (200..<300).contains(code)
        }
        return false
    }
}

/// The last token per key (alert, la_start, la_update per activity), re-posted on every
/// foreground: the Worker keeps a few install ids per account and evicts the least
/// recently updated, so a resident app that posted once at launch would drop off.
/// Keyed, so one foreground posts each key once.
struct PushTokenCache {
    struct Entry: Equatable {
        let kind: PushKind
        let token: String
        var activityId: String? = nil
        var macId: String? = nil
    }

    private(set) var entries: [String: Entry] = [:]

    mutating func remember(_ e: Entry) { entries["\(e.kind.rawValue)/\(e.activityId ?? "")"] = e }
    mutating func forget(activityId: String) { entries["\(PushKind.laUpdate.rawValue)/\(activityId)"] = nil }
    mutating func clear() { entries = [:] }

    func repost(_ client: PushTokens) async {
        for e in entries.values {
            await client.post(e.kind, token: e.token, activityId: e.activityId, macId: e.macId)
        }
    }
}

/// This install's `device_id` for the Worker: a UUID kept in the Keychain per account,
/// readable after first unlock (a push-started activity hands over its token while the
/// phone is locked) and never synced off the device.
enum InstallID {
    static func isValid(_ s: String) -> Bool {
        (8...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    static func key(email: String) -> String {
        "install-id/" + email.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func get(email: String,
                    load: (String) -> String? = PushKeychain.load,
                    save: (String, String) -> Void = PushKeychain.save) -> String {
        let k = key(email: email)
        if let id = load(k), isValid(id) { return id }
        let id = UUID().uuidString
        save(id, k)
        return id
    }
}

enum PushKeychain {
    private static let service = "eu.illegible.prosperios.push"

    static func load(_ account: String) -> String? {
        var item: CFTypeRef?
        guard SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, _ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

extension LiveTarget {
    /// The saved machine the push names, matched on the Mac's info-frame device id.
    func machine(in machines: [Machine]) -> Machine? {
        guard let macId else { return nil }
        return machines.first { $0.serverDeviceId == macId }
    }

    /// Where the tap lands: that Mac's session list, opening the session once listed; nil
    /// is home. Every call is a new route (`tap`), so a second tap for the same place
    /// still navigates after the user moved away by hand.
    func route(in machines: [Machine]) -> Route? {
        machine(in: machines).map { .sessions(.machine($0.id), open: session, tap: UUID()) }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// The phone side of live status: the switch, the tokens, and where a tap goes.
///
/// Tokens are posted on every launch (the device token comes back from
/// `registerForRemoteNotifications`, the activity sequences replay the current token) and
/// re-posted from `cache` on every foreground, so one that failed to post heals then.
@MainActor
final class LiveStatus: ObservableObject {
    static let shared = LiveStatus()

    static let enabledKey = "liveStatus.enabled"
    private static let askedKey = "liveStatus.asked"

    private let defaults: UserDefaults
    /// The "Live status and alerts" switch.
    @Published private(set) var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    /// The Turn On / Not now card was answered; it never comes back after Not now.
    @Published private(set) var asked: Bool {
        didSet { defaults.set(asked, forKey: Self.askedKey) }
    }
    /// Live Activities allowed for Prosper in the Settings app, as of the last foreground.
    @Published private(set) var activitiesAllowed = true
    /// A tapped alert or card waiting for Home to route it.
    @Published var target: LiveTarget?
    /// The session open on screen, so its own alert doesn't banner over it.
    var attached: LiveTarget?

    private var observers: [Task<Void, Never>] = []
    private var tracked: Set<String> = []
    private(set) var cache = PushTokenCache()
    private var reposting = false
    private let signedIn: () -> PushTokens?
    private let notificationsAllowed: () async -> Bool

    /// Tests substitute the defaults, the client and the permission check.
    init(defaults: UserDefaults = .standard,
         client: @escaping () -> PushTokens? = {
             Keychain.load().map { PushTokens(session: $0.session, deviceId: InstallID.get(email: $0.email)) }
         },
         notificationsAllowed: @escaping () async -> Bool = {
             await UNUserNotificationCenter.current().notificationSettings().authorizationStatus != .denied
         }) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        asked = defaults.bool(forKey: Self.askedKey)
        signedIn = client
        self.notificationsAllowed = notificationsAllowed
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in await LiveStatus.shared.foreground() }
        }
    }

    /// Re-post every cached token, once per key; a foreground while one is in flight
    /// adds nothing. Notifications turned off in the Settings app turn the switch off,
    /// so the Worker forgets this device.
    func foreground() async {
        guard enabled, !reposting, let client = client() else { return }
        reposting = true
        defer { reposting = false }
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 16.1, *) { activitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled }
        #endif
        guard await notificationsAllowed() else { return await turnOff() }
        await cache.repost(client)
    }

    /// From the app delegate at launch, and after Turn On.
    func launch() {
        guard enabled, Keychain.load() != nil else { return }
        UIApplication.shared.registerForRemoteNotifications()
        observeActivities()
    }

    /// Ask for permission and, if given, start handing the Worker tokens.
    @discardableResult
    func turnOn() async -> Bool {
        asked = true
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        enabled = true
        launch()
        return true
    }

    func notNow() { asked = true }

    /// The switch off: the Worker forgets this device, and no card stays behind.
    func turnOff() async {
        enabled = false
        // ponytail: a DELETE that fails all its tries leaves the Worker alerting until the
        // tokens go invalid; persist a pending delete if that shows up.
        if let client = client() { await client.delete() }
        await stop()
    }

    /// Sign-out, while the Bearer still works: tokens first, then the cards. Asks again
    /// on the next sign-in if it was on.
    func signOut(session: String, email: String) async {
        await PushTokens(session: session, deviceId: InstallID.get(email: email)).delete()
        if enabled { asked = false }
        enabled = false
        await stop()
    }

    func alertToken(_ token: Data) {
        Task { await post(.alert, token: token.hex) }
    }

    private func client() -> PushTokens? {
        guard var c = signedIn() else { return nil }
        c.live = { [weak self] in self?.enabled == true }
        return c
    }

    func post(_ kind: PushKind, token: String, activityId: String? = nil, macId: String? = nil) async {
        guard enabled, let client = client() else { return }
        cache.remember(.init(kind: kind, token: token, activityId: activityId, macId: macId))
        await client.post(kind, token: token, activityId: activityId, macId: macId)
    }

    private func observeActivities() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard observers.isEmpty else { return }
        if #available(iOS 17.2, *) {
            observers.append(Task {
                for await token in Activity<ProsperSessionsAttributes>.pushToStartTokenUpdates {
                    await post(.laStart, token: token.hex)
                }
            })
        }
        if #available(iOS 16.2, *) {
            Activity<ProsperSessionsAttributes>.activities.forEach(track)
            observers.append(Task {
                for await activity in Activity<ProsperSessionsAttributes>.activityUpdates { track(activity) }
            })
        }
        #endif
    }

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    /// Hand the Worker this activity's update token (and every rotation of it); take it
    /// back when the activity ends.
    @available(iOS 16.2, *)
    private func track(_ activity: Activity<ProsperSessionsAttributes>) {
        guard tracked.insert(activity.id).inserted else { return }
        let id = activity.id, mac = activity.attributes.macId
        observers.append(Task {
            for await token in activity.pushTokenUpdates {
                await post(.laUpdate, token: token.hex, activityId: id, macId: mac)
            }
        })
        observers.append(Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                await ended(id)
                return
            }
        })
    }
    #endif

    /// An ended card's token: no more reposts, and the Worker drops it.
    func ended(_ id: String) async {
        tracked.remove(id)
        cache.forget(activityId: id)
        if let client = client() { await client.delete(.laUpdate, activityId: id) }
    }

    private func stop() async {
        observers.forEach { $0.cancel() }
        observers = []
        tracked = []
        cache.clear()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 16.2, *) {
            for a in Activity<ProsperSessionsAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        }
        #endif
    }
}

/// The device-token callbacks and the notification delegate, which SwiftUI has no hook for.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        LiveStatus.shared.launch()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        LiveStatus.shared.alertToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// "Needs you" banners even with Prosper open, except over the session it's about.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let target = LiveTarget(userInfo: notification.request.content.userInfo)
        let onScreen = await MainActor.run { LiveStatus.shared.attached }
        return target.banners(over: onScreen) ? [.banner, .list, .sound] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let target = LiveTarget(userInfo: response.notification.request.content.userInfo)
        await MainActor.run { LiveStatus.shared.target = target }
    }
}
