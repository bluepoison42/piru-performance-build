import Foundation

/// Whether a column writes decimals with a comma ("0,75") or a point ("0.75").
nonisolated struct SpreadsheetNumberStyle: Hashable, Sendable {
    var decimalComma: Bool

    static let point = SpreadsheetNumberStyle(decimalComma: false)
    static let comma = SpreadsheetNumberStyle(decimalComma: true)

    /// The column's own evidence when it settles the mark one way, else the
    /// majority, else ``fallback(delimiter:decimalSeparator:)``.
    static func infer(
        from values: [String], delimiter: Unicode.Scalar, decimalSeparator: String? = Locale.current.decimalSeparator,
    ) -> SpreadsheetNumberStyle {
        let evidence = SpreadsheetNumberEvidence.collect(values)
        return evidence.settled ?? evidence.majority ?? fallback(delimiter: delimiter, decimalSeparator: decimalSeparator)
    }

    /// The mark assumed when the values never say: a semicolon-delimited file
    /// is written with decimal commas, which is why spreadsheets delimit it
    /// with semicolons; otherwise the device's own decimal separator.
    static func fallback(delimiter: Unicode.Scalar, decimalSeparator: String?) -> SpreadsheetNumberStyle {
        if delimiter == ";" { return .comma }
        return SpreadsheetNumberStyle(decimalComma: decimalSeparator == ",")
    }

    /// A number written with digits, a decimal mark, and thousands groups.
    /// "1,500" is 1500 in a decimal-point column and 1.5 in a decimal-comma one;
    /// "0,75", "0.75" and "0,125" are decimals in either.
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
    /// A leading group never starts with 0, so "0,125" is always a decimal.
    private static func resolve(_ token: String, mark: Character, isDecimal: Bool) -> String {
        let parts = token.split(separator: mark, omittingEmptySubsequences: false)
        let grouped = parts.count > 1 && SpreadsheetNumberEvidence.isLeadingGroup(parts[0])
            && parts.dropFirst().allSatisfy { $0.count == 3 }
        if parts.count > 2, grouped {
            return parts.joined()
        }
        if grouped, !isDecimal {
            return parts.joined()
        }
        return token.replacingOccurrences(of: String(mark), with: ".")
    }
}

