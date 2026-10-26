import XCTest
import UIKit
@testable import Prosper

/// The typo harness: common words typed through `track()` on the real layout at 402 pt,
/// each tap at its key's center plus seeded jitter (σ 7 pt sideways and 8 pt up and down,
/// centered 4 pt low, as thumbs land), then the character error rate with `tapLift` as
/// shipped and at 0. Touch correction is on in both.
/// Deterministic: the same seed for both, so they see the same taps. The 4 pt low is an
/// assumption, not a measurement: the harness guards that the lift helps, not its value.
@MainActor
final class TypoRateTests: XCTestCase {
    typealias K = TerminalKeyboard

    /// SplitMix64: a seeded generator, the same taps on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Box-Muller.
        mutating func normal(_ sigma: CGFloat) -> CGFloat {
            let u = Double.random(in: .ulpOfOne..<1, using: &self), v = Double.random(in: 0..<1, using: &self)
            return sigma * CGFloat((-2 * log(u)).squareRoot() * cos(2 * .pi * v))
        }
    }

    /// The field: what the keys typed, backspace included.
    private final class Field: NSObject, UIKeyInput {
        var text = ""
        var hasText: Bool { !text.isEmpty }
        func insertText(_ s: String) { text += s }
        func deleteBackward() { _ = text.popLast() }
    }

    /// Common words, written for this test.
    static let english = """
        the be to of and in that have it for not on with he as you do at this but his by from they we say
        her she or an will my one all would there their what so up out if about who get which go me when
        make can like time no just him know take people into year your good some could them see other than
        then now look only come its over think also back after use two how our work first well way even new
        want because any these give day most us is was are were been has had did said made find here thing
        many where right still between never under while last might great old big high small long little
        world life hand part child eye woman man place week case point number group problem fact home water
        room mother area money story night month lot book word side kind head house friend father power hour
        game line end member car city name team minute idea body face level door health person art war
        history party result change morning reason girl moment air teacher force foot boy age music market
        sense plan interest death course behind open walk start light keep turn ask show try call need feel
        become leave put mean let begin seem help talk move live believe hold bring happen write sit stand
        lose pay meet run read
        """.split(whereSeparator: \.isWhitespace).map(String.init)
    /// Rarer words, so a fix tuned to the commonest ones can't hide what it costs the rest.
    static let rarer = """
        thread shrimp glimpse brisk fjord quilt vortex plume garnish zealous whisk jovial knack
        mirth bland crisp drowsy fable gravel hustle ivory jargon kettle lumber muffin nimble
        oyster parcel quiver ripple saddle tavern umpire velvet walnut yonder zipper anchor
        bramble cobalt dwindle ember flannel goblet hazel inkwell jasmine kelp lantern meadow
        nectar orchid pebble quarry rustle sorrel thimble urchin vessel wicker yeast zinnia
        abide blunder cactus dimple elbow fiddle gargle hamlet igloo jostle kindle ladle mosaic
        nozzle oblong pickle quench rhubarb scribble tundra upend vigil wobble yodel zephyr
        apron buckle cinder doodle eclipse frolic gizmo huddle inlet juggle knoll lobster mingle
        nugget outfox puddle quirk raffle sprocket tickle unzip vandal waddle yogurt zigzag
        """.split(whereSeparator: \.isWhitespace).map(String.init)
    static let bulgarian = """
        и в на да се не за от че с е по това са като но към ще си му ми го ако или когато който която което
        които много един една едно само още вече сега тук там така след преди между без при през до под над
        около защото също всичко всички нещо нищо някой никой време година ден дни нощ утро вечер човек хора
        жена мъж дете деца майка баща брат сестра семейство приятел град село къща дом улица път държава
        страна свят вода хляб храна работа пари училище книга дума думи език история въпрос отговор място
        част начин страница живот любов сърце ръка глава око очи лице кола влак море планина река гора
        слънце небе земя огън въздух добър добре лош голям малък нов стар млад бял черен червен зелен син
        хубав красив бърз бавен дълъг кратък висок нисък топъл студен лесно трудно говоря казвам казва правя
        прави искам иска мога може трябва имам има няма знам знае виждам вижда отивам идвам дойде живея
        работя пиша чета слушам обичам ходя ям пия спя мисля вярвам помагам питам отговарям играя купувам
        давам взимам първи втори последен утре вчера днес винаги никога понякога често рано късно бързо тихо
        заедно сам моля благодаря здравей довиждане
        """.split(whereSeparator: \.isWhitespace).map(String.init)

    private var lift: CGFloat = 0

    override func setUp() {
        super.setUp()
        lift = K.tapLift
    }

    override func tearDown() {
        K.tapLift = lift
        super.tearDown()
    }

    /// Wrong characters per typed character, over `passes` of `words`, each word typed
    /// afresh into an empty field.
    private func errorRate(_ layout: K.Layout, _ words: [String], lift: CGFloat, passes: Int = 10) -> Double {
        K.tapLift = lift
        let kb = K(layout: layout)
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: K.height)
        kb.layoutIfNeeded()
        var centers: [Character: CGPoint] = [:]
        for case let b as UIButton in kb.subviews {
            if let t = b.title(for: .normal), t.count == 1 { centers[Character(t.lowercased())] = CGPoint(x: b.frame.midX, y: b.frame.midY) }
        }
        let field = Field()
        kb.target = field
        var rng = Seeded(state: 543), errors = 0, chars = 0, id = 0
        for _ in 0..<passes {
            for w in words {
                kb.resetWord(); field.text = ""
                for c in w {
                    let center = centers[c]!
                    let p = CGPoint(x: center.x + rng.normal(7), y: center.y + 4 + rng.normal(8))
                    id += 1
                    kb.track(.began, id: id, at: p)
                    kb.track(.ended, id: id, at: p)
                    if kb.showsEmoji { kb.showEmoji(false) }
                }
                errors += Suggestions.editDistance(field.text.lowercased(), w)
                chars += w.count
            }
        }
        return Double(errors) / Double(chars)
    }

    /// About 10,000 taps per language. Bulgarian's 11 keys a row are narrower, so more of
    /// its typos are sideways, where no lift helps.
    func testTheLiftCutsTheTypoRate() {
        for (name, layout, words) in [("English", K.Layout.english, Self.english), ("Bulgarian", .bulgarian, Self.bulgarian)] {
            let off = errorRate(layout, words, lift: 0), on = errorRate(layout, words, lift: lift)
            print(String(format: "typo rate %@: lift 0 %.2f%%, lift %.0f %.2f%%", name, off * 100, lift, on * 100))
            XCTAssertLessThan(on, off * 0.9, name)
        }
    }

    // MARK: Prose with a thumb

    /// A thumb's taps: the spread across (`sx`) and down (`sy`), the mean offset down and
    /// toward the thumb's own side (a key left of the middle is the left thumb's), how far
    /// the lift drifts from the touch-down, and the share of rushed taps at twice the spread.
    /// Space is the other thumb's, aimed a quarter of its width in from its own end.
    ///
    /// ponytail: assumed, not measured: the spread is about 1.5 mm, the offsets 1 mm and
    /// 0.5 mm. Replace it with a device's logged taps if one ever records them.
    struct Thumb {
        var name: String, sx: CGFloat, sy: CGFloat, down: CGFloat
        var side: CGFloat = 0, drift: CGFloat = 0, rushed: Double = 0
    }

    static let thumbs = [
        Thumb(name: "#543 model", sx: 7, sy: 8, down: 4),
        Thumb(name: "wider", sx: 9, sy: 11, down: 6),
        Thumb(name: "+side", sx: 9, sy: 11, down: 6, side: 3),
        Thumb(name: "+lift drift", sx: 9, sy: 11, down: 6, side: 3, drift: 3),
        Thumb(name: "+rushed", sx: 9, sy: 11, down: 6, side: 3, drift: 3, rushed: 0.05),
    ]

    /// Wrong taps per kind: a word's first letter, its later letters, space, and the spaces
    /// that typed a letter (the bottom row over the bar).
    struct Tally {
        var first = (wrong: 0, n: 0), rest = (wrong: 0, n: 0), space = (wrong: 0, n: 0), spaceLetter = 0
        var vertical = 0, deadEnd = 0, intact = 0, belowView = 0, inStrip = 0
        func pct(_ c: (wrong: Int, n: Int)) -> Double { 100 * Double(c.wrong) / Double(max(c.n, 1)) }
        var line: String {
            String(format: "first %.2f%%, rest %.2f%%, space %.2f%% (to a letter %.2f%%)",
                   pct(first), pct(rest), pct(space), 100 * Double(spaceLetter) / Double(max(space.n, 1)))
            + String(format: " | rest wrong: other row %d, dead end %d of intact prefix %d | space below view %.2f%%, in strip %.2f%%",
                     vertical, deadEnd, intact, 100 * Double(belowView) / Double(max(space.n, 1)), 100 * Double(inStrip) / Double(max(space.n, 1)))
        }
    }

    /// `words` typed as prose, eight to a line, every key a `thumb` tap through the view; the
    /// app's keyboard (`emoji`) or the extension's (no emoji key: space takes its room).
    private func prose(_ layout: K.Layout, _ words: [String], _ thumb: Thumb, emoji: Bool, passes: Int = 6) -> Tally {
        let kb = K(layout: layout)
        kb.offersEmoji = emoji
        kb.bottomInset = emoji ? K.bottomPadding : K.extensionBottomInset
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: K.keysHeight + kb.bottomInset)
        kb.layoutIfNeeded()
        var centers: [Character: CGPoint] = [:], space = CGRect.zero
        for case let b as UIButton in kb.subviews {
            if let t = b.title(for: .normal), t.count == 1 { centers[Character(t.lowercased())] = CGPoint(x: b.frame.midX, y: b.frame.midY) }
            if b.accessibilityLabel == "space" { space = b.frame }
        }
        let field = Field()
        kb.target = field
        var rng = Seeded(state: 566), tally = Tally(), id = 0, lastDown = CGPoint.zero
        func tap(_ aim: CGPoint, left: Bool) -> String {
            let k: CGFloat = Double.random(in: 0..<1, using: &rng) < thumb.rushed ? 2 : 1
            let down = CGPoint(x: aim.x + (left ? -thumb.side : thumb.side) + rng.normal(thumb.sx * k),
                               y: aim.y + thumb.down + rng.normal(thumb.sy * k))
            let up = CGPoint(x: down.x + rng.normal(thumb.drift), y: down.y + rng.normal(thumb.drift))
            let before = field.text
            lastDown = down
            // Under the extension's view is iOS's own strip: that touch never arrives. The
            // app's keyboard reaches the screen's bottom edge, where a thumb still lands.
            if down.y > kb.bounds.maxY && !emoji { return "" }
            id += 1
            kb.track(.began, id: id, at: CGPoint(x: down.x, y: min(down.y, kb.bounds.maxY - 0.5)))
            kb.track(.ended, id: id, at: CGPoint(x: up.x, y: min(up.y, kb.bounds.maxY - 0.5)))
            if kb.showsEmoji { kb.showEmoji(false) }
            return field.text.hasPrefix(before) ? String(field.text.dropFirst(before.count)) : "⌫"
        }
        for _ in 0..<passes {
            let order = words.shuffled(using: &rng)
            var left = false
            for (i, w) in order.enumerated() {
                if i % 8 == 0 { kb.resetWord(); field.text = "" }
                for (j, c) in w.enumerated() {
                    let center = centers[c]!
                    left = center.x < kb.bounds.midX
                    let prefix = kb.word, intended = String(w.prefix(j))
                    let got = tap(center, left: left).lowercased()
                    let ok = got == String(c)
                    if !ok, j > 0, let g = got.first {
                        let rows = layout.letterRows
                        if rows.firstIndex(where: { $0.contains(g) }) != rows.firstIndex(where: { $0.contains(c) }) { tally.vertical += 1 }
                        if prefix == intended {
                            tally.intact += 1
                            if !(K.dictionaryKnows(prefix + got, language: layout.language) || ShellWords.all.contains { $0.hasPrefix(prefix + got) }) { tally.deadEnd += 1 }
                        }
                    }
                    if j == 0 { tally.first.n += 1; tally.first.wrong += ok ? 0 : 1 } else { tally.rest.n += 1; tally.rest.wrong += ok ? 0 : 1 }
                }
                let right = !left   // the other thumb
                let typed = tap(CGPoint(x: space.midX + (right ? 1 : -1) * space.width / 4, y: space.midY), left: !right)
                tally.space.n += 1
                if lastDown.y > kb.bounds.maxY { tally.belowView += 1 }
                if lastDown.y > space.maxY { tally.inStrip += 1 }
                if typed != " " { tally.space.wrong += 1; tally.spaceLetter += typed.first?.isLetter == true ? 1 : 0 }
            }
        }
        return tally
    }

    /// The numbers for each thumb model, to see which mode dominates. One gate: the
    /// extension's space taps reach it (`extensionBottomInset`; 6 pt lost 4% of them).
    func testProseWithAThumb() {
        for (name, layout, words, emoji) in [("EN app", K.Layout.english, Self.english, true),
                                             ("EN app rarer", .english, Self.rarer, true),
                                             ("EN ext", .english, Self.english, false),
                                             ("BG ext", .bulgarian, Self.bulgarian, false)] {
            for t in Self.thumbs {
                let tally = prose(layout, words, t, emoji: emoji)
                print("thumb \(name), \(t.name): \(tally.line)")
                if !emoji, t.name == "wider" { XCTAssertLessThan(tally.pct(tally.space), 1, name) }
            }
        }
    }

    /// Two words run together, the space between them missed, then a space: what the
    /// extension's autocorrect makes of it (the gate). And a word with one letter slipped to
    /// a neighbor: what it makes of that, so a run-on fix costs no other correction.
    func testRunOnsAndSlipsThroughAutocorrect() {
        let suite = "TypoRateTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let doc = KeyboardExtensionTests.FakeProxy()
        doc.autocapitalizationType = .none
        let kb = K()
        kb.target = doc
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: UserDefaults(suiteName: suite)!)))
        bar.attach(kb)
        func typed(_ s: String) -> String {
            doc.text = ""
            for c in s { kb.press(c == " " ? .space : .char(String(c))) }
            return doc.text
        }
        var rng = Seeded(state: 566), split = 0, slipFixed = 0, slips = 0
        let words = Self.english.filter { $0.count >= 2 }, pairs = 400
        for _ in 0..<pairs {
            let a = words.randomElement(using: &rng)!, b = words.randomElement(using: &rng)!
            if typed(a + b + " ") == a + " " + b + " " { split += 1 }
        }
        let rows = K.Layout.english.letterRows
        for w in words where w.count >= 4 {
            let i = w.index(w.startIndex, offsetBy: 1 + Int.random(in: 0..<(w.count - 1), using: &rng))
            guard let n = rows.joined().filter({ Suggestions.neighbors($0, w[i]) && $0 != w[i] }).randomElement(using: &rng) else { continue }
            var slip = w
            slip.replaceSubrange(i...i, with: String(n))
            slips += 1
            if typed(slip + " ") == w + " " { slipFixed += 1 }
        }
        print(String(format: "autocorrect: run-ons split %.1f%% of %d, slips fixed %.1f%% of %d",
                     100 * Double(split) / Double(pairs), pairs, 100 * Double(slipFixed) / Double(slips), slips))
        XCTAssertGreaterThan(split, pairs * 3 / 4, "run-ons split (none before `Suggestions.split`)")
        withExtendedLifetime(bar) {}
    }
}
