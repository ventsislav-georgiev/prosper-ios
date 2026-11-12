import XCTest
import UIKit
@testable import Prosper

/// #941: the typo harness through the extension's real autocorrect. Whole sentences, each
/// letter a jittered thumb tap through `track()` (`TypoRateTests.Thumb`, seeded), a space
/// after each word, so the words before are in the document's context, then the wrong words
/// that survive per 1000: (a) context errors, the typo itself a word the checker keeps or a
/// wrong guess picked with the right one in the top 3, a previous word could fix them, and
/// (b) the rest. A measuring instrument: it prints, and asserts only loose sanity bounds.
/// #942 compares ranking strategies through `measure(... suggestions:)` and `score`.
@MainActor
final class SentenceTypoTests: XCTestCase {
    typealias K = TerminalKeyboard

    /// Everyday sentences, lowercase, letters only, written for this test.
    static let english = """
        i think we should go to the market after work today
        she said the game was over before the team got home
        can you tell me what time the train leaves in the morning
        my father reads a book every night before he goes to sleep
        the children played in the water while their mother watched
        we need to find a new place to live by the end of the year
        he never thought the old house would still be there
        please call me back when you have a moment to talk
        it was a long day and i am going to bed early
        they want to buy a car but they do not have the money
        the door was open so the cat walked into the room
        our teacher gave us a lot of work for the weekend
        do you know where i put my keys this morning
        the city looks very different from the top of the hill
        i will send you the file as soon as i get back
        let me know if you need any help with the move
        the power went out during the storm last night
        she has a good idea for the start of the story
        we met at a party a few years ago and became friends
        he likes to run in the park before he goes to work
        there is still some food left in the kitchen if you want it
        the music was so loud that we could not hear each other
        my sister wants to study history at the university next year
        you can leave your bag here while we look around
        the meeting starts at ten so do not be late again
        i forgot to bring my phone so i could not call you
        they walked along the river until the sun went down
        this is the best coffee i have had in a long time
        the doctor told him to rest and drink more water
        we should ask them what they think about the plan
        her brother works at a small shop near the station
        the kids are waiting outside for the bus to school
        it is going to rain later so take your coat with you
        he read the letter twice and then put it away
        the price of bread went up again this month
        can we talk about this tomorrow when we both have time
        i saw a movie last week that made me laugh a lot
        the road was closed so we had to find another way
        she always makes dinner for the whole family at the weekend
        we are almost there so please wait a few more minutes
        """.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    static let bulgarian = """
        днес времето е хубаво и искам да отида на море
        моля те кажи ми кога тръгва влакът за града
        майка ми прави най хубавия хляб в цялото село
        вчера вечерта четох книга до късно през нощта
        децата играят в парка след като свършат училище
        трябва да купя мляко и хляб на връщане от работа
        брат ми живее в голяма къща близо до реката
        не знам какво да правя с толкова много време
        всеки ден ходя пеша до работа защото е близо
        благодаря ти за помощта беше много добре
        утре ще говоря с баща ти за новата работа
        тя винаги пие кафе сутрин преди да излезе
        кога ще дойдеш да видиш новия ни дом
        имам един въпрос за урока от вчера
        колата е стара но все още работи добре
        понякога слушам музика когато пиша писма
        на планината въздухът е чист и студен
        приятелят ми обича да готви за всички
        сестра ми учи история в университета
        мисля че трябва да тръгваме защото е късно
        искаш ли да вечеряме заедно довечера
        той никога не идва навреме на срещите
        слънцето залезе и небето стана червено
        помагам на баба в градината всяка събота
        какво ще правиш през лятото тази година
        """.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

    /// The shipped thumb (`TypoRateTests`' #543 model) and the wider one #932 measured with.
    static let thumbs = Array(TypoRateTests.thumbs.prefix(2))

    /// What a run's words came out as.
    struct Result {
        var words = 0, raw = 0, fixed = 0, context = 0, rest = 0
        /// One line per surviving wrong word: intended, typed, what stayed, its class.
        var wrong: [String] = []
        var surviving: Int { context + rest }
        func perMille(_ n: Int) -> Double { 1000 * Double(n) / Double(max(words, 1)) }
        var line: String {
            String(format: "surviving %.1f/1000 (context %.1f, rest %.1f) | raw taps wrong %.1f/1000, autocorrect fixed %d, of %d words",
                   perMille(surviving), perMille(context), perMille(rest), perMille(raw), fixed, words)
        }
    }

