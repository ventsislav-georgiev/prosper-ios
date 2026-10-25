import UIKit
import UniformTypeIdentifiers

/// What the Prosper keyboard suggests in other apps, and the autocorrect, undo and
/// learning behind it: a stand-in for iOS's QuickType bar, which a custom keyboard
/// doesn't get. `SuggestionBar` draws it and wires it into the keyboard; the terminal
/// never has one, so none of this runs in the app.
///
/// The text before the cursor (`documentContextBeforeInput`) is the source of truth,
/// not the keyboard's tracked word: the host can move the cursor or change the text.
///
/// - Slots, best in the middle like iOS. While a word is typed: the typed word in
///   quotes when it's a word (or no word's start), then completions, then guesses. A
///   pending correction: “typed”, the correction (highlighted: space applies it), the
///   next completion or guess. At a word start: next-word predictions (`TypingMemory`).
/// - Autocorrect: a separator (space, return, `. , ? ! : ;`) after a word with a
///   pending correction (`correction(for:after:in:)`) replaces the word first; "." waits
///   for the space after it, as "jane.doe" or "example.com" go on past it. Only a word
///   this keyboard typed whole (`typed`): never a paste, nor text the cursor was put after.
/// - Undo: backspace as the very next key puts the typed word back, and it isn't
///   corrected again while this keyboard lives.
/// - Learning: tapping the quoted word keeps it and learns it; committed words feed the
///   next-word counts. Neither happens where autocorrect is off (`autocorrects`).
/// - Paste: at a word start, a fresh text clip replaces the slots (`offersPaste`).
///
/// The dictionary and the neighboring keys are the keyboard's `layout`'s: English, or
/// Bulgarian in the Bulgarian extension, where a checker without Bulgarian leaves only the
/// typed word, learned words, names and text replacements.
@MainActor
final class Suggestions {
    struct Slot: Equatable {
        /// What a tap types (and space, when `highlighted`).
        var word: String
        /// The typed word, kept as typed, drawn in quotes: a tap learns it.
        var quoted = false
        /// What space will put in place of the typed word.
        var highlighted = false
    }

    enum State: Equatable {
        /// Three slots, left to right; nil is blank.
        case slots([Slot?])
        /// A login field: one key button toward Apple's keyboard, for AutoFill and SMS codes.
        case autofill
        /// A word start with a fresh text clip: one Paste button.
        case paste
    }

    /// Punctuation that ends a word, so autocorrect runs first. Space and return too.
    static let separators: Set<String> = [".", ",", "?", "!", ":", ";"]

    let memory: TypingMemory
    /// Contact names from the supplementary lexicon: lowercase → as written.
    private(set) var names: [String: String] = [:]
    /// Text replacements from the supplementary lexicon: lowercase shortcut → phrase.
    private(set) var replacements: [String: String] = [:]
    /// Words whose autocorrect the user undid, lowercase: left alone from then on.
    private var rejected: Set<String> = []
    /// The last autocorrect while backspace can still undo it: the typed word, what stayed
    /// after it ("." for a correction deferred to the space), and what replaced the two plus
    /// the separator.
    private var undo: (typed: String, kept: String, inserted: String)?
    /// What this keyboard typed since the last paste or slot tap, lowercase, as `willPress`
    /// saw each key: the end of the text before the cursor, while nothing else changed it.
    /// Compared with that text, not trusted: hosts don't reliably report a cursor move.
    ///
    /// ponytail: the last 64 characters only: more isn't worth it.
    private var typed = ""
    /// The current word's first letter took auto-capitalization's shift, not the user's:
    /// rule N (`best`) reads the word lowercase. Set at the word's first letter (`willPress`),
    /// in a sentences field only: a words field capitalizes names too ("Jane Rkn" is Ron).
    private var autoCapital = false

    /// The pasteboard to offer, nil without Full Access: a custom keyboard reads it only
    /// with Full Access. The controller's, or a named one in tests.
    var pasteboard: () -> UIPasteboard? = { nil }
    /// False in a compact vertical size class, set by the bar (`SuggestionBar.refresh`): the
    /// secure control draws blank and takes no taps under about 36 pt, so landscape keeps its
    /// slots (OQ-43). A letter typed there doesn't retire the clip: Paste never showed.
    var pasteFits = true
    /// The app's Keyboard settings (Auto-Correction, Predictive Text): the extension's
    /// controller sets them when it appears.
    var settings = KeyboardSettings()

    let layout: TerminalKeyboard.Layout
    /// The layout's checker language, read once (`TerminalKeyboard.Layout.language`).
    let language: String?

    init(memory: TypingMemory = TypingMemory(), layout: TerminalKeyboard.Layout = .english) {
        self.memory = memory
        self.layout = layout
        language = layout.language
    }

    /// The supplementary lexicon (`UILexicon.entries`). Both sides equal: a name from
    /// Contacts. Different: a text replacement, shortcut → phrase. Entries that aren't one
    /// word of letters (multi-word names, "@@" shortcuts) never match a typed word: skipped.
    func load(_ entries: [(userInput: String, documentText: String)]) {
        for e in entries where Self.isWord(e.userInput) {
            if e.userInput == e.documentText {
                names[e.userInput.lowercased()] = e.documentText
            } else {
                replacements[e.userInput.lowercased()] = e.documentText
            }
        }
    }

    /// Lowercase words touch correction should treat as known: learned ones and names.
    var personalWords: Set<String> { memory.known.union(names.keys) }

    // MARK: - The bar

