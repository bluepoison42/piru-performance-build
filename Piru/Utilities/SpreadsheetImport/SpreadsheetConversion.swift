import Foundation

/// One dose a sheet row becomes, ready to insert.
struct SpreadsheetDoseDraft: Equatable {
    /// The sheet row it came from.
    let row: Int
    /// The catalog's name when the sheet's name resolved, else the name as written.
    var substance: String
    var resolved: Bool
    var amount: Double
    var unit: String
    var route: RouteOfAdministration
    var timestamp: Date
    /// The row gave no time of day, so ``timestamp`` is noon on its date.
    var timeIsInferred = false
    var isApproximate = false
    var isUnknownDose = false
    var notes: String?
    var tags: [String] = []
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
}

/// Why a row produced no dose.
enum SpreadsheetSkipReason: Equatable {
    case noSubstance
    case noDate
    /// The date cell, as written, which no date format reads.
    case unreadableDate(String)
}

struct SpreadsheetSkippedRow: Equatable {
    let row: Int
    let reason: SpreadsheetSkipReason
}

/// Something about the import worth a look before committing it. None stops the import.
enum SpreadsheetWarning: Equatable {
    /// No row settled day/month order, so the mapping's order was assumed.
    case dateOrderAssumed(SpreadsheetDateOrder)
    /// Rows settle the order both ways; the majority was used.
    case dateOrderConflict(dayFirst: Int, monthFirst: Int)
    /// Rows with a number that reads as a decimal or in thousands ("1,250"),
    /// read with the mapping's decimal mark because nothing in the column settles it.
    case decimalStyleAssumed(SpreadsheetNumberStyle, rows: [Int])
    /// Names the catalog doesn't know, kept as written, most frequent first.
    case unresolvedSubstances([String])
    /// The latitude and longitude columns are read the other way round.
    case coordinatesSwapped(SpreadsheetSwapEvidence?)
    /// Rows whose coordinates fall outside the globe's ranges, left without one.
    case coordinatesRejected(rows: [Int])
    /// Rows whose dose couldn't be read, imported as unknown doses with the text in their notes.
    case unreadableDoses(rows: [Int])
    /// Rows with no time of day, placed at noon.
    case missingTimes(rows: [Int])
}

/// What converting a sheet under a mapping yields.
struct SpreadsheetConversion {
    var drafts: [SpreadsheetDoseDraft] = []
    var skipped: [SpreadsheetSkippedRow] = []
    var warnings: [SpreadsheetWarning] = []
    /// The data rows read, header excluded.
    var rowCount = 0
}

