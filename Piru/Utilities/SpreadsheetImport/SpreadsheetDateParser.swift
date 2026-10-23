import Foundation

/// Which of the first two numbers in a numeric date is the day.
nonisolated enum SpreadsheetDateOrder: String, CaseIterable, Sendable {
    /// 25/06/2015: most of the world.
    case dayMonthYear
    /// 06/25/2015: the United States and a few others.
    case monthDayYear

    /// The order a person in `region` writes dates in.
    static func conventional(forRegion region: String?) -> SpreadsheetDateOrder {
        let monthFirst: Set = ["US", "PH", "FM", "MH", "PW", "GU", "AS", "PR", "VI", "UM", "BZ"]
        return region.map { monthFirst.contains($0.uppercased()) } == true ? .monthDayYear : .dayMonthYear
    }
}

/// A date read from a cell: the wall-clock fields it named, and the offset
/// when it carried one. A missing time leaves `hasTime` false so a separate
/// time column can fill it.
nonisolated struct SpreadsheetDateValue: Equatable, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var hour = 0
    var minute = 0
    var second = 0
    var millisecond = 0
    var hasTime = false
    /// Seconds east of UTC, when the cell stated a zone ("Z", "+02:00").
    var utcOffset: Int?

    /// Whether the day exists in its month on the Gregorian calendar, leap years
    /// included. `Calendar.date(from:)` rolls 30 February over to 1 March
    /// rather than refusing it, so every parsed date is checked here first.
    var isValidDay: Bool {
        guard (1 ... 12).contains(month), day >= 1 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= lengths[month - 1]
    }

    /// The instant, reading wall-clock fields in `timeZone` unless the cell named its own offset.
    func date(in timeZone: TimeZone) -> Date? {
        guard isValidDay else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcOffset.flatMap(TimeZone.init(secondsFromGMT:)) ?? timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let whole = calendar.date(from: components) else { return nil }
        return whole.addingTimeInterval(Double(millisecond) / 1_000)
    }
}

/// A time of day read from a cell with no date.
nonisolated struct SpreadsheetTimeValue: Equatable, Sendable {
    var hour: Int
    var minute: Int
    var second = 0
}

