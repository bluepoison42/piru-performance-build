import Foundation

/// Whether a column writes decimals with a comma ("0,75") or a point ("0.75").
nonisolated struct SpreadsheetNumberStyle: Equatable, Sendable {
    var decimalComma: Bool

    static let point = SpreadsheetNumberStyle(decimalComma: false)
    static let comma = SpreadsheetNumberStyle(decimalComma: true)

    /// Decides from the values' own separators: a comma or point followed by
    /// anything but exactly three digits can only be a decimal mark. When the
    /// column never says, a semicolon-delimited file is taken to be written
    /// with decimal commas, which is why it is semicolon-delimited.
    static func infer(from values: [String], delimiter: Unicode.Scalar) -> SpreadsheetNumberStyle {
        var commaDecimals = 0
        var pointDecimals = 0
        for value in values {
            let characters = Array(value)
            for (index, character) in characters.enumerated() where character == "," || character == "." {
                guard index > 0, characters[index - 1].isASCIIDigit else { continue }
                var digits = 0
                var cursor = index + 1
                while cursor < characters.count, characters[cursor].isASCIIDigit {
                    digits += 1
                    cursor += 1
                }
                guard digits > 0, digits != 3 else { continue }
                if character == "," { commaDecimals += 1 } else { pointDecimals += 1 }
            }
        }
        if commaDecimals != pointDecimals {
            return SpreadsheetNumberStyle(decimalComma: commaDecimals > pointDecimals)
        }
        return SpreadsheetNumberStyle(decimalComma: delimiter == ";")
    }

    /// A number written with digits, a decimal mark, and thousands groups.
    /// "1,500" is 1500 in a decimal-point column and 1.5 in a decimal-comma one;
    /// "0,75" and "0.75" are 0.75 in either.
    func parse(_ text: String) -> Double? {
        var token = text.trimmingCharacters(in: .whitespaces)
        var sign = 1.0
        if token.hasPrefix("-") || token.hasPrefix("−") {
            sign = -1
            token.removeFirst()
        } else if token.hasPrefix("+") {
            token.removeFirst()
        }
        guard !token.isEmpty, token.allSatisfy({ $0.isASCIIDigit || $0 == "," || $0 == "." }),
              token.contains(where: \.isASCIIDigit)
        else { return nil }
        let commas = token.count { $0 == "," }
        let points = token.count { $0 == "." }
        let normalized: String
        if commas > 0, points > 0 {
            let decimal: Character = token.lastIndex(of: ",")! > token.lastIndex(of: ".")! ? "," : "."
            let grouping: Character = decimal == "," ? "." : ","
            guard token.count(where: { $0 == decimal }) == 1 else { return nil }
            normalized = token.replacingOccurrences(of: String(grouping), with: "").replacingOccurrences(of: String(decimal), with: ".")
        } else if commas > 0 {
            normalized = Self.resolve(token, mark: ",", isDecimal: decimalComma)
        } else if points > 0 {
            normalized = Self.resolve(token, mark: ".", isDecimal: !decimalComma)
        } else {
            normalized = token
        }
        return Double(normalized).map { $0 * sign }
    }

    /// One kind of separator: grouping when it repeats or separates exact
    /// groups of three in a column that does not use it as the decimal mark.
    private static func resolve(_ token: String, mark: Character, isDecimal: Bool) -> String {
        let parts = token.split(separator: mark, omittingEmptySubsequences: false)
        let grouped = parts.count > 1 && parts[0].count <= 3 && !parts[0].isEmpty && parts.dropFirst().allSatisfy { $0.count == 3 }
        if parts.count > 2, grouped {
            return parts.joined()
        }
        if grouped, !isDecimal {
            return parts.joined()
        }
        return token.replacingOccurrences(of: String(mark), with: ".")
    }
}

/// A dose read from a cell. `amount` is `nil` when no quantity could be read.
nonisolated struct SpreadsheetDose: Equatable, Sendable {
    var amount: Double?
    /// Piru's spelling of the unit, or the unit as written when Piru has no spelling for it.
    var unit: String?
    var isApproximate = false
    /// Words the parser could not place, kept so nothing the cell said is lost.
    var leftover: String?
}