    func state(_ doc: UITextDocumentProxy, shift: ShiftState.Mode) -> State {
        if Self.isLoginField(doc) { return .autofill }
        if offersPaste(doc) { return .paste }
        if !settings.predictiveText { return .slots([nil, nil, nil]) }
        let before = doc.documentContextBeforeInput ?? ""
        let word = Self.currentWord(before)
        if word.isEmpty {
            let words = memory.predict(after: Self.previousWord(before)).map { w -> String in
                let w = display(w)
                switch shift {
                case .off: return w
                case .once: return w.prefix(1).uppercased() + w.dropFirst()
                case .locked: return w.uppercased()
                }
            }
            return .slots(Self.centered(words.map { Slot(word: $0) }))
        }
        let lower = word.lowercased()
        let fix = correction(for: word, after: String(before.dropLast(word.count)), in: doc)
        let known = knows(word)
        // Completions while the word can still become one, then the dictionary's guesses.
        // A prefix with a pending correction ("hel") shows the correction highlighted all
        // the same: the highlight is always what space will do.
        let completions = personal(prefix: lower) + Self.completions(lower, language: language)
        var seen: Set<String> = [lower, fix?.lowercased() ?? ""]
        let others = (completions + (completions.count < 3 ? Self.guesses(lower, language: language) : []))
            .map { shift == .locked ? $0.uppercased() : Self.matchCase($0, to: word) }
            .filter { seen.insert($0.lowercased()).inserted }
            .map { Slot(word: $0) }
        let typed = Slot(word: word, quoted: true)
        if let fix { return .slots([typed, Slot(word: fix, highlighted: true), others.first]) }
        if known || completions.isEmpty { return .slots([typed, others.first, others.dropFirst().first]) }
        return .slots(Self.centered(others))
    }

    /// Best in the middle, like iOS: second, first, third.
    static func centered(_ s: [Slot]) -> [Slot?] {
        [s.count > 1 ? s[1] : nil, s.first, s.count > 2 ? s[2] : nil]
    }

    /// A slot tapped: the word before the cursor becomes the slot's, then a space, like
    /// iOS. The quoted typed word stays as typed and is learned, where learning is allowed.
    func tap(_ slot: Slot, in doc: UITextDocumentProxy) {
        undo = nil
        typed = ""
        let before = doc.documentContextBeforeInput ?? ""
        let word = Self.currentWord(before)
        if slot.quoted {
            if !word.isEmpty, Self.autocorrects(doc), !knows(word) { memory.learn(word) }
            doc.insertText(" ")
        } else {
            for _ in 0..<word.count { doc.deleteBackward() }
            doc.insertText(slot.word + " ")
        }
        commit(slot.quoted ? word : slot.word, after: String(before.dropLast(word.count)), in: doc)
    }

    // MARK: - Paste

    /// A word start (an empty field, or after a space or newline: not "abc1", "mail@" or
    /// "alex.", where the next key would retire it unseen), and a clip with text the
    /// keyboard hasn't pasted or seen dismissed (`TypingMemory.retiredClip`). `hasStrings`
    /// and `changeCount` don't read the clip, so they raise no Allow Paste prompt. Just
    /// "Paste": iOS gives a keyboard no source app to name. Image-only clips never show:
    /// `insertText` takes only text.
    ///
    /// ponytail: no preview of the clip, since one means reading it unasked; add one only
    /// if a device shows no Allow Paste prompt for a Full Access keyboard.
    func offersPaste(_ doc: UITextDocumentProxy) -> Bool {
        guard pasteFits, let pb = pasteboard(),
              doc.documentContextBeforeInput?.last?.isWhitespace ?? true, pb.hasStrings else { return false }
        return pb.changeCount != memory.retiredClip
    }

    /// The Paste control delivered `clip`: it goes in as is, no space after (it may end
    /// mid-word or in a newline), and won't be offered again. The keyboard never reads it.
    func paste(_ clip: String, in doc: UITextDocumentProxy) {
        undo = nil
        typed = ""
        doc.insertText(clip)
        memory.retiredClip = pasteboard()?.changeCount
    }

    // MARK: - Typing

    /// The keyboard's trackpad moved the caret: what's before it now isn't what this
    /// keyboard typed, and backspace no longer undoes the last autocorrect.
    func caretMoved() {
        undo = nil
        typed = ""
    }

    /// The keyboard's hook before each key (`TerminalKeyboard.willPress`). A separator
    /// autocorrects the word it ends and records it; backspace right after an autocorrect
    /// undoes it and returns true: the keyboard then types nothing itself.
    func willPress(_ key: TerminalKeyboard.Key, in doc: UITextDocumentProxy, autoShift: Bool = false) -> Bool {
        let separator: String
        switch key {
        case .shift, .globe, .emoji: return false
        case .backspace:
            if revert(doc) { return true }
            _ = typed.popLast()
            return false
        case .space: separator = " "
        case .ret: separator = "\n"
        case .char(let c) where Self.separators.contains(c): separator = c
        case .char(let c):
            // Typing over the Paste button dismisses that clip for good.
            if offersPaste(doc) { memory.retiredClip = pasteboard()?.changeCount }
            if Self.currentWord(doc.documentContextBeforeInput).isEmpty {
                autoCapital = autoShift && doc.autocapitalizationType == .sentences
            }
            type(c)
            return false   // breaks the undo's suffix (`revert`)
        }
        undo = nil
        defer { type(separator) }
        // "." waits: a space after "word." corrects the word and keeps the ".", unless the
        // fix ends a sentence itself with . ! ? or … ("omw." → "On my way!").
        if separator == "." { return false }
        let before = doc.documentContextBeforeInput ?? ""
        var word = Self.currentWord(before), kept = ""
        if word.isEmpty, separator == " ", before.last == "." {
            kept = "."
            word = Self.currentWord(String(before.dropLast()))
        }
        guard !word.isEmpty else { return false }
        let prefix = String(before.dropLast(word.count + kept.count))
        var committed = word
        if let fix = correction(for: word, after: prefix, in: doc) {
            let tail = fix.last.map { ".!?…".contains($0) } == true ? "" : kept
            for _ in 0..<(word.count + kept.count) { doc.deleteBackward() }
            doc.insertText(fix + tail)
            undo = (word, kept, fix + tail + separator)
            typed = String(typed.dropLast(word.count + kept.count)) + (fix + tail).lowercased()
            committed = fix
        }
        commit(committed, after: prefix, in: doc)
        return false
    }

    /// Backspace right after an autocorrect: the correction and its separator give way to
    /// the typed word, cursor after it. Only while the text still ends with them, so any
    /// key typed since (or the host, or a cursor move) ends the chance.
    private func revert(_ doc: UITextDocumentProxy) -> Bool {
        guard let u = undo else { return false }
        undo = nil
        guard (doc.documentContextBeforeInput ?? "").hasSuffix(u.inserted) else { return false }
        for _ in 0..<u.inserted.count { doc.deleteBackward() }
        doc.insertText(u.typed + u.kept)
        typed = String(typed.dropLast(u.inserted.count)) + (u.typed + u.kept).lowercased()
        rejected.insert(u.typed.lowercased())
        return true
    }

