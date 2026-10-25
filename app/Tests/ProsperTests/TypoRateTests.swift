import XCTest
import UIKit
@testable import Prosper

/// The typo harness: common words typed through `track()` on the real layout at 402 pt,
/// each tap at its key's center plus seeded jitter (σ 7 pt sideways and 8 pt up and down,
/// centered 4 pt low, as thumbs land), then the character error rate with `tapLift` as
/// shipped and at 0. Touch correction is on in both.
/// Deterministic: the same seed for both, so they see the same taps.
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
}
