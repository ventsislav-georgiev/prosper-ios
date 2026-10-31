import AppIntents
import Foundation

/// The link an App Intent opens Prosper on (#611). The intents run in the app
/// (`openAppWhenRun`), so they only hand it to `HomeView`, which takes it as it takes
/// `onOpenURL`; on a cold launch it waits here until Home appears.
@MainActor
final class IntentLink: ObservableObject {
    static let shared = IntentLink()
    @Published var url: URL?

    /// Where the intents hand their link. Settable for tests: the test host's Home would
    /// take it and dial the Mac or start the mic.
    static var open: (URL) -> Void = { shared.url = $0 }

    /// The session last opened in the app (`ShareInbox.last`), looked up by the app: the
    /// widgets, which also build this file for the controls, can't read it.
    nonisolated static let last = URL(string: "prosper://last")!

    /// `Dictation.url`: the widgets don't build Sources/Keys.
    static func dictate() -> URL { URL(string: "prosper://dictate?id=\(UUID().uuidString)")! }
}

/// The keyboard mic key's link (#598) as a Shortcut, a Control Center control and an
/// Action Button choice: Prosper, listening.
struct DictateIntent: AppIntent {
    static var title: LocalizedStringResource = "Dictate"
    static var description = IntentDescription("Opens Prosper listening, as the Prosper keyboard's mic key does.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        IntentLink.open(IntentLink.dictate())
        return .result()
    }
}

/// The session last opened in Prosper, as a control and an Action Button choice.
struct OpenLastSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Last Session"
    static var description = IntentDescription("Opens the session you last had open in Prosper.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        IntentLink.open(IntentLink.last)
        return .result()
    }
}