    /// A key's text joins `typed`.
    private func type(_ s: String) {
        typed += s.lowercased()
        if typed.count > 64 { typed.removeFirst(typed.count - 64) }
    }

    /// A word went in: count it after the word before it, where learning is allowed.
    private func commit(_ word: String, after before: String, in doc: UITextDocumentProxy) {
        guard Self.autocorrects(doc), Self.isWord(word) else { return }
        memory.record(Self.previousWord(before), word)
    }

    // MARK: - Correction

    /// What a separator typed now puts in place of `word`, which follows `prefix`; nil
    /// leaves it. Only with Auto-Correction on, where the field autocorrects, for a word
    /// this keyboard typed whole (all after `prefix` ends `typed`), and never mid-word
    /// (letters after the cursor) or glued to what's before it (`glued`). A reverted word stays; "i" and its
    /// contractions get their capital; a text replacement shortcut gives its phrase;
    /// otherwise the dictionary's guess nearest on the keyboard (`best`), for a word nothing
    /// knows (`knows`). Anything less sure stays as typed, though the bar still offers the guesses.
    func correction(for word: String, after prefix: String, in doc: UITextDocumentProxy) -> String? {
        guard settings.autoCorrection, !word.isEmpty, Self.autocorrects(doc), !Self.glued(prefix),
              typed.hasSuffix((doc.documentContextBeforeInput ?? "").dropFirst(prefix.count).lowercased()),
              doc.documentContextAfterInput?.first?.isLetter != true else { return nil }
        let lower = word.lowercased()
        if rejected.contains(lower) { return nil }
        // The checker spells "i" fine (case-only guesses are dropped): iOS capitalizes it.
        if word.first == "i", ["i", "i'm", "i'll", "i've", "i'd"].contains(lower.replacingOccurrences(of: "’", with: "'")) {
            return "I" + word.dropFirst()
        }
        if let phrase = replacements[lower] { return phrase }
        // Rule N: a capital only auto-capitalization put first is lowercase ("Rkn" → "Run").
        let ruled = autoCapital && word.dropFirst() == lower.dropFirst() ? lower : word
        guard !knows(word), let guess = Self.best(Self.guesses(lower, language: language), for: ruled,
                                                  rows: layout.letterRows) else { return nil }
        return Self.matchCase(guess, to: word)
    }

    /// The confidence rule, kept conservative: at least 2 letters, letters and apostrophes
    /// only, not camelCase ("iPhone" is deliberate), the same first letter unless the guess
    /// is as long and starts on a neighboring key ("rhe" → "the"; a guess one letter shorter
    /// or longer is another word: "iphone" isn't "phone"), and the guess at most 2 edits away
    /// (1 for a word of 3 letters or fewer, where 2 edits make another word: "cat"/"dog").
    /// Which of the confident guesses wins is `best`'s.
    static func confident(_ word: String, guess: String) -> Bool {
        isConfident(word, guess: guess, rows: TerminalKeyboard.Layout.english.letterRows)
    }

    /// `confident` on a layout's `letterRows`. Named apart: an overload would make the
    /// unapplied `Suggestions.confident` ambiguous.
    static func isConfident(_ word: String, guess: String, rows: [[Character]]) -> Bool {
        guard isWord(word), word.filter(\.isLetter).count >= 2,
              !zip(word, word.dropFirst()).contains(where: { $0.isLowercase && $1.isUppercase }),
              let a = word.lowercased().first, let b = guess.lowercased().first,
              a == b || (word.count == guess.count && neighbors(a, b, rows: rows)) else { return false }
        return editDistance(word.lowercased(), guess.lowercased()) <= (word.count <= 3 ? 1 : 2)
    }

    /// Two letter keys at most one row and one place in their row apart (rows unstaggered).
    static func neighbors(_ a: Character, _ b: Character,
                          rows: [[Character]] = TerminalKeyboard.Layout.english.letterRows) -> Bool {
        func spot(_ c: Character) -> (row: Int, col: Int)? {
            guard let r = rows.firstIndex(where: { $0.contains(c) }) else { return nil }
            return (r, rows[r].firstIndex(of: c)!)
        }
        guard let p = spot(a), let q = spot(b) else { return false }
        return abs(p.row - q.row) <= 1 && abs(p.col - q.col) <= 1
    }

    /// The word is one the user would mind changing: the dictionary has it (as typed or
    /// lowercase), or it's a `ShellWords` word, a learned word or a contact name.
    func knows(_ word: String) -> Bool {
        let lower = word.lowercased()
        return memory.known.contains(lower) || names[lower] != nil || ShellWords.all.contains(lower)
            || Self.spelled(lower, language: language) || Self.spelled(word, language: language)
    }

    /// Of the checker's first 3 `guesses` for `word`, the `isConfident` one fewest keys away
    /// (`keyDistance`): "tge" is "the" (h is g's neighbor) before "toe". Ties keep the
    /// checker's order; past the third, a rare word one slip away would beat its right first
    /// guess ("hese" → "Hess", not "here"). None unless the first is confident: a first
    /// guess that drops a letter ("iphone" → "phone") says the word is deliberate.
    /// Rule N: a word typed lowercase takes a capitalized guess only first: "rkn" is "run",
    /// not "Ron". A sentence start's auto-capital counts as lowercase (`correction` passes
    /// the word lowercased); a capital the user shifted doesn't: "Rkn" is "Ron".
    ///
    /// ponytail: no frequency weighting; the checker's order is the only tie-break.
    static func best(_ guesses: [String], for word: String, rows: [[Character]]) -> String? {
        guard let first = guesses.first, isConfident(word, guess: first, rows: rows) else { return nil }
        let lower = word.lowercased()
        let rest = guesses.prefix(3).dropFirst().filter { word != lower || $0.first?.isUppercase != true }
        return ([first] + rest).filter { isConfident(word, guess: $0, rows: rows) }
            .min { keyDistance(lower, $0.lowercased(), rows: rows) < keyDistance(lower, $1.lowercased(), rows: rows) }
    }