    /// Wrong words in `output` against `intended`, aligned word by word; a word split or
    /// merged counts for each word it touches. #942's score for a corrected sentence.
    static func score(_ intended: String, _ output: String) -> Int {
        let a = intended.split(separator: " ").map { $0.lowercased() }
        let b = output.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var next = [i + 1]
            for (j, y) in b.enumerated() { next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (x == y ? 0 : 1))) }
            row = next
        }
        return row[b.count]
    }

    /// `sentences` typed `passes` times with `thumb`'s taps on the extension's keyboard, a
    /// space (pressed, never missed) after each word, through `suggestions`. One memory for
    /// the run, so its word pairs build up as a user's would. `autocorrect: false` turns
    /// the field's off: the sanity baseline.
    func measure(_ layout: K.Layout, _ sentences: [String], _ thumb: TypoRateTests.Thumb, passes: Int = 6,
                 autocorrect: Bool = true, suggestions: Suggestions? = nil) -> Result {
        let suite = "SentenceTypoTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let s = suggestions ?? Suggestions(memory: TypingMemory(defaults: UserDefaults(suiteName: suite)!), layout: layout)
        let doc = KeyboardExtensionTests.FakeProxy()
        doc.autocapitalizationType = .none
        if !autocorrect { doc.autocorrectionType = .no }
        let kb = K(layout: layout)
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: K.height)
        kb.layoutIfNeeded()
        var centers: [Character: CGPoint] = [:]
        for case let b as UIButton in kb.subviews {
            if let t = b.title(for: .normal), t.count == 1 { centers[Character(t.lowercased())] = CGPoint(x: b.frame.midX, y: b.frame.midY) }
        }
        kb.target = doc
        let bar = SuggestionBar(suggestions: s)
        bar.attach(kb)
        defer { withExtendedLifetime(bar) {} }
        var rng = TypoRateTests.Seeded(state: 941), r = Result(), id = 0
        for _ in 0..<passes {
            for sentence in sentences {
                kb.resetWord(); doc.text = ""
                for w in sentence.split(separator: " ").map(String.init) {
                    let start = doc.text
                    for c in w {
                        let center = centers[c]!
                        let p = CGPoint(x: center.x + rng.normal(thumb.sx), y: center.y + thumb.down + rng.normal(thumb.sy))
                        id += 1
                        kb.track(.began, id: id, at: p)
                        kb.track(.ended, id: id, at: p)
                        if kb.showsEmoji { kb.showEmoji(false) }
                    }
                    // A tap on backspace ate into the words before: all of it is this word's.
                    let typed = doc.text.hasPrefix(start) ? String(doc.text.dropFirst(start.count)).lowercased() : "⌫"
                    kb.press(.space)
                    let out = doc.text.hasPrefix(start) ? String(doc.text.dropFirst(start.count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : "⌫"
                    r.words += 1
                    if typed != w { r.raw += 1 }
                    if out == w { if typed != w { r.fixed += 1 }; continue }
                    let letters = !typed.isEmpty && typed.allSatisfy(\.isLetter)
                    let top3 = letters ? Suggestions.guesses(typed, language: layout.language).prefix(3).map { $0.lowercased() } : []
                    let context = letters && ((out == typed && s.knows(typed)) || (out != typed && top3.contains(w)))
                    if context { r.context += 1 } else { r.rest += 1 }
                    r.wrong.append("\(w) -> \(typed.debugDescription) -> \(out.debugDescription) \(context ? "context" : "rest")")
                }
            }
        }
        return r
    }

    /// The numbers, English and Bulgarian, each thumb, autocorrect on and off. The bounds are
    /// sanity only: autocorrect leaves fewer wrong words than the raw taps, the run typed
    /// every word, and English through autocorrect stays under 15 words in 100.
    func testSentencesThroughAutocorrect() {
        XCTAssertEqual(Self.score("the cat sat", "the cot sat"), 1)
        XCTAssertEqual(Self.score("the cat sat", "the c at sat"), 2)
        for (name, layout, sentences) in [("EN", K.Layout.english, Self.english), ("BG", .bulgarian, Self.bulgarian)] {
            let count = sentences.reduce(0) { $0 + $1.split(separator: " ").count } * 6
            for t in Self.thumbs {
                let on = measure(layout, sentences, t), off = measure(layout, sentences, t, autocorrect: false)
                print("sentences \(name) \(t.name), autocorrect on: \(on.line)")
                print("sentences \(name) \(t.name), autocorrect off: \(off.line)")
                for w in on.wrong { print("sentences \(name) \(t.name) wrong: \(w)") }
                XCTAssertEqual(on.words, count, name)
                XCTAssertEqual(off.raw, on.raw, "\(name): the same seed, the same taps")
                XCTAssertEqual(off.fixed, 0, name)
                if name == "EN" {
                    XCTAssertLessThan(on.surviving, off.surviving, "\(name) \(t.name): autocorrect fixes some")
                    XCTAssertLessThan(on.perMille(on.surviving), 150, "\(name) \(t.name)")
                }
            }
        }
        // The simulator's checker has no Bulgarian list (`bulgarianSpells`): BG on equals off there.
        print("sentences BG checker spells: \(K.bulgarianSpells)")
    }
}