/// How a column's numbers vote on their decimal mark.
///
/// A separator can only be a decimal mark when anything but exactly three
/// digits follows it, when the digits before it start with 0 or run past
/// three, or when the other separator groups thousands before it ("1.250,5").
/// It can only group thousands when it repeats ("1,250,000"). What is left
/// ("1,250", "1.250") reads either way and is counted as ambiguous.
nonisolated struct SpreadsheetNumberEvidence: Equatable, Sendable {
    var commaDecimals = 0
    var pointDecimals = 0
    var ambiguous = 0

    /// The mark the evidence names when all of it points one way.
    var settled: SpreadsheetNumberStyle? {
        if commaDecimals > 0, pointDecimals == 0 { return .comma }
        if pointDecimals > 0, commaDecimals == 0 { return .point }
        return nil
    }

    /// The mark more of the evidence names, when one is named more often.
    var majority: SpreadsheetNumberStyle? {
        commaDecimals == pointDecimals ? nil : SpreadsheetNumberStyle(decimalComma: commaDecimals > pointDecimals)
    }

    static func collect(_ values: [String]) -> SpreadsheetNumberEvidence {
        var evidence = SpreadsheetNumberEvidence()
        for value in values {
            for run in numericRuns(value) {
                evidence.count(run)
            }
        }
        return evidence
    }

    /// Whether `group` can open a thousands-grouped number: one to three
    /// digits, the first not 0.
    static func isLeadingGroup(_ group: Substring) -> Bool {
        (1 ... 3).contains(group.count) && group.first != "0"
    }

    private mutating func count(_ run: String) {
        let separators = run.filter { $0 == "," || $0 == "." }
        guard let first = separators.first, let last = separators.last else { return }
        if first != last {
            if separators.count(where: { $0 == last }) == 1 { vote(last) }
            return
        }
        let parts = run.split(separator: first, omittingEmptySubsequences: false)
        if parts.count > 2 {
            if Self.isLeadingGroup(parts[0]), parts.dropFirst().allSatisfy({ $0.count == 3 }) {
                vote(first == "," ? "." : ",")
            }
            return
        }
        if parts[1].count != 3 || !Self.isLeadingGroup(parts[0]) {
            vote(first)
        } else {
            ambiguous += 1
        }
    }

    private mutating func vote(_ decimal: Character) {
        if decimal == "," { commaDecimals += 1 } else { pointDecimals += 1 }
    }

    /// The runs of digits in `text`, each with the commas and points that sit
    /// between two of its digits.
    private static func numericRuns(_ text: String) -> [String] {
        let characters = Array(text)
        var runs: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if character.isASCIIDigit {
                current.append(character)
            } else if character == "," || character == ".", current.last?.isASCIIDigit == true,
                      index + 1 < characters.count, characters[index + 1].isASCIIDigit {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
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

/// A unit stated outside the dose cell: in a unit column, or in the dose
/// column's header.
nonisolated enum SpreadsheetUnitReading: Equatable, Sendable {
    /// A unit doses are logged in, in Piru's spelling.
    case unit(String)
    /// A unit expression no single amount can be logged in ("mg/kg"), as written.
    case unsupported(String)
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

    /// A unit column's cell: its unit in Piru's spelling with any stated basis
    /// ("mg (freebase)"), ``SpreadsheetUnitReading/unsupported(_:)`` for a rate
    /// or concentration ("mg/kg"), and anything else as written.
    static func reading(ofUnitCell text: String) -> SpreadsheetUnitReading? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let dose = SpreadsheetDoseParser.parse(trimmed, style: .point), let unit = dose.unit else {
            return .unit(normalized(trimmed))
        }
        if dose.amount == nil { return .unsupported(trimmed) }
        return .unit(dose.leftover == nil ? unit : trimmed)
    }

    /// A mass or volume unit named in a column header: "Dose (mg)", "Amount µg",
    /// "Dose (mg freebase)". A unit expression Piru can't hold a dose in
    /// ("Dose (mg/kg)", "Dose in mg per kg") reads as
    /// ``SpreadsheetUnitReading/unsupported(_:)`` so the column's bare numbers
    /// are never taken to be in a plain unit.
    static func reading(ofHeader header: String) -> SpreadsheetUnitReading? {
        guard let expression = unitExpression(in: header),
              let dose = SpreadsheetDoseParser.parse(expression, style: .point), let unit = dose.unit,
              DoseQuantity.massUnit(unit) != nil || DoseQuantity.basisMassUnit(unit) != nil || unit == "mL"
        else { return nil }
        return dose.amount == nil ? .unsupported(expression) : .unit(unit)
    }

    /// The part of a header that names a unit: the last parenthesized or
    /// bracketed group, else everything from the first word that opens with a
    /// mass or volume unit.
    private static func unitExpression(in header: String) -> String? {
        if let close = header.lastIndex(where: { $0 == ")" || $0 == "]" }),
           let open = header[..<close].lastIndex(where: { $0 == "(" || $0 == "[" }) {
            return String(header[header.index(after: open) ..< close]).trimmingCharacters(in: .whitespaces)
        }
        let words = header.split(whereSeparator: \.isWhitespace)
        guard let first = words.firstIndex(where: { word in
            let letters = String(word.prefix { $0.isLetter || $0 == "µ" || $0 == "μ" })
            return canonical(letters).map { DoseQuantity.massUnit($0) != nil || $0 == "mL" } ?? false
        }) else { return nil }
        return words[first...].joined(separator: " ")
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
///
/// A stated basis stays on the unit, the way the catalog writes one: "5 mg
/// (freebase)" is 5 of "mg (freebase)", which ``DoseQuantity`` compares only
/// with the same unit. Sums convert between units of one kind ("0.1 g + 50 mg"
/// is 150 mg). What Piru can't hold as a single amount leaves `amount` empty,
/// so the cell imports as an unknown dose with its text kept: a rate or
/// concentration ("5 mg/kg", "10 mg per ml", "5%"), any other qualifier in
/// parentheses after the unit ("5 mg (absorbed)"), a sum across kinds of unit
/// ("2 mg + 1 pill"), and a second number or unit with nothing joining it to
/// the first ("1 pill 50 mg").
nonisolated enum SpreadsheetDoseParser {
    /// One added part of a dose: its number and, once named, its unit.
    private struct Term {
        var value: Double
        var unit: String?
    }

    static func parse(_ text: String, style: SpreadsheetNumberStyle) -> SpreadsheetDose? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var dose = SpreadsheetDose()
        var terms: [Term] = []
        // The term being read: its number, unit, and stated basis.
        var total: Double?
        var unit: String?
        var basis: String?
        var adding = false
        var multiplying = false
        var unreadable = false
        var lastWasUnit = false
        // Words inside parentheses right after the unit, while they are read.
        var qualifier: [String]?
        var leftover: [String] = []
        let tokens = tokenize(joiningBasisWords(trimmed.lowercased()))

        func closeTerm() {
            if let total {
                terms.append(Term(value: total, unit: unit.map { unit in basis.map { "\(unit) (\($0))" } ?? unit }))
            }
            total = nil
            unit = nil
            basis = nil
        }

        func apply(_ value: Double, isFraction: Bool, isMixedFraction: Bool = false) {
            defer {
                adding = false
                multiplying = false
            }
            guard let current = total else {
                total = value
                return
            }
            if adding {
                if unit != nil {
                    closeTerm()
                    total = value
                } else {
                    total = current + value
                }
            } else if multiplying {
                total = current * value
            } else if unit != nil {
                unreadable = true
            } else if isMixedFraction {
                total = current + value
            } else if isFraction || current != 0 {
                total = current * value
            }
        }

        func closeQualifier() {
            guard let words = qualifier else { return }
            qualifier = nil
            guard !words.isEmpty else { return }
            if basis == nil, let named = basisWords[words.joined(separator: " ")], unit.flatMap(DoseQuantity.massUnit) != nil {
                basis = named
            } else {
                unreadable = true
            }
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let followsUnit = lastWasUnit
            lastWasUnit = false
            if qualifier != nil {
                switch token {
                case .symbol(")"): closeQualifier()
                case let .word(word), let .number(word): qualifier?.append(word)
                case .symbol: break
                }
                index += 1
                continue
            }
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
                } else if unit != nil, perWords.contains(word) {
                    unreadable = true
                } else if unit != nil, basis == nil, let named = basisWords[word], unit.flatMap(DoseQuantity.massUnit) != nil {
                    basis = named
                } else if unit == nil, total != nil || (terms.isEmpty && SpreadsheetUnits.canonical(word) != nil) {
                    // After a count any word is its unit ("3 blotters"); before
                    // one, only a word Piru knows as a unit ("pil").
                    unit = SpreadsheetUnits.normalized(word)
                    lastWasUnit = true
                } else if unit != nil, SpreadsheetUnits.canonical(word) != nil {
                    unreadable = true
                } else {
                    leftover.append(word)
                }
            case let .symbol(symbol):
                switch symbol {
                case "~", "≈", "±": dose.isApproximate = true
                case "+", "&": if total != nil { adding = true }
                case "×", "*": if total != nil { multiplying = true }
                case "/": if unit != nil { unreadable = true }
                case "%": unreadable = true
                case "(": if followsUnit { qualifier = [] }
                default: break
                }
            }
            index += 1
        }
        closeQualifier()

        if total == nil, unit != nil, terms.isEmpty { total = 1 }
        closeTerm()
        let combined = combine(terms)
        dose.unit = combined?.unit ?? terms.lazy.compactMap(\.unit).first
        if !unreadable, let amount = combined?.amount, amount > 0 { dose.amount = amount }
        dose.leftover = leftover.isEmpty ? nil : leftover.joined(separator: " ")
        return dose
    }

    /// The terms of a sum as one amount: as written when they share a unit (a
    /// term with none takes the others'), converted to the finest of their
    /// units when they are masses in different units, and `nil` across kinds
    /// or when a unitless term sits among several units.
    private static func combine(_ terms: [Term]) -> (amount: Double, unit: String?)? {
        guard !terms.isEmpty else { return nil }
        let units = terms.compactMap(\.unit)
        let distinct = Set(units)
        if distinct.count <= 1 {
            return (terms.map(\.value).reduce(0, +), units.first)
        }
        guard units.count == terms.count else { return nil }
        let quantities = terms.map { DoseQuantity($0.value, unit: $0.unit ?? "") }
        guard Set(quantities.map(\.family)).count == 1 else { return nil }
        let finest = quantities.min { lhs, rhs in
            guard case let .mass(left) = lhs, case let .mass(right) = rhs else { return false }
            return left.unit.converter.baseUnitValue(fromValue: 1) < right.unit.converter.baseUnitValue(fromValue: 1)
        }
        guard let target = finest?.unitSymbol else { return nil }
        var sum = 0.0
        for quantity in quantities {
            guard let value = quantity.value(in: target) else { return nil }
            sum += value
        }
        return (sum, target)
    }

    /// "free base" and "free-base" as the one word "freebase".
    private static func joiningBasisWords(_ text: String) -> String {
        text.replacingOccurrences(of: "free-base", with: "freebase").replacingOccurrences(of: "free base", with: "freebase")
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
                if "~≈±+&×*-–/%()".contains(character) {
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

    /// Words that make the amount a rate ("5 mg per kg", "pro Tag").
    static let perWords: Set<String> = ["per", "pro", "por", "par", "each", "every"]

    /// The bases a mass can be stated on, in the catalog's spelling.
    static let basisWords: [String: String] = [
        "freebase": "freebase", "base": "base", "salt": "salt", "zout": "salt", "sal": "salt", "salz": "salt", "sel": "salt",
        "hcl": "hydrochloride", "hydrochloride": "hydrochloride",
    ]

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