    /// Edits from `a` to `b`: insert, delete, substitute, and swapping two neighbors
    /// counts one ("teh" → "the", the commonest typo). Optimal string alignment, the
    /// restricted Damerau-Levenshtein.
    static func editDistance(_ a: String, _ b: String) -> Int {
        distance(a, b, edit: 1) { _, _ in 1 }
    }

    /// `editDistance` where only a slip to a neighboring key (`neighbors`) is one
    /// substitution: any other letter for a letter costs two, a delete and an insert.
    static func keyDistance(_ a: String, _ b: String, rows: [[Character]]) -> Int {
        distance(a, b, edit: 1) { neighbors($0, $1, rows: rows) ? 1 : 2 }
    }

    private static func distance(_ a: String, _ b: String, edit: Int,
                                 substitution: (Character, Character) -> Int) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return edit * max(a.count, b.count) }
        var d = (0...a.count).map { i in (0...b.count).map { j in edit * (i == 0 ? j : j == 0 ? i : 0) } }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i - 1][j] + edit, d[i][j - 1] + edit,
                              d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : substitution(a[i - 1], b[j - 1])))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + edit)
                }
            }
        }
        return d[a.count][b.count]
    }

    // MARK: - Fields

    /// A login field iOS hands a custom keyboard (secure ones it swaps for its own):
    /// username, one-time code, or a non-secure password. The bar offers Apple's keyboard
    /// for AutoFill instead of suggestions; nothing is corrected or learned.
    static func isLoginField(_ doc: UITextDocumentProxy) -> Bool {
        if doc.isSecureTextEntry == true { return true }
        guard let type = doc.textContentType ?? nil else { return false }
        return [.username, .oneTimeCode, .password, .newPassword].contains(type)
    }

    /// Whether the field lets the keyboard rewrite and learn what's typed: it doesn't turn
    /// off autocorrection or spell checking (`.default` counts as on), it isn't a login
    /// field, and its value isn't prose (`TerminalKeyboard.isValueField`).
    static func autocorrects(_ doc: UITextDocumentProxy) -> Bool {
        !isLoginField(doc) && doc.autocorrectionType != .no && doc.spellCheckingType != .no
            && !TerminalKeyboard.isValueField(doc.keyboardType ?? .default)
    }

    // MARK: - Words

    /// A letter run glued to a digit or to `@ # _ / .` ("2nd", "@handle", "jane.doe",
    /// "example.com/path") is part of a token, not a word: never corrected. Safari's stale
    /// traits after a field switch make this the only guard in email and URL fields there.
    static func glued(_ prefix: String) -> Bool {
        guard let c = prefix.last else { return false }
        return c.isNumber || "@#_/.".contains(c)
    }

    /// The word the cursor ends: the trailing letters and apostrophes, less any leading
    /// apostrophe (an opening quote). "" after a space, a digit or punctuation.
    static func currentWord(_ text: String?) -> String {
        let run = (text ?? "").reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        return String(String(run.reversed()).drop { $0 == "'" || $0 == "’" })
    }

    /// The word before the spaces that end `text`, lowercase; "" when the field, a line or
    /// punctuation comes first, so a sentence's first word follows "", the start.
    static func previousWord(_ text: String) -> String {
        currentWord(String(text.reversed().drop { $0 == " " }.reversed())).lowercased()
    }

    static func isWord(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" }
    }

    /// `suggestion` in the typed word's case: all caps (2+ letters) → all caps, a capital
    /// first letter → capitalized, else as the dictionary has it ("I", names).
    static func matchCase(_ suggestion: String, to typed: String) -> String {
        if typed.filter(\.isLetter).count > 1, typed == typed.uppercased() { return suggestion.uppercased() }
        if typed.first?.isUppercase == true { return suggestion.prefix(1).uppercased() + suggestion.dropFirst() }
        return suggestion
    }

    /// A recorded word (lowercase) as it's written: a contact's name as in Contacts, "I"
    /// and its contractions capitalized.
    private func display(_ w: String) -> String {
        if let name = names[w] { return name }
        return w == "i" || w.hasPrefix("i'") ? "I" + w.dropFirst() : w
    }

    /// One learned word or contact name that continues `prefix`, the shortest, to lead the
    /// dictionary's completions: the user's own words beat the dictionary's first guess.
    private func personal(prefix: String) -> [String] {
        let words = memory.known.filter { $0.hasPrefix(prefix) && $0 != prefix }.map { $0 }
            + names.filter { $0.key.hasPrefix(prefix) && $0.key != prefix }.map(\.value)
        return words.min { ($0.count, $0) < ($1.count, $1) }.map { [$0] } ?? []
    }

    // MARK: - Dictionary

    /// The dictionary in `language` (English by default) has `s` as a word.
    static func spelled(_ s: String, language: String? = TerminalKeyboard.language) -> Bool {
        guard let language else { return false }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return TerminalKeyboard.checker.rangeOfMisspelledWord(in: s, range: range, startingAt: 0, wrap: false,
                                                              language: language).location == NSNotFound
    }

    /// Words that continue `prefix`, most likely first. Shell words never: they're known
    /// (never corrected), but prose doesn't want them offered.
    static func completions(_ prefix: String, language: String? = TerminalKeyboard.language) -> [String] {
        guard let language else { return [] }
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        return (TerminalKeyboard.checker.completions(forPartialWordRange: range, in: prefix, language: language) ?? [])
            .filter(isWord)
    }

    /// The dictionary's corrections for a misspelled `word`, best first: single words only.
    static func guesses(_ word: String, language: String? = TerminalKeyboard.language) -> [String] {
        guard let language else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        return (TerminalKeyboard.checker.guesses(forWordRange: range, in: word, language: language) ?? [])
            .filter { isWord($0) && $0.lowercased() != word.lowercased() }
    }
}