/// Piru's spelling for unit words: mass and volume units by their symbol,
/// counted forms by one plural label each, so "pil", "pill" and "pastilla"
/// all log as "pills", and "tablet" logs as "tabs" like an inventory count.
nonisolated enum SpreadsheetUnits {
    static func canonical(_ word: String) -> String? {
        let key = word.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let mass = DoseQuantity.massUnit(key) ?? extraMass[key] { return mass.symbol }
        if DoseQuantity.volumeUnit(key) != nil || extraVolume.contains(key) { return "mL" }
        return counts[key]
    }

    /// A unit cell as Piru stores it: its canonical spelling, or as written.
    static func normalized(_ word: String) -> String {
        canonical(word) ?? word.trimmingCharacters(in: .whitespaces)
    }

    private static let extraMass: [String: UnitDoseMass] = [
        "miligramo": .milligrams, "miligramos": .milligrams, "milligramo": .milligrams, "milligramos": .milligrams,
        "milligramm": .milligrams, "milligramme": .milligrams, "milligrammes": .milligrams, "mgr": .milligrams,
        "microgramo": .micrograms, "microgramos": .micrograms, "mikrogramm": .micrograms, "microgramme": .micrograms,
        "gramo": .grams, "gramos": .grams, "gramm": .grams, "gramme": .grams, "grammes": .grams, "gram": .grams,
        "grams": .grams, "gr": .grams, "grammen": .grams,
    ]

    private static let extraVolume: Set<String> = ["mililitro", "mililitros", "milliliter", "millilitre", "millilitres", "milliliters", "mls"]

    private static let counts: [String: String] = {
        let groups: [String: [String]] = [
            "pills": ["pill", "pills", "pil", "pillen", "pilletje", "pilletjes", "pille", "pastilla", "pastillas", "pilule", "pilules"],
            "tabs": ["tab", "tabs", "tablet", "tablets", "tabletten", "tablette", "tablettes", "tableta", "tabletas", "comprimido", "comprimidos", "comprimé", "comprimés"],
            "caps": ["cap", "caps", "capsule", "capsules", "capsula", "capsulas", "cápsula", "cápsulas", "kapsel", "kapseln", "capsuleje"],
            "hits": ["hit", "hits"],
            "joints": ["joint", "joints", "jointje", "jointjes", "porro", "porros"],
            "drops": ["drop", "drops", "druppel", "druppels", "gota", "gotas", "tropfen", "goutte", "gouttes"],
            "puffs": ["puff", "puffs", "hijs", "hijsje", "hijsjes", "trekje", "trekjes", "calada", "caladas", "zug", "züge", "toke", "tokes"],
            "lines": ["line", "lines", "lijn", "lijnen", "lijntje", "lijntjes", "raya", "rayas", "ligne", "lignes"],
            "bumps": ["bump", "bumps"],
            "drinks": ["drink", "drinks", "glas", "glass", "glasses", "glazen", "glaasje", "copa", "copas", "verre", "verres"],
            "IU": ["iu", "ie", "ui", "ie.", "i.u."],
        ]
        var table: [String: String] = [:]
        for (label, spellings) in groups {
            for spelling in spellings {
                table[spelling] = label
            }
        }
        return table
    }()
}