/// Turns a sheet's rows into dose drafts under a mapping.
///
/// A row needs a substance and a date to become a dose. Everything else falls
/// back rather than failing: an empty dose cell is an unknown dose; a dose
/// cell no rule reads is an unknown dose whose notes keep the text; a missing
/// unit is the unit column's, then the header's, then the substance's own,
/// and a unit no single amount can be logged in ("mg/kg" in either) makes the
/// dose unknown with its text kept; a missing route is the substance's
/// default; a missing time of day is noon, and said so. Times without an
/// offset are wall-clock times in `timeZone`.
enum SpreadsheetConverter {
    static func convert(
        _ analysis: SpreadsheetAnalysis,
        mapping: SpreadsheetMapping,
        resolver: SpreadsheetSubstanceResolver,
        timeZone: TimeZone = .current,
    ) -> SpreadsheetConversion {
        var result = SpreadsheetConversion(rowCount: analysis.dataRecords.count)
        var resolutions: [String: SpreadsheetSubstanceMatch?] = [:]
        var unresolved: [String: Int] = [:]
        var rejectedCoordinates: [Int] = []
        var unreadableDoses: [Int] = []
        var missingTimes: [Int] = []
        var assumedDecimals: [Int] = []

        let column = { (role: SpreadsheetColumnRole) in mapping.column(for: role) }
        let substanceColumn = column(.substance)
        let dateColumn = column(.date)
        let amountColumn = column(.amount)
        let amountStyle = amountColumn.map { analysis.numberStyle($0, mapping) } ?? .point
        let headerUnit = amountColumn.flatMap { analysis.headerUnits[$0] }
        let decimalColumns = analysis.decimalStyleColumns(mapping)

        for record in analysis.dataRecords {
            // The export's formula guard comes off here, so its text round-trips.
            let cell = { (role: SpreadsheetColumnRole) -> String in
                column(role).map { DelimitedText.restoringFormula(record.cell($0)) } ?? ""
            }

            let typed = cell(.substance)
            guard substanceColumn != nil, !typed.isEmpty else {
                result.skipped.append(SpreadsheetSkippedRow(row: record.row, reason: .noSubstance))
                continue
            }
            let dateText = cell(.date)
            guard let dateColumn, !dateText.isEmpty else {
                result.skipped.append(SpreadsheetSkippedRow(row: record.row, reason: .noDate))
                continue
            }
            let parsedDate = analysis.serialDateColumns.contains(dateColumn)
                ? SpreadsheetDateParser.parseSerial(dateText)
                : SpreadsheetDateParser.parse(dateText, order: mapping.dateOrder) ?? SpreadsheetDateParser.parseSerial(dateText)
            guard var dateValue = parsedDate else {
                result.skipped.append(SpreadsheetSkippedRow(row: record.row, reason: .unreadableDate(dateText)))
                continue
            }
            var timeIsInferred = false
            if !dateValue.hasTime {
                if let time = SpreadsheetDateParser.parseTime(cell(.time)) {
                    dateValue.hour = time.hour
                    dateValue.minute = time.minute
                    dateValue.second = time.second
                } else {
                    dateValue.hour = 12
                    timeIsInferred = true
                    missingTimes.append(record.row)
                }
            }
            guard let timestamp = dateValue.date(in: timeZone) else {
                result.skipped.append(SpreadsheetSkippedRow(row: record.row, reason: .unreadableDate(dateText)))
                continue
            }

            let match: SpreadsheetSubstanceMatch? = if let cached = resolutions[typed] {
                cached
            } else {
                resolver(typed)
            }
            resolutions[typed] = match
            if match == nil { unresolved[typed, default: 0] += 1 }

            var notes: [String] = []
            let doseText = cell(.amount)
            let dose = SpreadsheetDoseParser.parse(doseText, style: amountStyle)
            let statedUnit = dose?.unit.map(SpreadsheetUnitReading.unit)
                ?? SpreadsheetUnits.reading(ofUnitCell: cell(.unit))
                ?? headerUnit
            var unit = match?.defaultUnit ?? "mg"
            var amount = dose?.amount
            var writtenUnit: String?
            switch statedUnit {
            case let .unit(stated):
                unit = stated
            case let .unsupported(expression):
                amount = nil
                writtenUnit = expression
            case nil:
                break
            }
            if !doseText.isEmpty, amount == nil || dose?.leftover != nil {
                if amount == nil { unreadableDoses.append(record.row) }
                let written = writtenUnit.map { "\(doseText) \($0)" } ?? doseText
                notes.append(String(localized: "Dose as written: \(written)"))
            }
            if let amountColumn, decimalColumns.contains(amountColumn),
               SpreadsheetNumberEvidence.collect([doseText]).ambiguous > 0 {
                assumedDecimals.append(record.row)
            }

            let routeText = cell(.route)
            let route = SpreadsheetRouteParser.route(from: routeText) ?? match?.defaultRoute ?? .other
            if !routeText.isEmpty, SpreadsheetRouteParser.route(from: routeText) == nil {
                notes.append(String(localized: "Route as written: \(routeText)"))
            }

            let comment = cell(.notes)
            if !comment.isEmpty { notes.insert(comment, at: 0) }
            let noteText = notes.isEmpty ? nil : notes.joined(separator: "\n")

            var tags = cell(.tags).split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for tag in TagExtractor.extractTags(from: comment) where !tags.contains(tag) {
                tags.append(tag)
            }

            let place = SpreadsheetLocationParser.place(from: cell(.location))
            var coordinate = place?.coordinate
            if let latColumn = column(.latitude), let lngColumn = column(.longitude) {
                let latText = record.cell(latColumn)
                let lngText = record.cell(lngColumn)
                if decimalColumns.contains(latColumn) || decimalColumns.contains(lngColumn),
                   SpreadsheetNumberEvidence.collect([latText, lngText]).ambiguous > 0, assumedDecimals.last != record.row {
                    assumedDecimals.append(record.row)
                }
                if let lat = analysis.numberStyle(latColumn, mapping).parse(latText),
                   let lng = analysis.numberStyle(lngColumn, mapping).parse(lngText) {
                    var labeled = SpreadsheetCoordinate(latitude: lat, longitude: lng)
                    if mapping.swapCoordinates { labeled = labeled.swapped }
                    if labeled.isValid {
                        coordinate = labeled
                    } else {
                        rejectedCoordinates.append(record.row)
                    }
                } else if !latText.isEmpty || !lngText.isEmpty {
                    rejectedCoordinates.append(record.row)
                }
            }

            let approximate = SpreadsheetFlag.parse(cell(.approximate)) ?? false
            result.drafts.append(SpreadsheetDoseDraft(
                row: record.row,
                substance: match?.name ?? typed,
                resolved: match != nil,
                amount: amount ?? 0,
                unit: unit,
                route: route,
                timestamp: timestamp,
                timeIsInferred: timeIsInferred,
                isApproximate: amount != nil && (approximate || dose?.isApproximate == true),
                isUnknownDose: amount == nil,
                notes: noteText,
                tags: tags,
                locationName: place?.name,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude,
            ))
        }

        if let conflict = analysis.dateOrderConflict(mapping) {
            result.warnings.append(.dateOrderConflict(dayFirst: conflict.dayFirst, monthFirst: conflict.monthFirst))
        } else if analysis.dateOrderIsAmbiguous(mapping) {
            result.warnings.append(.dateOrderAssumed(mapping.dateOrder))
        }
        if !assumedDecimals.isEmpty {
            result.warnings.append(.decimalStyleAssumed(mapping.decimalStyle, rows: assumedDecimals))
        }
        if !unresolved.isEmpty {
            let names = unresolved.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            result.warnings.append(.unresolvedSubstances(names))
        }
        if mapping.swapCoordinates {
            result.warnings.append(.coordinatesSwapped(analysis.swapEvidence(mapping)))
        }
        if !rejectedCoordinates.isEmpty { result.warnings.append(.coordinatesRejected(rows: rejectedCoordinates)) }
        if !unreadableDoses.isEmpty { result.warnings.append(.unreadableDoses(rows: unreadableDoses)) }
        if !missingTimes.isEmpty { result.warnings.append(.missingTimes(rows: missingTimes)) }
        return result
    }
}