/// What the keyboard learns from its user, in the extension's own `UserDefaults` (no App
/// Group: the app never reads it): words kept as typed, and how often one word followed
/// another, for next-word predictions. Lowercase throughout; never written where the
/// field turns autocorrect off (`Suggestions.autocorrects`), so not from password-like
/// fields.
///
/// ponytail: iOS's own language model isn't available to a custom keyboard, so the
/// predictions come only from what the user typed with this keyboard: blank on day one,
/// never seeded from anything else. Caps: `wordCap` learned words (the oldest go) and
/// `pairCap` pairs (the rarest go, down to 90% so the sort runs once per few hundred
/// new pairs). Each change rewrites its whole key, ~100 KB at the cap: fine at typing
/// speed; batch the writes if it ever shows.
final class TypingMemory {
    static let wordsKey = "suggestions.learnedWords"
    static let pairsKey = "suggestions.wordPairs"
    static let clipKey = "suggestions.retiredClip"

    let defaults: UserDefaults
    let wordCap: Int, pairCap: Int
    /// Learned words, oldest first, and the same as a set.
    private(set) var words: [String]
    private(set) var known: Set<String>
    /// "previous word" → times typed. Previous "" is the start of a field or sentence.
    private(set) var pairs: [String: Int]

    init(defaults: UserDefaults = .standard, wordCap: Int = 2000, pairCap: Int = 5000) {
        self.defaults = defaults
        self.wordCap = wordCap
        self.pairCap = pairCap
        words = defaults.stringArray(forKey: Self.wordsKey) ?? []
        known = Set(words)
        pairs = defaults.dictionary(forKey: Self.pairsKey) as? [String: Int] ?? [:]
    }

    /// The pasteboard `changeCount` last pasted or typed over: that clip isn't offered
    /// again, even after the extension relaunches. A reboot resets the count, so a clip
    /// copied then may stay hidden till the next copy: rare and harmless.
    var retiredClip: Int? {
        get { defaults.object(forKey: Self.clipKey) as? Int }
        set { defaults.set(newValue, forKey: Self.clipKey) }
    }

    func learn(_ word: String) {
        let w = word.lowercased()
        guard known.insert(w).inserted else { return }
        words.append(w)
        if words.count > wordCap {
            known.subtract(words.prefix(words.count - wordCap))
            words.removeFirst(words.count - wordCap)
        }
        defaults.set(words, forKey: Self.wordsKey)
    }

    func record(_ previous: String, _ word: String) {
        let key = previous.lowercased() + " " + word.lowercased()
        pairs[key, default: 0] += 1
        if pairs.count > pairCap {
            let drop = pairs.count - pairCap * 9 / 10
            let rarest = pairs.filter { $0.key != key }.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
            for (k, _) in rarest.prefix(drop) { pairs[k] = nil }
        }
        defaults.set(pairs, forKey: Self.pairsKey)
    }

    /// The three words most often typed after `previous`, topped up with the most often
    /// typed words overall when it has fewer followers. Lowercase.
    func predict(after previous: String) -> [String] {
        var after: [String: Int] = [:], all: [String: Int] = [:]
        let lead = previous.lowercased() + " "
        for (key, n) in pairs {
            guard let space = key.firstIndex(of: " ") else { continue }
            let w = String(key[key.index(after: space)...])
            all[w, default: 0] += n
            if key.hasPrefix(lead) { after[w, default: 0] += n }
        }
        func top(_ counts: [String: Int], _ n: Int, not taken: [String]) -> [String] {
            counts.filter { !taken.contains($0.key) }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(n).map(\.key)
        }
        let first = top(after, 3, not: [])
        return first + top(all, 3 - first.count, not: first)
    }
}

/// The bar above the extension's keys: three slots split by hairlines, like iOS's
/// QuickType, or in a login field one key button toward Apple's keyboard (AutoFill, SMS
/// codes: a tap hops past the sibling Prosper keyboard, a hold lists the keyboards), or
/// at a word start with a fresh clip one Paste button. `attach` also wires `Suggestions`
/// into the keyboard. Extension-only: the terminal keeps its shortcut bar, which the
/// extension can show here in the slots' place (`addToolbar`).
///
/// 44 pt, and never under 42: a top-row press bubble rises 48 pt above a key whose top
/// is 6 pt below the keyboard's, and a custom keyboard can't draw above its own view, so
/// the bar is the bubbles' headroom too. In a compact vertical size class (landscape)
/// 32 pt, over a 3 pt top pad and a 35 pt rise (`TerminalKeyboard.metrics(compact:)`).
/// A plain view on the extension's dark backdrop (`host`), not a UIInputView: one of
/// those slips its own `_UIInputViewContent` halves over its subviews, and they took the
/// right slot's touches.
final class SuggestionBar: UIView {
    static let height: CGFloat = 44
    static func height(compact: Bool) -> CGFloat { compact ? 32 : height }
    let suggestions: Suggestions
    /// The key button's every touch: the controller's `handleInputModeList`, so a tap
    /// advances and a hold lists the keyboards.
    var inputModeList: ((UIView, UIEvent) -> Void)?
    /// When the key button went down. Its lift marks the hop (`KeyboardSettings.markHop`)
    /// only after a tap: a hold showed the list, and its pick must not hop.
    var pressedAt: Date?
    /// A longer press is a hold: the system lists the keyboards from about a 0.22 s press,
    /// and a lift from the list's bottom row still counts as inside the key.
    static let tapLimit: TimeInterval = 0.2
    private(set) var state: Suggestions.State = .slots([nil, nil, nil])
    private weak var keyboard: TerminalKeyboard?
    private(set) var slotButtons: [UIButton] = []
    private var heightConstraint: NSLayoutConstraint?
    private var hairlines: [UIView] = []
    /// The app's shortcut keys in the slots' place (`addToolbar`), and the toggle at the
    /// leading edge that picks them or the slots; both nil until then.
    private(set) var toolbar: ShortcutBar?
    private(set) var toggle: UIButton?
    /// The toggle's pick, in the extension's own defaults (the suggestions' memory's), so it
    /// holds without Full Access. AutoFill and Paste show over the toolbar whatever it says
    /// (`show`), and never change it.
    static let toolbarKey = "keyboard.showsToolbar"
    var showsToolbar: Bool {
        get { suggestions.memory.defaults.bool(forKey: Self.toolbarKey) }
        set { suggestions.memory.defaults.set(newValue, forKey: Self.toolbarKey); show(state) }
    }
    let autofillButton = UIButton(configuration: .plain())
    /// The system's secure Paste (it draws its own icon and "Paste"): a tap hands the clip
    /// to `paste(itemProviders:)` with no Allow Paste prompt, where reading
    /// `UIPasteboard.string` raises one on every tap.
    let pasteControl: UIPasteControl = {
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconAndLabel
        config.baseForegroundColor = .white
        config.baseBackgroundColor = TerminalKeyboard.Style.backdrop   // .clear draws black
        let control = UIPasteControl(configuration: config)
        // Above Large the control outgrows its 36 pt and draws blank, taking no taps.
        control.maximumContentSizeCategory = .large
        return control
    }()