/// Parses the date and time spellings spreadsheets hold: ISO 8601 with or
/// without an offset; IFTTT/Google Sheets' "June 25, 2015 at 11:28PM"; month
/// names in English, Dutch, Spanish, German and French; numeric day/month
/// orders, decided per column; 12- and 24-hour clocks with or without seconds;
/// and Excel/Sheets serial day numbers.
nonisolated enum SpreadsheetDateParser {
    /// Serial day numbers from 1970 to 2100, read as dates only in a column
    /// whose every value falls in this range.
    static let serialRange = 25_569.0 ... 73_051.0

    /// Parses `text`, resolving an ambiguous numeric order with `order`.
    static func parse(_ text: String, order: SpreadsheetDateOrder) -> SpreadsheetDateValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let iso = parseISO(trimmed) { return iso }
        return parseGeneral(trimmed, order: order)
    }

    /// A serial day number (days since 1899-12-30, the fraction the time of day).
    static func parseSerial(_ text: String) -> SpreadsheetDateValue? {
        guard let serial = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              serialRange.contains(serial)
        else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let epoch = utc.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        let seconds = (serial * 86_400).rounded()
        let fields = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: epoch.addingTimeInterval(seconds))
        guard let year = fields.year, let month = fields.month, let day = fields.day else { return nil }
        return SpreadsheetDateValue(
            year: year, month: month, day: day,
            hour: fields.hour ?? 0, minute: fields.minute ?? 0, second: fields.second ?? 0,
            hasTime: serial.truncatingRemainder(dividingBy: 1) != 0,
        )
    }

    /// A time with no date: "23:28", "11:28 PM", "23h28", or a day fraction
    /// (Excel's 0.979).
    static func parseTime(_ text: String) -> SpreadsheetTimeValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let fraction = Double(trimmed.replacingOccurrences(of: ",", with: ".")), (0 ..< 1).contains(fraction), trimmed.contains(where: { $0 == "." || $0 == "," }) {
            let seconds = Int((fraction * 86_400).rounded())
            return SpreadsheetTimeValue(hour: seconds / 3_600 % 24, minute: seconds / 60 % 60, second: seconds % 60)
        }
        var tokens = tokenize(trimmed)
        guard let time = extractTime(&tokens), tokens.allSatisfy(\.isFiller) else { return nil }
        return time
    }

    // MARK: - Order evidence

    /// How the numeric dates in a column vote on day/month order: a first
    /// number above 12 can only be a day, a second above 12 only a day too.
    struct OrderEvidence: Equatable {
        var dayFirst = 0
        var monthFirst = 0
        var ambiguous = 0
    }

    static func orderEvidence(_ values: [String]) -> OrderEvidence {
        var evidence = OrderEvidence()
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard parseISO(trimmed) == nil else { continue }
            var tokens = tokenize(trimmed.lowercased())
            _ = extractTime(&tokens)
            let numbers = tokens.compactMap(\.number)
            guard tokens.allSatisfy({ $0.number != nil || $0.isFiller }), numbers.count == 3,
                  numbers[0].digits <= 2, numbers[1].digits <= 2
            else { continue }
            let (first, second) = (numbers[0].value, numbers[1].value)
            if first > 12, second <= 12 {
                evidence.dayFirst += 1
            } else if second > 12, first <= 12 {
                evidence.monthFirst += 1
            } else if first <= 12, second <= 12 {
                evidence.ambiguous += 1
            }
        }
        return evidence
    }

    // MARK: - ISO 8601

    /// `yyyy-MM-dd`, optionally `T` or a space and `HH:mm[:ss[.SSS]]`, optionally `Z` or `±HH[:]MM`.
    private static func parseISO(_ text: String) -> SpreadsheetDateValue? {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func number(_ width: ClosedRange<Int>) -> Int? {
            var digits = 0
            var value = 0
            while index < scalars.count, digits < width.upperBound, ("0" ... "9").contains(scalars[index]) {
                value = value * 10 + Int(scalars[index].value - 48)
                digits += 1
                index += 1
            }
            return width.contains(digits) ? value : nil
        }
        func expect(_ scalar: Unicode.Scalar) -> Bool {
            guard index < scalars.count, scalars[index] == scalar else { return false }
            index += 1
            return true
        }
        guard let year = number(4 ... 4), expect("-"), let month = number(1 ... 2), expect("-"), let day = number(1 ... 2),
              (1 ... 12).contains(month), (1 ... 31).contains(day)
        else { return nil }
        var value = SpreadsheetDateValue(year: year, month: month, day: day)
        guard value.isValidDay else { return nil }
        guard index < scalars.count else { return value }
        guard expect("T") || expect(" "), let hour = number(1 ... 2), expect(":"), let minute = number(2 ... 2),
              hour < 24, minute < 60
        else { return nil }
        value.hour = hour
        value.minute = minute
        value.hasTime = true
        if expect(":") {
            guard let second = number(2 ... 2), second < 61 else { return nil }
            value.second = min(second, 59)
            if expect(".") || expect(",") {
                let start = index
                guard let fraction = number(1 ... 9) else { return nil }
                let digits = index - start
                value.millisecond = Int((Double(fraction) / pow(10, Double(digits)) * 1_000).rounded())
            }
        }
        while index < scalars.count, scalars[index] == " " {
            index += 1
        }
        guard index < scalars.count else { return value }
        if expect("Z") || expect("z") {
            value.utcOffset = 0
        } else if scalars[index] == "+" || scalars[index] == "-" {
            let sign = scalars[index] == "-" ? -1 : 1
            index += 1
            guard let hours = number(2 ... 2) else { return nil }
            _ = expect(":")
            let minutes = number(2 ... 2) ?? 0
            value.utcOffset = sign * (hours * 3_600 + minutes * 60)
        }
        return index == scalars.count ? value : nil
    }

    // MARK: - General form

    private static func parseGeneral(_ text: String, order: SpreadsheetDateOrder) -> SpreadsheetDateValue? {
        var tokens = tokenize(text.lowercased())
        let time = extractTime(&tokens)
        guard tokens.allSatisfy({ $0.number != nil || $0.month != nil || $0.isFiller || $0.weekday }) else { return nil }
        let numbers = tokens.compactMap(\.number)
        let month = tokens.lazy.compactMap(\.month).first

        var value: SpreadsheetDateValue
        if let month {
            // "June 25, 2015", "25 juni 2015", "25. Juni 2015": the year is the
            // four-digit number, or else the last.
            guard numbers.count == 2 else { return nil }
            let yearIndex = numbers.firstIndex { $0.digits == 4 } ?? 1
            let year = numbers[yearIndex]
            let day = numbers[1 - yearIndex]
            guard day.digits <= 2, (1 ... 31).contains(day.value), let fullYear = fullYear(year) else { return nil }
            value = SpreadsheetDateValue(year: fullYear, month: month, day: day.value)
        } else {
            guard numbers.count == 3 else { return nil }
            if numbers[0].digits == 4 {
                value = SpreadsheetDateValue(year: numbers[0].value, month: numbers[1].value, day: numbers[2].value)
            } else {
                guard let year = fullYear(numbers[2]), numbers[0].digits <= 2, numbers[1].digits <= 2 else { return nil }
                let (first, second) = (numbers[0].value, numbers[1].value)
                let dayFirst: Bool = if first > 12 {
                    true
                } else if second > 12 {
                    false
                } else {
                    order == .dayMonthYear
                }
                value = SpreadsheetDateValue(year: year, month: dayFirst ? second : first, day: dayFirst ? first : second)
            }
        }
        guard value.isValidDay, (1900 ... 2200).contains(value.year) else { return nil }
        if let time {
            value.hour = time.hour
            value.minute = time.minute
            value.second = time.second
            value.hasTime = true
        }
        return value
    }

    /// A two-digit year lands in the century that puts it no later than next year.
    private static func fullYear(_ number: Token.Number) -> Int? {
        switch number.digits {
        case 4: return number.value
        case 2:
            let thisYear = Calendar(identifier: .gregorian).component(.year, from: .now) % 100
            return number.value <= thisYear + 1 ? 2_000 + number.value : 1_900 + number.value
        default: return nil
        }
    }

    // MARK: - Tokens

    struct Token: Equatable {
        struct Number: Equatable {
            let value: Int
            let digits: Int
        }

        enum Kind: Equatable {
            case number(Number)
            case word(String)
            case separator(Character)
        }

        let kind: Kind

        var number: Number? {
            if case let .number(number) = kind { return number }
            return nil
        }

        var word: String? {
            if case let .word(word) = kind { return word }
            return nil
        }

        var month: Int? {
            word.flatMap { SpreadsheetDateParser.months[$0] }
        }

        var weekday: Bool {
            word.map { SpreadsheetDateParser.weekdays.contains($0) } ?? false
        }

        /// Punctuation and the joining words around a date ("at", "om", "um").
        var isFiller: Bool {
            switch kind {
            case .separator: true
            case let .word(word): SpreadsheetDateParser.fillers.contains(word)
            case .number: false
            }
        }
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsDigit = false
        func flush() {
            guard !current.isEmpty else { return }
            if currentIsDigit, let value = Int(current) {
                tokens.append(Token(kind: .number(.init(value: value, digits: current.count))))
            } else {
                tokens.append(Token(kind: .word(current)))
            }
            current = ""
        }
        for character in text {
            if character.isNumber, character.isASCII {
                if !currentIsDigit { flush() }
                currentIsDigit = true
                current.append(character)
            } else if character.isLetter {
                if currentIsDigit { flush() }
                currentIsDigit = false
                current.append(character)
            } else {
                flush()
                if !character.isWhitespace {
                    tokens.append(Token(kind: .separator(character)))
                }
            }
        }
        flush()
        return tokens
    }

    /// Removes the first clock time from `tokens` and returns it: `H:mm[:ss]`
    /// or `HHhmm`, with an optional am/pm marker.
    static func extractTime(_ tokens: inout [Token]) -> SpreadsheetTimeValue? {
        for start in tokens.indices {
            guard let hour = tokens[start].number, hour.digits <= 2 else { continue }
            var index = start + 1
            var minute: Int?
            if index + 1 < tokens.count, tokens[index].kind == .separator(":"), let m = tokens[index + 1].number, m.digits == 2 {
                minute = m.value
                index += 2
            } else if index + 1 < tokens.count, tokens[index].word == "h", let m = tokens[index + 1].number, m.digits == 2 {
                // "23h28" tokenizes as 23, "h", 28.
                minute = m.value
                index += 2
            }
            guard let minute, minute < 60 else { continue }
            var second = 0
            if index + 1 < tokens.count, tokens[index].kind == .separator(":"), let s = tokens[index + 1].number, s.digits == 2, s.value < 61 {
                second = min(s.value, 59)
                index += 2
                // Fractional seconds: ".123".
                if index + 1 < tokens.count, tokens[index].kind == .separator("."), tokens[index + 1].number != nil {
                    index += 2
                }
            }
            var hourValue = hour.value
            if let marker = meridiem(tokens, at: &index) {
                guard (1 ... 12).contains(hourValue) else { return nil }
                hourValue = hourValue % 12 + (marker ? 12 : 0)
            }
            guard hourValue < 24 else { continue }
            tokens.removeSubrange(start ..< index)
            return SpreadsheetTimeValue(hour: hourValue, minute: minute, second: second)
        }
        return nil
    }

    /// Consumes an am/pm marker at `index` ("pm", "p.m.", "PM"): `true` for pm.
    private static func meridiem(_ tokens: [Token], at index: inout Int) -> Bool? {
        guard index < tokens.count, let word = tokens[index].word else { return nil }
        switch word {
        case "am", "pm":
            index += 1
            return word == "pm"
        case "a", "p":
            // "a.m." / "p.m."
            guard index + 2 < tokens.count, tokens[index + 1].kind == .separator("."), tokens[index + 2].word == "m" else { return nil }
            index += 3
            if index < tokens.count, tokens[index].kind == .separator(".") { index += 1 }
            return word == "p"
        default:
            return nil
        }
    }

    // MARK: - Vocabulary

    static let months: [String: Int] = {
        let names: [[String]] = [
            ["january", "jan", "januari", "enero", "ene", "januar", "janvier", "janv", "jänner"],
            ["february", "feb", "februari", "febrero", "februar", "février", "fevrier", "févr", "fevr", "fév"],
            ["march", "mar", "maart", "mrt", "marzo", "märz", "maerz", "mars", "mär"],
            ["april", "apr", "abril", "abr", "avril", "avr"],
            ["may", "mei", "mayo", "mai"],
            ["june", "jun", "juni", "junio", "juin"],
            ["july", "jul", "juli", "julio", "juillet", "juil"],
            ["august", "aug", "augustus", "agosto", "ago", "août", "aout"],
            ["september", "sep", "sept", "septiembre", "setiembre", "septembre"],
            ["october", "oct", "oktober", "okt", "octubre", "octobre"],
            ["november", "nov", "noviembre", "novembre"],
            ["december", "dec", "diciembre", "dic", "dezember", "dez", "décembre", "decembre", "déc"],
        ]
        var table: [String: Int] = [:]
        for (index, spellings) in names.enumerated() {
            for spelling in spellings {
                table[spelling] = index + 1
            }
        }
        return table
    }()

    static let weekdays: Set<String> = [
        "monday", "mon", "tuesday", "tue", "tues", "wednesday", "wed", "thursday", "thu", "thurs", "friday", "fri",
        "saturday", "sat", "sunday", "sun", "maandag", "ma", "dinsdag", "di", "woensdag", "wo", "donderdag", "do",
        "vrijdag", "vr", "zaterdag", "za", "zondag", "zo", "lunes", "martes", "miércoles", "miercoles", "jueves",
        "viernes", "sábado", "sabado", "domingo", "montag", "dienstag", "mittwoch", "donnerstag", "freitag",
        "samstag", "sonntag", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
    ]

    static let fillers: Set<String> = ["at", "om", "a", "las", "la", "um", "à", "de", "del", "den", "der", "le", "the", "of", "t", "u", "uhr", "h"]
}
