import Foundation

/// What the keyboards did with each space, for a device run of the double-space shortcut:
/// timings and the kinds of characters around the caret, never the characters. A ring of
/// `cap` lines in the App Group (`KeyboardSettings.store`), read by Settings' Double-Space Log.
///
/// ponytail: temporary, for #540's device run. Remove it, its Settings page and its
/// `TerminalKeyboard.spaceLog` calls once the double space is diagnosed.
enum DoubleSpaceLog {
    static let key = "keyboard.doubleSpaceLog"
    static let cap = 60

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// `line` stamped with the wall clock, the oldest dropped past `cap`. Nil is no store:
    /// nothing is written.
    static func add(_ line: String, to store: UserDefaults?, at date: Date = Date()) {
        guard let store else { return }
        let all = (store.stringArray(forKey: key) ?? []) + [clock.string(from: date) + " " + line]
        store.set(Array(all.suffix(cap)), forKey: key)
    }

    /// Newest first.
    static func lines(in store: UserDefaults?) -> [String] {
        (store?.stringArray(forKey: key) ?? []).reversed()
    }

    static func clear(_ store: UserDefaults?) { store?.removeObject(forKey: key) }

    /// The last three characters' kinds: L letter or digit, S space, N newline,
    /// P punctuation or an ASCII symbol, E anything else (emoji). "nil" for no context,
    /// "-" for an empty one. Never a character itself.
    static func shape(_ text: String?) -> String {
        guard let text else { return "nil" }
        if text.isEmpty { return "-" }
        return String(text.suffix(3).map { c -> Character in
            if c == " " { return "S" }
            if c.isNewline { return "N" }
            if (c.isLetter || c.isNumber) && !c.unicodeScalars.contains("\u{FE0F}") { return "L" }
            if c.isPunctuation || (c.isSymbol && c.isASCII) { return "P" }
            return "E"
        })
    }

    /// A typed key's kind, as `spaceDoubles` reads it: L letter or digit, S space, O other.
    static func kind(_ key: TerminalKeyboard.Key) -> String {
        switch key {
        case .space: return "S"
        case .char(let c) where c.first.map { $0.isLetter || $0.isNumber } == true: return "L"
        default: return "O"
        }
    }
}