    /// Nil: a fresh one on the extension's own defaults. (Not a default argument: those
    /// are evaluated off the main actor.)
    init(suggestions: Suggestions? = nil) {
        self.suggestions = suggestions ?? Suggestions()
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height))
        overrideUserInterfaceStyle = .dark
        for i in 0..<3 {
            let b = UIButton(type: .custom)
            b.setTitleColor(.white, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 17)
            b.titleLabel?.lineBreakMode = .byTruncatingMiddle
            b.layer.cornerRadius = 6
            b.addAction(UIAction { [weak self] _ in self?.tap(i) }, for: .touchUpInside)
            slotButtons.append(b)
            addSubview(b)
        }
        for _ in 0..<2 {
            let line = UIView()
            line.backgroundColor = TerminalKeyboard.Style.key
            hairlines.append(line)
            addSubview(line)
        }
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "key.fill")
        config.title = "AutoFill"
        config.imagePadding = 6
        config.baseForegroundColor = .white
        autofillButton.configuration = config
        let key = autofillButton
        key.addAction(UIAction { [weak self] _ in self?.pressedAt = Date() }, for: .touchDown)
        // Marked before the list's own touch-up does the advance.
        key.addAction(UIAction { [weak self] _ in self?.autofillLift() }, for: .touchUpInside)
        key.addTarget(self, action: #selector(modeListTouch(_:event:)), for: .allTouchEvents)
        addSubview(autofillButton)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier])
        pasteControl.target = self
        addSubview(pasteControl)
        show(state)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func autofillLift() {
        defer { pressedAt = nil }
        guard let down = pressedAt, Date().timeIntervalSince(down) < Self.tapLimit else { return }
        KeyboardSettings.markHop(from: Bundle.main.bundleIdentifier ?? "")
    }

    @objc private func modeListTouch(_ sender: UIView, event: UIEvent?) {
        if let event { inputModeList?(sender, event) }
    }

    /// The toolbar: `keys` (read again on `toolbar.reload()`) less those a text field
    /// can't use (`Shortcuts.hostKey`), in one row that scrolls, and the toggle before it.
    /// Paste only where the bar's own would show: with Full Access, and not in landscape.
    /// Copy and cut line with Full Access: a keyboard writes the pasteboard only with it.
    func addToolbar(_ keys: @escaping () -> [ShortcutKey]) {
        let tools = ShortcutBar(keys: { [weak self] in
            let full = self?.suggestions.pasteboard() != nil, pastes = full && self?.suggestions.pasteFits == true
            return keys().filter { key in
                guard let action = Shortcuts.hostKey(key.id) else { return false }
                if case .edit(let e) = action, e.copies { return full }
                return pastes || action != .paste
            }
        }, oneRow: true)
        tools.onKey = { [weak self] in self?.press($0) }
        tools.onPaste = { [weak self] in self?.load($0, fromToolbar: true) }
        addSubview(tools)
        toolbar = tools
        let t = UIButton(configuration: .plain())
        t.configuration?.baseForegroundColor = .white
        t.addAction(UIAction { [weak self] _ in self?.showsToolbar.toggle() }, for: .touchUpInside)
        addSubview(t)
        toggle = t
        show(state)
    }

    /// A toolbar key, in the keyboard's target (`Shortcuts.hostKey`).
    func press(_ key: ShortcutKey) {
        guard let keyboard, let doc = keyboard.target as? UITextDocumentProxy,
              let action = Shortcuts.hostKey(key.id) else { return }
        UIDevice.current.playInputClick()
        switch action {
        case .paste: break   // the toolbar's Paste control (`onPaste`), never a read
        case .key(let k): keyboard.press(k)
        case .caret(let n): keyboard.caret(n)
        case .line(let n): keyboard.line(n)
        case .lineEdge(let dir):
            // ponytail: only as far as the context shows the line; a second press goes on.
            let n = dir < 0 ? Self.toLineStart(doc.documentContextBeforeInput ?? "")
                : Self.toLineEnd(doc.documentContextAfterInput ?? "")
            if n > 0 { keyboard.caret(dir * n) }
        case .edit(let e): edit(e, keyboard, doc)
        }
    }

    /// Characters back to the line's start in `before`, as far as it shows. Safari's space
    /// after a break isn't in the text, as `CaretWalk.step` reads it.
    static func toLineStart(_ before: String) -> Int {
        let n = before.reversed().prefix { !$0.isNewline }.count
        return before.hasPrefix("\n ") && n == before.count - 1 ? n - 1 : n
    }

    static func toLineEnd(_ after: String) -> Int { after.prefix { !$0.isNewline }.count }

    /// nvim's word classes: 0 blank, 1 letters, digits and "_", 2 any other.
    static func wordClass(_ c: Character) -> Int {
        c.isWhitespace ? 0 : c.isLetter || c.isNumber || c == "_" ? 1 : 2
    }

    /// Characters over the blanks and then the run of one class at the start of `text`:
    /// `e` on the after-context (the caret lands after the word), `b` and ctrl-w on the
    /// before-context reversed.
    static func toWordEdge<S: Sequence<Character>>(_ text: S) -> Int {
        var n = 0, run: Int?
        for c in text {
            let k = wordClass(c)
            if k == 0 { if run != nil { break } } else if run == nil { run = k } else if k != run { break }
            n += 1
        }
        return n
    }

    /// nvim's `w`: over the run the caret is before, then the blanks.
    static func toNextWord(_ after: String) -> Int {
        let a = Array(after), k = a.first.map(wordClass) ?? 0
        let run = k == 0 ? 0 : a.prefix { wordClass($0) == k }.count
        return run + a[run...].prefix { wordClass($0) == 0 }.count
    }

    /// A toolbar edit. Word motions and ctrl-w go as far as the context shows, as home and end
    /// do: a second press goes on. Line and document edits read the context again after each
    /// move or batch of deletes, since it shows only part of the text (`walk`, `deleteBack`).
    /// Forward deletes walk the caret there first: a proxy deletes only backward.
    private func edit(_ e: Shortcuts.Edit, _ keyboard: TerminalKeyboard, _ doc: UITextDocumentProxy) {
        let before = doc.documentContextBeforeInput ?? "", after = doc.documentContextAfterInput ?? ""
        let copy = suggestions.pasteboard()
        switch e {
        case .wordNext, .wordEnd, .wordBack:
            let n = e == .wordBack ? -Self.toWordEdge(before.reversed())
                : e == .wordEnd ? Self.toWordEdge(after) : Self.toNextWord(after)
            if n != 0 { keyboard.caret(n) }
        case .deleteWord:
            deleteBack(doc, limit: Self.toWordEdge(before.reversed()))
            edited()
        case .deleteToStart:
            deleteBack(doc, Self.toLineStart)
            edited()
        case .deleteToEnd:
            walk(1, { Self.toLineEnd($1) }) { [weak self] crossed in
                guard let self, let doc = self.keyboard?.target as? UITextDocumentProxy else { return }
                self.deleteBack(doc, limit: crossed.count)
                self.edited()
            }
        case .deleteAll:
            // An after-context that stops at the line's end shows no more: one step blind, which
            // the host clamps at the text's end.
            walk(1, { $1.isEmpty ? 1 : $1.count }) { [weak self] _ in
                guard let self, let doc = self.keyboard?.target as? UITextDocumentProxy else { return }
                self.deleteBack(doc) { $0.count }
                self.edited()
            }
        case .deleteLine, .cutLine:
            guard e == .deleteLine || copy != nil else { return }
            walk(1, { Self.toLineEnd($1) }) { [weak self] _ in self?.deleteLine(into: e == .cutLine ? copy : nil) }
        case .copyLine:
            guard let copy else { return }
            // To the line's start, over it to its end, and back: the caret ends where it was.
            walk(-1, { b, _ in Self.toLineStart(b) }) { [weak self] head in
                self?.walk(1, { Self.toLineEnd($1) }) { line in
                    copy.string = line
                    if line.count > head.count { self?.keyboard?.caret(head.count - line.count) }
                }
            }
        }
    }

    /// `dd` from the line's end: its break after it too if the context shows one, else the
    /// one before it, so the next line or the one before takes its place. The line, without
    /// a break, goes to `copy`.
    /// ponytail: a host whose after-context stops at the line's end hides the break after it,
    /// so the first line leaves an empty one there; step over it blind if that matters.
    private func deleteLine(into copy: UIPasteboard?) {
        guard let keyboard, let doc = keyboard.target as? UITextDocumentProxy else { return }
        let joins = doc.documentContextAfterInput?.first?.isNewline == true
        let finish = { [weak self] in
            guard let self, let doc = self.keyboard?.target as? UITextDocumentProxy else { return }
            if joins { doc.deleteBackward() }
            let line = self.deleteBack(doc, Self.toLineStart)
            if !joins, doc.documentContextBeforeInput?.last?.isNewline == true { doc.deleteBackward() }
            copy?.string = line
            self.edited()
        }
        if joins { keyboard.caret(1, then: finish) } else { finish() }
    }

    /// Walks the caret `dir` by `count(before, after)` Characters a leg at a time, each sized
    /// from the context the last landed in (`TerminalKeyboard.caret(_:then:)`), until `count`
    /// finds none or the context stops changing (an edge the host clamps at); then `done`
    /// with the Characters crossed, in order. A touch or a key on the way drops `done`.
    /// ponytail: 1,000 legs at most; a long run of one character in Safari's windows reads
    /// the same after a leg and stops there: a second press goes on.
    private func walk(_ dir: Int, legs: Int = 1_000, crossed: String = "", seen: (String, String)? = nil,
                      _ count: @escaping (String, String) -> Int, done: @escaping (String) -> Void) {
        guard let keyboard, let doc = keyboard.target as? UITextDocumentProxy else { return }
        let b = doc.documentContextBeforeInput ?? "", a = doc.documentContextAfterInput ?? ""
        let n = count(b, a)
        guard n > 0, legs > 0, seen.map({ $0 != (b, a) }) ?? true else { return done(crossed) }
        let leg = String(dir < 0 ? b.suffix(n) : a.prefix(n))
        keyboard.caret(dir * n) { [weak self] in
            self?.walk(dir, legs: legs - 1, crossed: dir < 0 ? leg + crossed : crossed + leg, seen: (b, a),
                       count, done: done)
        }
    }

    /// Deletes back `count(before)` Characters a batch at a time, reading the context again
    /// after each, since it shows only part of the text, until `count` finds none, `limit`
    /// is reached or the context stops changing (a host behind still shows what went). The
    /// Characters deleted, in order.
    /// ponytail: 10,000 deletes at most; a repeat of the last context (a long run of one
    /// character, two equal lines a UITextView shows one at a time) stops early, and a host
    /// one edit behind, its context changed but stale, sizes the next batch past the mark.
    /// Wait for the host's answer between batches if a device shows that.
    @discardableResult
    private func deleteBack(_ doc: UITextDocumentProxy, limit: Int = 10_000,
                            _ count: (String) -> Int = { $0.count }) -> String {
        var gone = "", left = limit, seen: String?
        while left > 0 {
            let before = doc.documentContextBeforeInput ?? ""
            let n = min(count(before), left)
            guard n > 0, before != seen else { break }
            gone = String(before.suffix(n)) + gone
            for _ in 0..<n { doc.deleteBackward() }
            left -= n
            seen = before
        }
        return gone
    }

    /// After an edit the bar's own: the word and the autocorrect it could undo are gone.
    private func edited() {
        keyboard?.resetWord()
        keyboard?.autoCapitalize()
        suggestions.caretMoved()
        refresh()
    }

    /// Suggest for `keyboard`'s target: its keys go through `Suggestions.willPress` and
    /// refresh the bar, as its trackpad's caret moves do (`caretMoved`); learned words and
    /// names join its touch correction.
    func attach(_ keyboard: TerminalKeyboard) {
        self.keyboard = keyboard
        keyboard.willPress = { [weak self, weak keyboard] key in
            guard let self, let doc = keyboard?.target as? UITextDocumentProxy else { return false }
            return self.suggestions.willPress(key, in: doc, autoShift: keyboard?.shift.auto == true)
        }
        keyboard.didPress = { [weak self] in self?.refresh() }
        keyboard.didMoveCaret = { [weak self] in
            self?.suggestions.caretMoved()
            self?.refresh()
        }
        keyboard.screenWords = { [weak self] in self?.suggestions.personalWords ?? [] }
        refresh()
    }

    /// Stacks the bar over `keyboard` in the extension's `view`, which is then the bar's
    /// height plus the keyboard's own height: the digit row's bubbles rise into the bar.
    /// The view gets an opaque dark fill: the keys are fixed dark grays, and a light
    /// app's backdrop behind them would read as a light keyboard with dark keys.
    func host(_ keyboard: TerminalKeyboard, in view: UIView) {
        view.backgroundColor = TerminalKeyboard.Style.backdrop
        for v in [self, keyboard] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let height = heightAnchor.constraint(equalToConstant: Self.height(compact: traitCollection.verticalSizeClass == .compact))
        heightConstraint = height
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: view.topAnchor),
            leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
            keyboard.topAnchor.constraint(equalTo: bottomAnchor),
            keyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The height follows the size class, like the keyboard's (rotation), and so do Paste
    /// and the toolbar's.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        heightConstraint?.constant = Self.height(compact: traitCollection.verticalSizeClass == .compact)
        refresh()
        toolbar?.reload()
    }

    /// Recompute from the text: after each key, and when the host changes the text or
    /// the selection.
    func refresh() {
        assert(Thread.isMainThread, "the bar is main-only")   // debug only: an off-main caller trips in tests and QA
        suggestions.pasteFits = traitCollection.verticalSizeClass != .compact
        guard let doc = keyboard?.target as? UITextDocumentProxy else { return }
        show(suggestions.state(doc, shift: keyboard?.shift.mode ?? .off))
    }

    private func tap(_ i: Int) {
        guard case .slots(let slots) = state, let slot = slots[i],
              let keyboard, let doc = keyboard.target as? UITextDocumentProxy else { return }
        UIDevice.current.playInputClick()
        suggestions.tap(slot, in: doc)
        keyboard.resetWord()
        keyboard.autoCapitalize()
        refresh()
    }

    /// The Paste control's tap (`pasteControl`, whose target is the bar).
    override func paste(itemProviders: [NSItemProvider]) { load(itemProviders, fromToolbar: false) }

    /// A Paste control's clip, the bar's or the toolbar's. It loads off the main thread and
    /// goes in on it, while that control still shows. A late tap (a double tap's second)
    /// loads nothing: loading raises Allow Paste once its control is gone.
    private func load(_ providers: [NSItemProvider], fromToolbar: Bool) {
        guard shows(fromToolbar),
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] clip, _ in
            guard let clip = clip as? String else { return }
            DispatchQueue.main.async { self?.insert(clip, fromToolbar: fromToolbar) }
        }
    }

    private func shows(_ fromToolbar: Bool) -> Bool {
        fromToolbar ? toolbar?.isHidden == false : state == .paste
    }

    private func insert(_ clip: String, fromToolbar: Bool) {
        guard shows(fromToolbar), let keyboard, let doc = keyboard.target as? UITextDocumentProxy else { return }
        UIDevice.current.playInputClick()
        suggestions.paste(clip, in: doc)
        keyboard.resetWord()
        keyboard.autoCapitalize()
        refresh()
    }

    private func show(_ new: Suggestions.State) {
        state = new
        let slots: [Suggestions.Slot?]
        if case .slots(let s) = new { slots = s } else { slots = [nil, nil, nil] }
        let single = new == .autofill || new == .paste   // one full-width button
        let tools = toolbar != nil && !single && showsToolbar
        autofillButton.isHidden = new != .autofill
        pasteControl.isHidden = new != .paste
        toolbar?.isHidden = !tools
        if let toggle {
            toggle.isHidden = single
            toggle.configuration?.image = UIImage(systemName: tools ? "ellipsis.bubble" : "command")
            toggle.accessibilityLabel = tools ? "Show suggestions" : "Show toolbar"
            setNeedsLayout()
        }
        for (b, slot) in zip(slotButtons, slots) {
            b.isHidden = single || tools
            b.isEnabled = slot != nil
            b.setTitle(slot.map { $0.quoted ? "“\($0.word)”" : $0.word }, for: .normal)
            b.accessibilityLabel = slot?.word
            b.backgroundColor = slot?.highlighted == true ? TerminalKeyboard.Style.key : nil
        }
        // Like iOS, no hairline beside the highlighted slot.
        for (i, line) in hairlines.enumerated() {
            line.isHidden = single || tools || slots[i]?.highlighted == true || slots[i + 1]?.highlighted == true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var area = bounds.inset(by: UIEdgeInsets(top: 4, left: safeAreaInsets.left + 3, bottom: 4,
                                                 right: safeAreaInsets.right + 3))
        if let toggle, !toggle.isHidden {
            toggle.frame = CGRect(x: area.minX, y: area.minY, width: 36, height: area.height)
            area = area.inset(by: UIEdgeInsets(top: 0, left: 40, bottom: 0, right: 0))
        }
        toolbar?.frame = CGRect(x: area.minX, y: 0, width: bounds.width - area.minX, height: bounds.height)
        let w = area.width / 3
        for (i, b) in slotButtons.enumerated() {
            b.frame = CGRect(x: area.minX + CGFloat(i) * w, y: area.minY, width: w, height: area.height).insetBy(dx: 2, dy: 0)
        }
        let px = 1 / max(traitCollection.displayScale, 1)
        for (i, line) in hairlines.enumerated() {
            line.frame = CGRect(x: area.minX + CGFloat(i + 1) * w - px / 2, y: area.midY - 12, width: px, height: 24)
        }
        autofillButton.frame = area
        pasteControl.frame = area
    }
}
