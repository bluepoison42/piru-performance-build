// Apple's automatic grammar agreement, `^[2 dose](inflect: true)` → "2 doses", for Android,
// where Foundation has no morphology engine. The catalogs that carry the markup are English (the
// development language, which every untranslated key falls back to) and Spanish; Chinese is
// translated without it. So the rules here are those two languages' regular plurals, applied to
// the counted phrase: an approximation of Apple's engine that is exact for every phrase the app
// counts, and close for a new one.
//
// Needs nothing past Foundation: android/Compat/Tests/InflectionTests links this file.

import Foundation

nonisolated enum AndroidInflection {
    /// `text` with each `^[run](attributes)` replaced by its run. When the attributes say
    /// `inflect: true`, the run agrees in number with the count it holds.
    ///
    /// `language` is a BCP 47 tag or subtag of the catalog the text came from: `es…` takes the
    /// Spanish rules, anything else the English ones.
    static func resolve(_ text: String, language: String) -> String {
        guard text.contains("^[") else { return text }
        let spanish = language.lowercased().hasPrefix("es")
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "^["),
              let close = rest[open.upperBound...].range(of: "]("),
              let end = rest[close.upperBound...].firstIndex(of: ")") {
            result.append(contentsOf: rest[..<open.lowerBound])
            let run = String(rest[open.upperBound ..< close.lowerBound])
            let attributes = String(rest[close.upperBound ..< end].filter { !$0.isWhitespace }).lowercased()
            result.append(attributes.contains("inflect:true") ? agree(run, spanish: spanish) : run)
            rest = rest[rest.index(after: end)...]
        }
        result.append(contentsOf: rest)
        return result
    }

    /// The run with the phrase after its count made plural, unless the count is exactly one.
    ///
    /// The phrase ends at its first preposition or conjunction ("dose of caffeine", "dosis de
    /// carga"). In English its last word takes the plural; in Spanish every word does, the
    /// adjectives agreeing with the noun, except the invariable ones.
    static func agree(_ run: String, spanish: Bool) -> String {
        var words = run.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let countIndex = words.firstIndex(where: { $0.first?.isNumber == true }) else { return run }
        let digits = words[countIndex].prefix { $0.isNumber }
        guard Int(digits) != 1 else { return run }

        let stops = spanish ? spanishPhraseEnds : englishPhraseEnds
        var phrase: [Int] = []
        for index in words.indices where index > countIndex {
            let core = letters(of: words[index]).lowercased()
            if core.isEmpty { continue }
            if stops.contains(core) { break }
            phrase.append(index)
        }
        if spanish {
            for index in phrase {
                words[index] = pluralizing(words[index], with: spanishPlural)
            }
        } else if let last = phrase.last {
            words[last] = pluralizing(words[last], with: englishPlural)
        }
        return words.joined(separator: " ")
    }

    // MARK: Words

    private static let englishPhraseEnds: Set<String> = [
        "of", "for", "with", "in", "on", "to", "from", "at", "by", "per", "and", "or",
    ]
    private static let spanishPhraseEnds: Set<String> = [
        "de", "del", "a", "al", "en", "con", "por", "para", "sin", "y", "e", "o", "u", "que",
    ]

    /// The word's leading letters; punctuation after them is kept as it is.
    private static func letters(of word: String) -> String {
        String(word.prefix { $0.isLetter })
    }

    /// `word` with `plural` applied to its letters, in the word's own capitalization.
    private static func pluralizing(_ word: String, with plural: (String) -> String) -> String {
        let core = letters(of: word)
        guard !core.isEmpty else { return word }
        let tail = String(word.dropFirst(core.count))
        var inflected = plural(core.lowercased())
        if core.count > 1, core == core.uppercased() {
            inflected = inflected.uppercased()
        } else if core.first?.isUppercase == true {
            inflected = inflected.prefix(1).uppercased() + String(inflected.dropFirst())
        }
        return inflected + tail
    }

    // MARK: English

    private static let englishIrregular: [String: String] = [
        "person": "people", "child": "children", "man": "men", "woman": "women",
        "foot": "feet", "tooth": "teeth", "mouse": "mice", "goose": "geese",
        "life": "lives", "half": "halves", "leaf": "leaves",
    ]
    private static let englishInvariable: Set<String> = [
        "series", "species", "sheep", "fish", "deer", "data", "information", "news",
    ]

    /// The plural of a lowercased English noun: `dose` → `doses`, `entry` → `entries`.
    static func englishPlural(_ word: String) -> String {
        if let irregular = englishIrregular[word] { return irregular }
        if englishInvariable.contains(word) { return word }
        if ["s", "x", "z", "ch", "sh"].contains(where: { word.hasSuffix($0) }) { return word + "es" }
        let characters = Array(word)
        if characters.count > 1, characters[characters.count - 1] == "y", !"aeiou".contains(characters[characters.count - 2]) {
            return String(characters.dropLast()) + "ies"
        }
        return word + "s"
    }

    // MARK: Spanish

    private static let spanishInvariable: Set<String> = ["más", "menos"]
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "á", "é", "í", "ó", "ú", "ü"]
    private static let plainVowel: [Character: Character] = ["á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u"]
    private static let accentedVowel: [Character: Character] = ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú"]

    /// The plural of a lowercased Spanish noun or adjective: `dosis` stays, `interacción` →
    /// `interacciones`, `preparada` → `preparadas`, `examen` → `exámenes`, `vez` → `veces`.
    static func spanishPlural(_ word: String) -> String {
        if spanishInvariable.contains(word) { return word }
        let characters = Array(word)
        guard let last = characters.last, last.isLetter else { return word }
        let groups = vowelGroups(characters)
        let accent = characters.firstIndex { plainVowel[$0] != nil }
        let accentInLastGroup = accent.map { groups.last?.contains($0) == true } ?? false

        switch last {
        case "s", "x":
            // A word ending in -s or -x keeps its form unless its last syllable is stressed:
            // la dosis → las dosis, el autobús → los autobuses, el mes → los meses.
            guard groups.count == 1 || accentInLastGroup else { return word }
            return String(withoutFinalAccent(characters, groups: groups)) + "es"
        case "z":
            return String(characters.dropLast()) + "ces"
        case _ where vowels.contains(last):
            return word + "s"
        case "y" where characters.count > 1 && vowels.contains(characters[characters.count - 2]):
            return word + "es"
        default:
            if accentInLastGroup {
                return String(withoutFinalAccent(characters, groups: groups)) + "es"
            }
            if last == "n", accent == nil, groups.count >= 2 {
                return String(accentingPenultimate(characters, groups: groups)) + "es"
            }
            return word + "es"
        }
    }

    /// The indices of each run of consecutive vowels: a rough count of the word's syllables.
    private static func vowelGroups(_ characters: [Character]) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        for (index, character) in characters.enumerated() {
            if vowels.contains(character) {
                current.append(index)
            } else if !current.isEmpty {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// The word with the written accent of its last syllable removed, as a plural adding a
    /// syllable needs (`interacción` → `interaccion-es`). An accented í or ú beside another vowel
    /// marks a hiatus and stays (`país` → `países`).
    private static func withoutFinalAccent(_ characters: [Character], groups: [[Int]]) -> [Character] {
        guard let group = groups.last else { return characters }
        var result = characters
        for index in group {
            guard let plain = plainVowel[characters[index]] else { continue }
            let hiatus = (plain == "i" || plain == "u") && group.count > 1
            if !hiatus { result[index] = plain }
        }
        return result
    }

    /// The word with a written accent on its second-to-last syllable, which the plural turns into
    /// the third-to-last (`examen` → `exámen-es`). The accent goes on that syllable's open vowel.
    private static func accentingPenultimate(_ characters: [Character], groups: [[Int]]) -> [Character] {
        let group = groups[groups.count - 2]
        let target = group.first { "aeo".contains(characters[$0]) } ?? group.last
        guard let target, let accented = accentedVowel[characters[target]] else { return characters }
        var result = characters
        result[target] = accented
        return result
    }
}
