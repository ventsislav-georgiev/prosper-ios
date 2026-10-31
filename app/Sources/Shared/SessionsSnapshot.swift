import Foundation
import WidgetKit

/// The Home Screen sessions widget's data (#611): one Mac's session list as the app last
/// listed it, written to the App Group on every list. The widget never dials the Mac, so
/// this is all it knows, and it shows how old it is.
struct SessionsSnapshot: Codable, Equatable {
    struct Row: Codable, Equatable {
        var name: String
        var title: String
        /// nil for an unknown state, or a Mac too old to send one.
        var state: SessionStateStyle?
    }

    var machine: UUID
    var mac: String
    var date = Date()
    var rows: [Row]

    /// `ShareInbox.group`: the widgets don't build Sources/Share.
    static let group = "group.eu.illegible.prosperios"
    /// Settable for tests.
    static var dir: () -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    private static let file = "sessions.json"

    /// Needs input first, then working, idle, done and unknown; by title within each, as
    /// the session list orders them.
    var ordered: [Row] {
        let rank = { (r: Row) in r.state.map { [.blocked, .working, .idle, .done].firstIndex(of: $0) ?? 4 } ?? 4 }
        return rows.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func link(_ row: Row) -> URL { Self.link(machine: machine, session: row.name) }

    static func read() -> SessionsSnapshot? {
        dir().flatMap { try? Data(contentsOf: $0.appendingPathComponent(file)) }
            .flatMap { try? JSONDecoder().decode(SessionsSnapshot.self, from: $0) }
    }

    /// Written, and the widget redrawn, only when the list moved or the age shown is a
    /// minute out: the session list polls every few seconds and reloads are budgeted.
    static func save(_ s: SessionsSnapshot) {
        if let old = read(), old.machine == s.machine, old.mac == s.mac, old.rows == s.rows,
           s.date.timeIntervalSince(old.date) < 60 { return }
        guard let url = dir()?.appendingPathComponent(file),
              (try? JSONEncoder().encode(s).write(to: url, options: .atomic)) != nil else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// `prosper://session?machine=<id>&name=<session>`: a widget row's tap and the intents' link.
    static func link(machine: UUID, session: String) -> URL {
        var u = URLComponents()
        u.scheme = "prosper"
        u.host = "session"
        u.queryItems = [URLQueryItem(name: "machine", value: machine.uuidString), URLQueryItem(name: "name", value: session)]
        return u.url ?? URL(string: "prosper://session")!
    }

    /// The Mac and session a `link` names; nil for another link.
    static func target(_ url: URL) -> (machine: UUID, session: String)? {
        guard url.scheme == "prosper", url.host == "session",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let machine = items.first(where: { $0.name == "machine" })?.value.flatMap(UUID.init(uuidString:)),
              let name = items.first(where: { $0.name == "name" })?.value, !name.isEmpty else { return nil }
        return (machine, name)
    }
}
