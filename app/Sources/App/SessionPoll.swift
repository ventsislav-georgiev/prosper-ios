import Foundation

/// The session list's state poll while the app is in front. One small list round-trip;
/// the answer refreshes the visible rows, and it is the only thing keeping the
/// working/idle labels honest.
enum SessionPoll {
    /// How often the list asks the Mac for states — so this doubles as how stale a row
    /// can look.
    static let interval: TimeInterval = 3
    /// After a failed poll, back off — an asleep Mac shouldn't be dialed every 3s.
    static let failureBackoff: TimeInterval = 20
}
