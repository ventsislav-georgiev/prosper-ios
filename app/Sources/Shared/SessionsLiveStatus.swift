import SwiftUI

/// One Mac's agents as the Live Activity shows them, pushed by the Prosper Worker (contract
/// v1). Names and states only, never terminal text, and no timestamps: freshness is the
/// push's stale date, which the card reads as `isStale`.
///
/// Decoded leniently, because a push that fails to decode is a card that silently stops
/// updating: unknown keys are ignored, a newer `v` still reads, a missing value or one of
/// the wrong type reads as its default (no alias, no agents, zero, no sessions), and an
/// unknown state reads as idle.
struct SessionsStatus: Codable, Hashable {
    struct Counts: Codable, Hashable {
        var blocked = 0, working = 0, idle = 0, done = 0
    }

    struct Session: Codable, Hashable {
        var name: String
        var alias: String?
        var state: SessionStateStyle
        var agents: Int?

        /// The session list's label: alias, else the dch name.
        var title: String { alias.flatMap { $0.isEmpty ? nil : $0 } ?? name }
    }

    var v = 1
    var online = true
    var counts = Counts()
    /// At most 6, already sorted by urgency by the Worker.
    var sessions: [Session] = []
    /// Sessions beyond `sessions`.
    var more = 0
}

extension SessionsStatus {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = c.lenient(.v) ?? 1
        online = c.lenient(.online) ?? true
        counts = c.lenient(.counts) ?? Counts()
        sessions = c.lenient(.sessions) ?? []
        more = c.lenient(.more) ?? 0
    }
}

extension SessionsStatus.Counts {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocked = c.lenient(.blocked) ?? 0
        working = c.lenient(.working) ?? 0
        idle = c.lenient(.idle) ?? 0
        done = c.lenient(.done) ?? 0
    }
}

extension SessionsStatus.Session {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)   // none: the card lists no sessions
        alias = c.lenient(.alias)
        state = SessionStateStyle(c.lenient(.state)) ?? .idle
        agents = c.lenient(.agents)
    }
}

private extension KeyedDecodingContainer {
    /// The value, or nil when it is missing or of the wrong type.
    func lenient<T: Decodable>(_ key: Key) -> T? { (try? decodeIfPresent(T.self, forKey: key)) ?? nil }
}

extension SessionStateStyle: Codable {}

/// What the card says, kept out of the widget so the rules are testable: a stale card
/// says "status unavailable" and an offline Mac says so, and neither shows a session
/// state, since those would be old.
struct SessionsCard {
    let status: SessionsStatus
    let isStale: Bool

    /// Session rows are shown only while the feed is live.
    var live: Bool { !isStale && status.online }

    var headline: String {
        if isStale { return "status unavailable" }
        if !status.online { return "Mac offline" }
        let c = status.counts
        let parts = [(c.blocked, SessionStateStyle.blocked), (c.working, .working), (c.idle, .idle), (c.done, .done)]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1.label.lowercased())" }
        return parts.isEmpty ? "no sessions" : parts.joined(separator: " · ")
    }

    /// The most urgent state with a session in it, for the compact and minimal island.
    var lead: SessionStateStyle? {
        guard live else { return nil }
        let c = status.counts
        if c.blocked > 0 { return .blocked }
        if c.working > 0 { return .working }
        if c.idle > 0 { return .idle }
        return c.done > 0 ? .done : nil
    }

    var symbol: String {
        if isStale { return "questionmark.circle" }
        if !status.online { return "desktopcomputer" }
        return lead?.symbol ?? "circle"
    }

    var tint: Color { lead?.tint ?? .secondary }

    /// How many sessions are in the lead state.
    private var leadCount: Int {
        let c = status.counts
        switch lead {
        case .blocked: return c.blocked
        case .working: return c.working
        case .idle:    return c.idle
        case .done:    return c.done
        case nil:      return 0
        }
    }

    /// The compact island's trailing text: how many sessions are in the lead state.
    var compactText: String {
        if isStale { return "–" }
        if !status.online { return "offline" }
        return "\(leadCount)"
    }

    /// What VoiceOver reads for that count: "3 sessions need input", not a bare "3".
    var compactLabel: String {
        guard let lead else { return headline }
        let n = leadCount
        let state = lead != .blocked ? lead.label.lowercased() : n == 1 ? "needs input" : "need input"
        return "\(n) \(n == 1 ? "session" : "sessions") \(state)"
    }

    /// Up to `limit` sessions, and the "+N more" count for the rest.
    func rows(limit: Int) -> (sessions: [SessionsStatus.Session], more: Int) {
        guard live else { return ([], 0) }
        let shown = Array(status.sessions.prefix(limit))
        return (shown, status.sessions.count - shown.count + max(0, status.more))
    }

    /// The row's state and its subagents: "Working · +2 agents", or just "Working".
    static func detail(_ s: SessionsStatus.Session) -> String {
        [s.state.label, SessionStateStyle.agents(s.agents)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Where a tap on an alert or on the card should land: that Mac (by the info-frame
/// `device_id` the phone stores as `serverDeviceId`) and optionally one of its sessions.
/// No Mac means home.
struct LiveTarget: Equatable {
    var macId: String?
    var session: String?

    /// The alert push's `userInfo {mac_id, session, more}`. No Mac is home. `more > 0` is
    /// one alert for several blocked sessions ("a and 2 more need you"): it targets the
    /// Mac's session list, not its first session. A missing or non-integer `more` counts
    /// as a single alert.
    init(userInfo: [AnyHashable: Any]) {
        macId = (userInfo["mac_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let aggregate = ((userInfo["more"] as? Int) ?? 0) > 0
        session = macId == nil || aggregate ? nil : (userInfo["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether this alert banners with Prosper in front: always, unless it is about the
    /// one session on screen (an aggregate names no session, so it always banners).
    func banners(over attached: LiveTarget?) -> Bool {
        session == nil || self != attached
    }

    init(macId: String?, session: String? = nil) {
        self.macId = macId
        self.session = session
    }

    /// The card's link: `prosper://sessions?mac=<mac_id>`.
    static func url(macId: String) -> URL {
        var u = URLComponents()
        u.scheme = "prosper"
        u.host = "sessions"
        u.queryItems = [URLQueryItem(name: "mac", value: macId)]
        return u.url ?? URL(string: "prosper://sessions")!
    }

    /// nil for a URL that isn't the card's.
    init?(url: URL) {
        guard url.scheme == "prosper", url.host == "sessions" else { return nil }
        let mac = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "mac" }?.value
        self.init(macId: mac.flatMap { $0.isEmpty ? nil : $0 })
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

/// The Live Activity for one Mac. The type name is part of the contract: push-to-start
/// names it in `attributes-type`, so it must stay `ProsperSessionsAttributes`.
@available(iOS 16.1, *)
struct ProsperSessionsAttributes: ActivityAttributes {
    typealias ContentState = SessionsStatus

    var macId: String
    var macName: String

    enum CodingKeys: String, CodingKey {
        case macId = "mac_id"
        case macName = "mac_name"
    }
}
#endif
