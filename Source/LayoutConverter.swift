import Foundation

// 4.3.0 — «ghbdtn» → «привет» and back: the same keys on the English (QWERTY)
// and Russian (ЙЦУКЕН) layouts. Pure, covered by tests.
enum LayoutConverter {
    private static let enLower = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./")
    private static let ruLower = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.")
    private static let enUpper = Array("~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?")
    private static let ruUpper = Array("ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,")
    // Shifted digits that differ between the layouts.
    private static let enDigits = Array("@#$^&")
    private static let ruDigits = Array("\"№;:?")

    static let toRussian: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (a, b) in zip(enLower, ruLower) { map[a] = b }
        for (a, b) in zip(enUpper, ruUpper) { map[a] = b }
        for (a, b) in zip(enDigits, ruDigits) { map[a] = b }
        return map
    }()

    static let toEnglish: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (a, b) in toRussian { map[b] = a }
        return map
    }()

    static func isCyrillic(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }

    static func isLatin(_ c: Character) -> Bool {
        c.isASCII && c.isLetter
    }

    // The converted text and whether it is now Russian. More Latin letters
    // than Cyrillic → it was typed on the English layout by mistake.
    static func convert(_ text: String) -> (text: String, toRussian: Bool) {
        let latin = text.filter(isLatin).count
        let cyrillic = text.filter(isCyrillic).count
        let toRu = latin >= cyrillic && latin > 0
        let map = toRu ? toRussian : toEnglish
        return (String(text.map { map[$0] ?? $0 }), toRu)
    }
}