/// Reads a dose as people type it into a spreadsheet: "200 mg", "0,75 joint",
/// "3 kwart pill" (three quarters), "halve pil", "1 1/2 tabs", "2 x 10mg",
/// "~5 mg", "one and a half pills", in English, Dutch, Spanish, German and
/// French. A count with no unit word stays unitless for the caller to fill;
/// a unit word with no count is one of it.
nonisolated enum SpreadsheetDoseParser {
    static func parse(_ text: String, style: SpreadsheetNumberStyle) -> SpreadsheetDose? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var dose = SpreadsheetDose()
        var total: Double?
        var adding = false
        var multiplying = false
        var leftover: [String] = []
        let tokens = tokenize(trimmed.lowercased())

        func apply(_ value: Double, isFraction: Bool, isMixedFraction: Bool = false) {
            guard let current = total else {
                total = value
                return
            }
            if adding || isMixedFraction {
                total = current + value
            } else if multiplying || isFraction || current != 0 {
                total = current * value
            }
            adding = false
            multiplying = false
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case let .number(raw):
                if index + 2 < tokens.count, case .symbol("-") = tokens[index + 1], case let .number(upperRaw) = tokens[index + 2],
                   let lower = number(raw, style: style), let upper = number(upperRaw, style: style), upper > lower {
                    // "1-2 pills": the midpoint, marked as an estimate.
                    apply((lower + upper) / 2, isFraction: false)
                    dose.isApproximate = true
                    index += 3
                    continue
                }
                guard let value = number(raw, style: style) else {
                    leftover.append(raw)
                    break
                }
                let isMixed = raw.contains("/") && value < 1 && total != nil && !multiplying
                apply(value, isFraction: false, isMixedFraction: isMixed)
            case let .word(word):
                if approximateWords.contains(word) {
                    dose.isApproximate = true
                } else if let value = compounds[word] {
                    apply(value, isFraction: false)
                } else if let value = fractions[word] {
                    apply(value, isFraction: true)
                } else if adding, articles.contains(word) {
                    // "two and a half": the article belongs to the fraction.
                    break
                } else if let value = cardinals[word] {
                    apply(value, isFraction: false)
                } else if connectors.contains(word) {
                    if total != nil { adding = true }
                } else if word == "x", total != nil {
                    multiplying = true
                } else if skipWords.contains(word) {
                    break
                } else if dose.unit == nil, total != nil || SpreadsheetUnits.canonical(word) != nil {
                    // After a count any word is its unit ("3 blotters"); before
                    // one, only a word Piru knows as a unit ("pil").
                    dose.unit = SpreadsheetUnits.normalized(word)
                } else {
                    leftover.append(word)
                }
            case let .symbol(symbol):
                switch symbol {
                case "~", "≈", "±": dose.isApproximate = true
                case "+", "&": if total != nil { adding = true }
                case "×", "*": if total != nil { multiplying = true }
                default: break
                }
            }
            index += 1
        }

        if total == nil, dose.unit != nil { total = 1 }
        if let total, total > 0 { dose.amount = total }
        dose.leftover = leftover.isEmpty ? nil : leftover.joined(separator: " ")
        return dose
    }

    /// A number token: decimal, or a fraction "1/2".
    private static func number(_ raw: String, style: SpreadsheetNumberStyle) -> Double? {
        let parts = raw.split(separator: "/")
        if parts.count == 2 {
            guard let numerator = style.parse(String(parts[0])), let denominator = style.parse(String(parts[1])), denominator != 0 else { return nil }
            return numerator / denominator
        }
        return style.parse(raw)
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case number(String)
        case word(String)
        case symbol(Character)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var kind: Character = " " // "n" number, "w" word
        func flush() {
            guard !current.isEmpty else { return }
            if kind == "n" {
                while let last = current.last, !last.isASCIIDigit {
                    current.removeLast()
                }
                if !current.isEmpty { tokens.append(.number(current)) }
            } else {
                tokens.append(.word(current))
            }
            current = ""
        }
        let characters = Array(expandingFractions(text))
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character.isASCIIDigit {
                if kind != "n" { flush() }
                kind = "n"
                current.append(character)
            } else if kind == "n", ",./".contains(character), next?.isASCIIDigit == true {
                current.append(character)
            } else if character == ".", next?.isASCIIDigit == true, current.isEmpty || kind != "w" {
                flush()
                kind = "n"
                current = "0."
            } else if character.isLetter || character == "µ" || (character == "'" && kind == "w") {
                if kind != "w" { flush() }
                kind = "w"
                current.append(character)
            } else {
                flush()
                kind = " "
                if "~≈±+&×*-–".contains(character) {
                    tokens.append(.symbol(character == "–" ? "-" : character))
                }
            }
        }
        flush()
        return tokens
    }

    /// "½" as " 1/2 ", so a vulgar fraction reads like a typed one.
    private static func expandingFractions(_ text: String) -> String {
        let fractions: [Character: String] = ["½": "1/2", "¼": "1/4", "¾": "3/4", "⅓": "1/3", "⅔": "2/3", "⅛": "1/8"]
        var result = ""
        for character in text {
            if let expansion = fractions[character] {
                result += " \(expansion) "
            } else {
                result.append(character)
            }
        }
        return result
    }

    // MARK: - Vocabulary

    static let cardinals: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "een": 1, "één": 1, "eén": 1, "twee": 2, "drie": 3, "vier": 4, "vijf": 5, "zes": 6, "zeven": 7, "acht": 8, "negen": 9, "tien": 10,
        "un": 1, "uno": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10,
        "ein": 1, "eine": 1, "einen": 1, "einer": 1, "eins": 1, "zwei": 2, "drei": 3, "fünf": 5, "sechs": 6, "sieben": 7, "neun": 9, "zehn": 10,
        "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "sept": 7, "huit": 8, "neuf": 9, "dix": 10,
    ]

    static let fractions: [String: Double] = [
        "half": 0.5, "halves": 0.5, "halve": 0.5, "helft": 0.5, "halb": 0.5, "halbe": 0.5, "halben": 0.5, "halbes": 0.5, "halber": 0.5,
        "medio": 0.5, "media": 0.5, "mitad": 0.5, "demi": 0.5, "demie": 0.5,
        "quarter": 0.25, "quarters": 0.25, "kwart": 0.25, "kwartje": 0.25, "cuarto": 0.25, "cuartos": 0.25, "viertel": 0.25,
        "quart": 0.25, "quarts": 0.25,
        "third": 1.0 / 3, "thirds": 1.0 / 3, "derde": 1.0 / 3, "tercio": 1.0 / 3, "drittel": 1.0 / 3, "tiers": 1.0 / 3,
        "eighth": 0.125, "achtste": 0.125,
    ]

    static let compounds: [String: Double] = [
        "anderhalf": 1.5, "anderhalve": 1.5, "anderthalb": 1.5, "eineinhalb": 1.5,
    ]

    static let articles: Set<String> = ["a", "an", "een", "un", "una", "ein", "eine", "une"]

    static let connectors: Set<String> = ["and", "en", "y", "und", "et", "plus"]

    static let skipWords: Set<String> = ["of", "van", "de", "del", "von", "d'", "the", "het", "la", "el", "le", "der", "die", "das"]

    static let approximateWords: Set<String> = [
        "about", "approx", "approximately", "around", "roughly", "circa", "ca", "ish", "ongeveer", "ong", "zo'n", "rond",
        "aprox", "aproximadamente", "unos", "unas", "etwa", "ungefähr", "ungefaehr", "environ",
    ]
}

private nonisolated extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
