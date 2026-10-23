import Foundation

/// The import screens' words for roles, warnings and skipped rows.
extension SpreadsheetColumnRole {
    var title: String {
        switch self {
        case .ignore: String(localized: "Not Imported")
        case .date: String(localized: "Date")
        case .time: String(localized: "Time")
        case .substance: String(localized: "Substance")
        case .amount: String(localized: "Dose")
        case .unit: String(localized: "Unit")
        case .route: String(localized: "Route")
        case .notes: String(localized: "Notes")
        case .location: String(localized: "Location")
        case .latitude: String(localized: "Latitude")
        case .longitude: String(localized: "Longitude")
        case .approximate: String(localized: "Approximate")
        case .tags: String(localized: "Tags")
        }
    }
}

extension SpreadsheetDateOrder {
    var title: String {
        switch self {
        case .dayMonthYear: String(localized: "Day/Month/Year")
        case .monthDayYear: String(localized: "Month/Day/Year")
        }
    }
}

enum SpreadsheetImportCopy {
    /// How sure the guess for a column is, in words.
    static func confidence(_ value: Double) -> String {
        if value >= 0.9 { return String(localized: "Recognized") }
        if value >= 0.6 { return String(localized: "Likely") }
        return String(localized: "Guessed")
    }

    static func warning(_ warning: SpreadsheetWarning) -> String {
        switch warning {
        case let .dateOrderAssumed(order):
            String(localized: "No date in the file settles which number is the day, so dates are read as \(order.title).")
        case let .dateOrderConflict(dayFirst, monthFirst):
            String(localized: "Dates disagree on their order: \(dayFirst) read day first, \(monthFirst) month first. Check the date order.")
        case let .unresolvedSubstances(names):
            String(localized: "Not in Piru's library, kept as written: \(list(names)).")
        case let .coordinatesSwapped(evidence):
            switch evidence {
            case .mapsLinks:
                String(localized: "Latitude and longitude are read the other way round, because the sheet's own map links put them that way.")
            case .outOfRange:
                String(localized: "Latitude and longitude are read the other way round, because the latitude column has values past 90°.")
            case nil:
                String(localized: "Latitude and longitude are read the other way round.")
            }
        case let .coordinatesRejected(rows):
            String(localized: "Coordinates outside the map were left off: rows \(rowList(rows)).")
        case let .unreadableDoses(rows):
            String(localized: "Doses Piru couldn't read are imported as unknown doses, with the text kept in their notes: rows \(rowList(rows)).")
        case let .missingTimes(rows):
            String(localized: "Rows with no time of day are placed at noon: rows \(rowList(rows)).")
        }
    }

    static func skipped(_ row: SpreadsheetSkippedRow) -> String {
        switch row.reason {
        case .noSubstance:
            String(localized: "Row \(row.row): no substance")
        case .noDate:
            String(localized: "Row \(row.row): no date")
        case let .unreadableDate(text):
            String(localized: "Row \(row.row): “\(text)” isn't a date Piru can read")
        }
    }

    static func swapFooter(_ evidence: SpreadsheetSwapEvidence?) -> String {
        switch evidence {
        case .mapsLinks:
            String(localized: "The sheet's map links put latitude and longitude the other way round from its column labels.")
        case .outOfRange:
            String(localized: "The latitude column has values past 90°, which only a longitude can have.")
        case nil:
            String(localized: "Turn this on if places land in the wrong part of the world.")
        }
    }

    /// Up to eight names, then how many more.
    private static func list(_ names: [String]) -> String {
        let shown = names.prefix(8).joined(separator: ", ")
        guard names.count > 8 else { return shown }
        return String(localized: "\(shown) and \(names.count - 8) more")
    }

    /// Up to ten row numbers, then how many more.
    private static func rowList(_ rows: [Int]) -> String {
        let shown = rows.prefix(10).map(String.init).joined(separator: ", ")
        guard rows.count > 10 else { return shown }
        return String(localized: "\(shown) and \(rows.count - 10) more")
    }
}
