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
    /// True while the bar shows its toolbar (`SuggestionBar.showsToolbar`), set by the bar: the
    /// toolbar has its own Paste, so a fresh clip doesn't take its place, nor typing retire it.
    var toolbarShown = false
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
        guard pasteFits, !toolbarShown, let pb = pasteboard(),
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
    /// holds without Full Access. AutoFill shows over the toolbar whatever it says (`show`),
    /// and never changes it; the bar's Paste doesn't (`Suggestions.toolbarShown`).
    static let toolbarKey = "keyboard.showsToolbar"
    var showsToolbar: Bool {
        get { suggestions.memory.defaults.bool(forKey: Self.toolbarKey) }
        set { suggestions.memory.defaults.set(newValue, forKey: Self.toolbarKey); refresh() }
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
        // Body's size at Large, fixed: a glyph growing with the text clips in the 36 pt slot.
        t.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17)
        t.addAction(UIAction { [weak self] _ in self?.showsToolbar.toggle() }, for: .touchUpInside)
        addSubview(t)
        toggle = t
        refresh()
    }

    /// A toolbar key, in the keyboard's target (`Shortcuts.hostKey`), once a step pair an edit
    /// has under way is back (`TerminalKeyboard.finish`): it reads the context.
    func press(_ key: ShortcutKey) {
        guard let keyboard, keyboard.target is UITextDocumentProxy, Shortcuts.hostKey(key.id) != nil else { return }
        UIDevice.current.playInputClick()
        keyboard.finish { [weak self] in self?.act(key) }
    }

    private func act(_ key: ShortcutKey) {
        guard let keyboard, let doc = keyboard.target as? UITextDocumentProxy,
              let action = Shortcuts.hostKey(key.id) else { return }
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
        let before = Self.before(doc), after = doc.documentContextAfterInput ?? ""
        let copy = suggestions.pasteboard()
        switch e {
        case .wordBack:
            let n = Self.toWordEdge(before.reversed())
            if n != 0 { keyboard.caret(-n) }
        case .wordNext, .wordEnd:
            guard after.isEmpty else {
                let n = e == .wordEnd ? Self.toWordEdge(after) : Self.toNextWord(after)
                if n != 0 { keyboard.caret(n) }
                return
            }
            // An after-context that stops at the line's end shows no more: one step blind over
            // the break, which the host clamps at the text's end, then on from the next line's
            // start, where `w` has landed unless blanks start it. `e` steps on over empty
            // lines, as nvim's. ponytail: two empty lines read the same in a UITextView, so `e`
            // stops on the second; a second press goes on.
            if e == .wordEnd {
                return walk(1, { $1.isEmpty ? 1 : 0 }) { [weak self] _ in
                    guard let kb = self?.keyboard, let a = (kb.target as? UITextDocumentProxy)?.documentContextAfterInput
                    else { return }
                    let n = Self.toWordEdge(a)
                    if n != 0 { kb.caret(n) }
                }
            }
            keyboard.caret(1) { [weak self] in
                guard let kb = self?.keyboard, let a = (kb.target as? UITextDocumentProxy)?.documentContextAfterInput
                else { return }
                let n = a.first.map(Self.wordClass) == 0 ? Self.toNextWord(a) : 0
                if n != 0 { kb.caret(n) }
            }
        case .deleteWord:
            // At a line's start only the break, as nvim's insert mode: not the word before it too.
            let n = before.last?.isNewline == true ? 1 : Self.toWordEdge(before.reversed().prefix { !$0.isNewline })
            deleteBack(left: n) { b, _ in b.count }
        case .deleteToStart:
            deleteBack { b, _ in Self.toLineStart(b) }
        case .deleteToEnd:
            walk(1, { Self.toLineEnd($1) }) { [weak self] crossed in
                self?.deleteBack(left: crossed.count) { b, _ in b.count }
            }
        case .deleteAll:
            // Back to the text's start at once, so the deletes show at the press (#553 QA: the
            // walk first took 2 s from mid-text); then to its end, one step blind where the
            // after-context stops at the line's end, which the host clamps at the text's end,
            // and back. Only once the host showed the first part gone: one that never shows a
            // batch would size the rest from what went.
            // The first part's deletes saw the before-context: no field without context.
            let rest: () -> Void = { [weak self] in
                self?.walk(1, { $1.isEmpty ? 1 : $1.count }) { [weak self] _ in
                    self?.deleteBack(all: true, blind: before.isEmpty ? nil : false) { b, _ in b.count }
                }
            }
            guard !before.isEmpty else { return rest() }
            deleteBack(all: true, { b, _ in b.count }) { [weak self] _ in
                guard let doc = self?.keyboard?.target as? UITextDocumentProxy, Self.before(doc).isEmpty else { return }
                rest()
            }
        case .deleteLine, .cutLine:
            guard e == .deleteLine || copy != nil else { return }
            walk(1, { Self.toLineEnd($1) }) { [weak self] crossed in
                self?.deleteLine(into: e == .cutLine ? copy : nil, moved: !crossed.isEmpty)
            }
        case .copyLine:
            guard let copy else { return }
            // To the line's start, over it to its end, and back: the caret ends where it was.
            walk(-1, { b, _ in Self.toLineStart(b) }) { [weak self] head in
                self?.walk(1, { Self.toLineEnd($1) }) { line in
                    guard !line.isEmpty else { return }   // an empty line leaves the clip be
                    self?.keep(line, in: copy)
                    if line.count > head.count { self?.keyboard?.caret(head.count - line.count) }
                }
            }
        }
    }

    /// The keyboard's own copy: retired at once, so a fresh clip of it never takes the bar.
    private func keep(_ line: String, in copy: UIPasteboard) {
        copy.string = line
        suggestions.memory.retiredClip = copy.changeCount
    }

    /// `dd` from the line's end: over the break after it, blind where the after-context stops
    /// at the line's end (the host clamps at the text's end), then back over it and the line,
    /// the caret on the next line's start, as nvim's. The last line goes with the break before
    /// it instead, the caret then on the line above's start (nvim's first non-blank). The line,
    /// without a break, goes to `copy` unless it's empty.
    ///
    /// The step crossed a break if the context changed and its before ends in one, which holds only
    /// for a context a move showed: one an edit left (`deleteBack`) re-windows at the step
    /// even where the host clamps it. So a walk that `moved` nothing re-windows first (#553
    /// QA: a stale "" on the empty last line took the line above).
    private func deleteLine(into copy: UIPasteboard?, moved: Bool, blind: Bool? = nil) {
        guard let keyboard, let doc = keyboard.target as? UITextDocumentProxy else { return }
        guard moved else {
            return rewindow(waits: true, blind: Self.shows(doc) ? false : nil) { [weak self] in
                self?.deleteLine(into: copy, moved: true, blind: $0)
            }
        }
        let seen = (Self.before(doc), doc.documentContextAfterInput ?? "")
        guard seen.1.isEmpty || seen.1.first?.isNewline == true else { return }   // the walk stopped short
        keyboard.caret(1) { [weak self] in
            guard let self, let doc = self.keyboard?.target as? UITextDocumentProxy else { return }
            let b = Self.before(doc), joins = (b, doc.documentContextAfterInput ?? "") != seen && b.last?.isNewline == true
            self.deleteBack(blind: blind, { b, gone in
                let n = Self.toLineStart(b)
                if joins { return gone.isEmpty && b.last?.isNewline == true ? 1 + Self.toLineStart(String(b.dropLast())) : n }
                return gone.first?.isNewline == true ? 0 : n < b.count ? n + 1 : n
            }, done: { [weak self] gone in
                var line = Substring(gone)
                if joins, line.last?.isNewline == true { line.removeLast() }
                if !joins, line.first?.isNewline == true { line.removeFirst() }
                if let copy, !line.isEmpty { self?.keep(String(line), in: copy) }
                if !joins, gone.first?.isNewline == true { self?.walk(-1, { b, _ in Self.toLineStart(b) }) { _ in } }
            })
        }
    }

    /// Walks the caret `dir` by `count(before, after)` Characters a leg at a time, each sized
    /// from the context the last landed in (`TerminalKeyboard.caret(_:then:)`), until `count`
    /// finds none or the context stops changing (an edge the host clamps at); then `done`
    /// with the Characters crossed, in order. A touch or a key on the way drops `done`.
    /// A leg back taking a before-context that opens on a space whole stops short of it: the
    /// space may be Safari's after a break, not in the text, and the next leg reads on.
    /// ponytail: 1,000 legs at most; a long run of one character in Safari's windows reads
    /// the same after a leg and stops there: a second press goes on.
    private func walk(_ dir: Int, legs: Int = 1_000, crossed: String = "", seen: (String, String)? = nil,
                      _ count: @escaping (String, String) -> Int, done: @escaping (String) -> Void) {
        guard let keyboard, let doc = keyboard.target as? UITextDocumentProxy else { return }
        let b = doc.documentContextBeforeInput ?? "", a = doc.documentContextAfterInput ?? ""
        let n = count(b, a) - (dir < 0 && b.first == " " && count(b, a) == b.count ? 1 : 0)
        guard n > 0, legs > 0, seen.map({ $0 != (b, a) }) ?? true else { return done(crossed) }
        let leg = String(dir < 0 ? b.suffix(n) : a.prefix(n))
        keyboard.caret(dir * n) { [weak self] in
            self?.walk(dir, legs: legs - 1, crossed: dir < 0 ? leg + crossed : crossed + leg, seen: (b, a),
                       count, done: done)
        }
    }

    /// Deletes back `count(before, gone)` Characters, `gone` those deleted so far, `left` at
    /// most, a batch at a time, each sent whole and the context read again only once the host
    /// shows it (`TerminalKeyboard.wait`): real hosts answer a later runloop turn, and a
    /// context that hasn't shown a batch sizes the next past the mark. Where the context shows
    /// where the deletes end (`count` short of its start), or `left` does, one batch is all;
    /// else it leaves the context's start, the anchor the next context must end in, ending
    /// unlike the batch starts, so a host one edit behind, still showing its first Character,
    /// is never taken for the answer. Then `edited` and `done` with what went, in order.
    /// A key, a touch or a move drops the rest.
    ///
    /// After a delete a host shows only what's left of the window it cut the context at, ""
    /// at that window's start, till a move shows a fresh one (#553 QA: UITextView's windows
    /// open at a sentence or a paragraph, Safari's at a row). So such a context is never taken
    /// for the edge: where `count` reaches its start and the batch would leave no anchor, the
    /// caret steps away and back (`rewindow`) and the batch is sized from the `fresh` context.
    /// So too an empty one, which an edit before may have left; a fresh empty one is the
    /// text's start. Only then: a run of one Character leaves an anchor, so its batches of one
    /// take no steps (#553 QA: 84 steps for 168 deletes).
    /// Deleting `all` (delete all's), nothing the deletes reach is to stay, and one past the
    /// text's start does nothing: a batch taking the whole context goes without steps first
    /// and takes one more blind, saving the steps for the break's window, and a timeout goes
    /// on from any fresh context.
    /// A batch the context still doesn't show after 0.3 s goes on from a fresh context too
    /// (#553 QA: Safari at times keeps the old window, a stalling host answers late): with an
    /// anchor, but for `all`, only once a context shows the batch gone, waiting again up to
    /// three times, so no batch is sized from a context that still shows the last one; without
    /// (the batch took the whole context), from any, since an empty line's break in a
    /// UITextView, and Safari's at a window's start, read the same after it.
    /// ponytail: 10,000 deletes at most; a host still not showing a batch after three waits
    /// ends it there with what went, a second press goes on. A run of one Character goes one
    /// a batch, a poll each.
    private func deleteBack(left: Int = 10_000, gone: String = "", fresh: Bool = false, all: Bool = false,
                            blind: Bool? = nil, _ count: @escaping (String, String) -> Int,
                            done: @escaping (String) -> Void = { _ in }) {
        guard let keyboard, let doc = keyboard.target as? UITextDocumentProxy else { return }
        let blind = blind ?? (Self.shows(doc) ? false : nil)
        let b = Self.before(doc), c = Array(b), want = min(count(b, gone), left)
        // A context starting at a space may start at Safari's after a break, not in the text:
        // the anchor goes past it, and is checked without it.
        let from = c.first == " " ? 2 : 1
        let m = c.isEmpty ? 0 : want < c.count || want == left ? c.count - want
            : (from..<max(from, c.count)).first { c[$0 - 1] != c[$0] } ?? c.count - 1
        let anchor = String(c[(c.first == " " ? min(1, m) : 0)..<m])
        if !fresh, anchor.isEmpty, want >= c.count, want < left, c.isEmpty || !gone.isEmpty && !all {
            // A fresh empty one ends it: from a busy host's answer, not UIKit's guess.
            return rewindow(waits: c.isEmpty, blind: blind) { [weak self] in
                self?.deleteBack(left: left, gone: gone, fresh: true, all: all, blind: $0, count, done: done)
            }
        }
        guard want > 0 else { edited(); return done(gone) }
        let batch = String(c[m...]), sent = min(batch.count + (all && m == 0 ? 1 : 0), left)
        for _ in 0..<sent { doc.deleteBackward() }
        keyboard.resetWord()   // a key before the host answers corrects nothing that went
        suggestions.caretMoved()
        let shown = { (now: String) in
            now != b && (anchor.isEmpty || !now.isEmpty && (now.hasSuffix(anchor) || anchor.hasSuffix(now)))
        }
        // Read till the context shows the batch; after 0.3 s without, from a fresh one, and
        // so up to three times.
        func read(_ tries: Int) {
            var last = b, quiet = 0
            keyboard.wait { [weak self] in
                guard let self, let doc = self.keyboard?.target as? UITextDocumentProxy else { return true }
                let now = Self.before(doc)
                if shown(now) {
                    self.deleteBack(left: left - sent, gone: batch + gone, all: all, blind: blind, count, done: done)
                    return true
                }
                if now != last { last = now; quiet = 0 } else { quiet += 1 }
                guard quiet > 15 else { return false }
                guard left > sent else { self.edited(); done(batch + gone); return true }
                self.rewindow(blind: blind) { [weak self] blind in
                    guard let self, let doc = self.keyboard?.target as? UITextDocumentProxy else { return }
                    if anchor.isEmpty || all || shown(Self.before(doc)) {
                        self.deleteBack(left: left - sent, gone: batch + gone, fresh: true, all: all, blind: blind, count, done: done)
                    } else if tries > 1 { read(tries - 1) } else { self.edited(); done(batch + gone) }
                }
                return true
            }
        }
        read(3)
    }

    /// The caret a step away and back, so a host that cut its context at a delete shows a
    /// fresh one (`deleteBack`), then `then`. The step goes on first where the after-context
    /// shows text, so the two net nothing at the text's start whatever the before-context reads
    /// (#553 QA: one still showing the Character deleted there took a step back the host
    /// ignored for a move, and the step on went past the next). Else back first: from an empty
    /// before-context, a step back the host ignores, the context as it was, is the text's
    /// start, and no step on; one that shows the Character stepped over after it is no edge.
    /// A field known to show no context (`blind`) gets no steps; one showing none now, before
    /// or after a step, gets the step back (#553 QA: a UITextView, and Safari, show none at
    /// the text's end once a delete used up the window, and UIKit's `hasText` is false there).
    /// `then` gets `blind`, decided by the step away where it wasn't (`shows`), and only while
    /// the pair's end shows none either: a busy host's step away lands on UIKit's guess, empty
    /// from an empty context, and its answer shows the text later.
    /// Steps that landed on the context as it was may have landed on UIKit's guess: one that
    /// `waits` waits up to 0.3 s more for the host's answer, another context with the same
    /// after-context, as dd's does for a context the last edit may have left stale (#553 QA: a
    /// busy host's answer to the step back was taken for dd's next step's), and the deletes'
    /// from an empty one, which a guess would leave empty. Other deletes' needn't: UIKit's copy
    /// shows them.
    /// A key, a touch or a press before the step back lands gets the caret back first
    /// (`TerminalKeyboard.caret(away:back:then:)`).
    /// ponytail: a host answering later than 0.3 s is read before it does.
    private func rewindow(waits: Bool = false, blind: Bool?, then: @escaping (_ blind: Bool) -> Void) {
        guard let keyboard, let doc = keyboard.target as? UITextDocumentProxy else { return }
        guard blind != true else { return then(true) }
        let none = doc.documentContextBeforeInput == nil && doc.documentContextAfterInput == nil
        let was = (doc.documentContextBeforeInput ?? "", doc.documentContextAfterInput ?? ""), on = !was.1.isEmpty
        var back = true, blind = blind
        keyboard.caret(away: on ? 1 : -1, back: { [weak keyboard] in
            guard let doc = keyboard?.target as? UITextDocumentProxy else { return true }
            blind = blind ?? !Self.shows(doc)
            back = on || none || !was.0.isEmpty || doc.documentContextBeforeInput?.isEmpty == false
                || doc.documentContextAfterInput ?? "" != was.1
            return back
        }) { [weak self] in
            let then = { [weak self] in
                let doc = self?.keyboard?.target as? UITextDocumentProxy
                then(blind == true && doc.map { !Self.shows($0) } != false)
            }
            guard waits, back, let kb = self?.keyboard else { return then() }
            var last = was, quiet = 0
            let answered = { [weak kb] () -> Bool in
                guard let doc = kb?.target as? UITextDocumentProxy else { return true }
                let now = (doc.documentContextBeforeInput ?? "", doc.documentContextAfterInput ?? "")
                if now != was, now.1 == was.1 { return true }
                if now != last { last = now; quiet = 0 } else { quiet += 1 }
                return quiet > 15
            }
            if answered() { return then() }
            kb.wait { guard answered() else { return false }; then(); return true }
        }
    }

    /// The field shows some context. A field shows none (`blind`, no steps for a fresh one)
    /// only if it showed none before a press's first delete and still none after its first
    /// step: decided once a press, before it deletes, and passed on. Never from a context an
    /// edit left, which may be none with text either side (#553 QA: a UITextView's at its end
    /// once a delete used up the window, Safari's too; dd's from the last press's), and never
    /// from `hasText`, which UIKit answers from the context.
    private static func shows(_ doc: UITextDocumentProxy) -> Bool {
        doc.documentContextBeforeInput?.isEmpty == false || doc.documentContextAfterInput?.isEmpty == false
    }

    /// The before-context, Safari's space after a break that isn't in the text taken out, as
    /// `CaretWalk.step` reads it.
    private static func before(_ doc: UITextDocumentProxy) -> String {
        let b = doc.documentContextBeforeInput ?? ""
        return b.hasPrefix("\n ") ? "\n" + b.dropFirst(2) : b
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
        suggestions.toolbarShown = toolbar != nil && showsToolbar
        guard let doc = keyboard?.target as? UITextDocumentProxy else { return show(state) }
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
