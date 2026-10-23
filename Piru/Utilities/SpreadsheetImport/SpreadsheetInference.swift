import Foundation

/// A catalog substance a sheet's name resolved to, with what a dose of it
/// defaults to when the sheet leaves the unit or route out.
struct SpreadsheetSubstanceMatch: Equatable {
    let name: String
    let defaultUnit: String
    let defaultRoute: RouteOfAdministration
}

/// Resolves a typed substance name, alias included, or answers `nil`.
typealias SpreadsheetSubstanceResolver = (String) -> SpreadsheetSubstanceMatch?

extension SpreadsheetSubstanceMatch {
    /// Resolution through ``SubstanceLibrary``, custom substances and relabels
    /// included. Await ``SubstanceStore/ensureAllLoaded()`` before calling it.
    static let library: SpreadsheetSubstanceResolver = { name in
        SubstanceLibrary.lookup(name).map {
            SpreadsheetSubstanceMatch(name: $0.name, defaultUnit: $0.defaultUnit, defaultRoute: $0.defaultRoute)
        }
    }
}

/// One column as the mapping screen shows it.
struct SpreadsheetColumn: Identifiable, Equatable {
    let index: Int
    /// The header cell, or a spreadsheet-style letter when the sheet has no header.
    let title: String
    /// The first few distinct values.
    let samples: [String]
    let inferredRole: SpreadsheetColumnRole
    /// How sure the inference is of ``inferredRole``, 0–1.
    let confidence: Double

    var id: Int {
        index
    }
}

/// A sheet read and understood: where its data starts, what each column
/// appears to hold, and the mapping suggested from that.
struct SpreadsheetAnalysis {
    let table: DelimitedTable
    /// The record holding the column labels, or `nil` for a sheet with none.
    let headerRow: Int?
    let dataRecords: [DelimitedRecord]
    let columns: [SpreadsheetColumn]
    fileprivate(set) var suggestedMapping: SpreadsheetMapping
    /// Per column: how its numbers write decimals.
    let numberStyles: [SpreadsheetNumberStyle]
    /// Per column: how its numeric dates vote on day/month order.
    let dateOrderEvidence: [SpreadsheetDateParser.OrderEvidence]
    /// Per column: a unit named in its header ("Dose (mg)").
    let headerUnits: [String?]
    /// Per column: every value is a serial day number.
    let serialDateColumns: Set<Int>

    /// Whether the date column, as `mapping` assigns it, gives no row that
    /// settles day/month order.
    func dateOrderIsAmbiguous(_ mapping: SpreadsheetMapping) -> Bool {
        guard let column = mapping.column(for: .date) else { return false }
        let evidence = dateOrderEvidence[column]
        return evidence.dayFirst == 0 && evidence.monthFirst == 0 && evidence.ambiguous > 0
    }

    /// Whether the date column has rows settling the order both ways.
    func dateOrderConflict(_ mapping: SpreadsheetMapping) -> SpreadsheetDateParser.OrderEvidence? {
        guard let column = mapping.column(for: .date) else { return nil }
        let evidence = dateOrderEvidence[column]
        return evidence.dayFirst > 0 && evidence.monthFirst > 0 ? evidence : nil
    }

    /// The evidence that the latitude and longitude columns `mapping` names
    /// are labeled the wrong way round (``SpreadsheetCoordinateSwap``).
    func swapEvidence(_ mapping: SpreadsheetMapping) -> SpreadsheetSwapEvidence? {
        guard let latitude = mapping.column(for: .latitude), let longitude = mapping.column(for: .longitude) else { return nil }
        let location = mapping.column(for: .location)
        let samples = dataRecords.compactMap { record -> SpreadsheetCoordinateSwap.Sample? in
            guard let lat = numberStyles[latitude].parse(record.cell(latitude)),
                  let lng = numberStyles[longitude].parse(record.cell(longitude))
            else { return nil }
            let link = location.flatMap { SpreadsheetLocationParser.place(from: record.cell($0))?.coordinate }
            return SpreadsheetCoordinateSwap.Sample(labeled: SpreadsheetCoordinate(latitude: lat, longitude: lng), link: link)
        }
        return SpreadsheetCoordinateSwap.evidence(samples)
    }
}

/// Works out what a sheet's columns hold.
///
/// Each column gets a score per role from two sources:
/// - **Header** (``SpreadsheetColumnRole/headerScore(_:)``): 1 for a known
///   header word or phrase in any of six languages, 0.6 when one word of a
///   longer header is one, 0 otherwise.
/// - **Content**: the share of the column's non-empty values that read as that
///   role. Dates and times by parse rate, amounts by dose parse rate,
///   substances by how many resolve in the catalog, units and routes by
///   vocabulary, coordinates by range, location by maps links.
///
/// With a header match, confidence is the mean of the two for a role whose
/// values can be checked, and the header score alone for free text (notes,
/// place names, tags) or an empty column. Without one, it is the content score
/// scaled by the role's ``SpreadsheetColumnRole/contentOnlyWeight``, so
/// content alone never reaches certainty, and a column whose header names a
/// role outright is only a candidate for the roles its header names. Pairs
/// are then assigned greedily,
/// most confident first, each role and each column once; a column whose best
/// remaining score is under ``threshold`` is ignored.
enum SpreadsheetInference {
    static let threshold = 0.35
    private static let sampleLimit = 400

    static func analyze(
        _ table: DelimitedTable,
        resolver: @escaping SpreadsheetSubstanceResolver,
        region: String? = Locale.current.region?.identifier,
    ) -> SpreadsheetAnalysis {
        let headerRow = detectHeader(table.records)
        let headerIndex = headerRow.flatMap { row in table.records.firstIndex { $0.row == row } }
        let dataRecords = headerIndex.map { Array(table.records[($0 + 1)...]) } ?? table.records
        let header = headerIndex.map { table.records[$0] }
        let width = table.columnCount

        var columns: [SpreadsheetColumn] = []
        var styles: [SpreadsheetNumberStyle] = []
        var evidence: [SpreadsheetDateParser.OrderEvidence] = []
        var headerUnits: [String?] = []
        var serialColumns = Set<Int>()
        var candidates: [(column: Int, role: SpreadsheetColumnRole, confidence: Double)] = []
        var resolverCache: [String: Bool] = [:]

        for column in 0 ..< width {
            let values = dataRecords.prefix(sampleLimit).map { $0.cell(column) }.filter { !$0.isEmpty }
            let title = header?.cell(column) ?? ""
            let style = SpreadsheetNumberStyle.infer(from: values, delimiter: table.delimiter)
            styles.append(style)
            evidence.append(SpreadsheetDateParser.orderEvidence(values))
            headerUnits.append(headerUnit(title))
            let profile = ContentProfile(values: values, style: style) { name in
                if let known = resolverCache[name] { return known }
                let resolved = resolver(name) != nil
                resolverCache[name] = resolved
                return resolved
            }
            if profile.isSerialDates { serialColumns.insert(column) }
            // A header that names a role outright limits the column to the
            // roles its header names; content then only confirms or doubts.
            let namesRole = SpreadsheetColumnRole.assignable.contains { $0.headerScore(title) == 1 }
            for role in SpreadsheetColumnRole.assignable where role != .ignore {
                if namesRole, role.headerScore(title) == 0 { continue }
                let confidence = confidence(role: role, header: title, profile: profile)
                if confidence >= threshold {
                    candidates.append((column, role, confidence))
                }
            }
            columns.append(SpreadsheetColumn(
                index: column,
                title: title.isEmpty ? columnLetterTitle(column) : title,
                samples: Array(values.uniqued(by: \.self).prefix(3)),
                inferredRole: .ignore,
                confidence: 0,
            ))
        }

        var roles = Array(repeating: SpreadsheetColumnRole.ignore, count: width)
        var confidences = Array(repeating: 0.0, count: width)
        let order = SpreadsheetColumnRole.assignable
        candidates.sort {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.column != $1.column { return $0.column < $1.column }
            return order.firstIndex(of: $0.role)! < order.firstIndex(of: $1.role)!
        }
        var taken = Set<SpreadsheetColumnRole>()
        for candidate in candidates where roles[candidate.column] == .ignore && !taken.contains(candidate.role) {
            roles[candidate.column] = candidate.role
            confidences[candidate.column] = candidate.confidence
            taken.insert(candidate.role)
        }
        if header == nil, !taken.contains(.notes), let notes = longTextColumn(dataRecords, roles: roles) {
            roles[notes] = .notes
            confidences[notes] = 0.4
        }
        columns = columns.map { column in
            SpreadsheetColumn(
                index: column.index, title: column.title, samples: column.samples,
                inferredRole: roles[column.index], confidence: confidences[column.index],
            )
        }

        var mapping = SpreadsheetMapping(roles: roles, dateOrder: .dayMonthYear, swapCoordinates: false)
        if let dateColumn = mapping.column(for: .date) {
            let votes = evidence[dateColumn]
            mapping.dateOrder = if votes.dayFirst == votes.monthFirst {
                SpreadsheetDateOrder.conventional(forRegion: region)
            } else {
                votes.dayFirst > votes.monthFirst ? .dayMonthYear : .monthDayYear
            }
        }
        var analysis = SpreadsheetAnalysis(
            table: table, headerRow: headerRow, dataRecords: dataRecords, columns: columns, suggestedMapping: mapping,
            numberStyles: styles, dateOrderEvidence: evidence, headerUnits: headerUnits, serialDateColumns: serialColumns,
        )
        analysis.suggestedMapping.swapCoordinates = analysis.swapEvidence(mapping) != nil
        return analysis
    }

    static func confidence(role: SpreadsheetColumnRole, header: String, profile: ContentProfile) -> Double {
        let headerScore = header.isEmpty ? 0 : role.headerScore(header)
        if headerScore > 0 {
            guard role.hasContentTest, !profile.values.isEmpty else { return headerScore }
            return 0.5 * headerScore + 0.5 * profile.score(role)
        }
        return role.contentOnlyWeight * profile.score(role, contentOnly: true)
    }

    // MARK: - Header detection

    /// The row number of the header record: the first of the first five
    /// records in which at least two cells, and a third of the non-empty ones,
    /// name a role. Failing that, the first record is a header when none of
    /// its cells reads as a date or number while some column below it mostly
    /// does. Otherwise the sheet has no header.
    static func detectHeader(_ records: [DelimitedRecord]) -> Int? {
        for record in records.prefix(5) {
            let cells = record.cells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !cells.isEmpty else { continue }
            let named = cells.count { cell in SpreadsheetColumnRole.assignable.contains { $0.headerScore(cell) > 0 } }
            if named >= min(2, cells.count), named * 3 >= cells.count {
                return record.row
            }
        }
        guard let first = records.first, records.count > 1 else { return nil }
        let rest = records.dropFirst().prefix(50)
        func isTyped(_ value: String) -> Bool {
            SpreadsheetNumberStyle.point.parse(value) != nil
                || SpreadsheetDateParser.parse(value, order: .dayMonthYear) != nil
                || SpreadsheetDateParser.parseTime(value) != nil
        }
        guard !first.cells.contains(where: { isTyped($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        for column in first.cells.indices {
            let values = rest.map { $0.cell(column) }.filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            if Double(values.count(where: isTyped)) / Double(values.count) >= 0.6 {
                return first.row
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// A unit named in a header: "Dose (mg)", "Amount µg".
    static func headerUnit(_ header: String) -> String? {
        let words = header.lowercased().split { !$0.isLetter && $0 != "µ" && $0 != "μ" }
        for word in words.reversed() {
            if let unit = SpreadsheetUnits.canonical(String(word)), DoseQuantity.massUnit(unit) != nil || unit == "mL" {
                return unit
            }
        }
        return nil
    }

    /// For a sheet with no header: the unassigned column of the longest
    /// sentences, which is what a notes column looks like.
    private static func longTextColumn(_ records: [DelimitedRecord], roles: [SpreadsheetColumnRole]) -> Int? {
        var best: (column: Int, length: Double)?
        for column in roles.indices where roles[column] == .ignore {
            let values = records.prefix(sampleLimit).map { $0.cell(column) }.filter { !$0.isEmpty }
            guard values.count * 4 >= max(1, records.prefix(sampleLimit).count),
                  values.allSatisfy({ $0.contains(where: \.isLetter) })
            else { continue }
            let length = Double(values.map(\.count).reduce(0, +)) / Double(values.count)
            if length >= 8, length > (best?.length ?? 0) {
                best = (column, length)
            }
        }
        return best?.column
    }

    /// "Column A", "Column B", … "Column AA".
    static func columnLetterTitle(_ index: Int) -> String {
        var letters = ""
        var value = index
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + value % 26))) + letters
            value = value / 26 - 1
        } while value >= 0
        return String(localized: "Column \(letters)")
    }
}

/// What a column's values read as, computed once and scored per role.
struct ContentProfile {
    let values: [String]
    let style: SpreadsheetNumberStyle
    private let resolves: (String) -> Bool

    init(values: [String], style: SpreadsheetNumberStyle, resolves: @escaping (String) -> Bool) {
        self.values = values
        self.style = style
        self.resolves = resolves
    }

    /// Every value is a serial day number in 1970–2100.
    var isSerialDates: Bool {
        !values.isEmpty && values.allSatisfy { SpreadsheetDateParser.parseSerial($0) != nil }
    }

    /// The share of values reading as `role`. `contentOnly` asks more of
    /// coordinates (decimal places), since range alone fits many numbers.
    func score(_ role: SpreadsheetColumnRole, contentOnly: Bool = false) -> Double {
        guard !values.isEmpty else { return 0 }
        func rate(_ test: (String) -> Double) -> Double {
            values.map(test).reduce(0, +) / Double(values.count)
        }
        switch role {
        case .date:
            let text = rate { value in
                SpreadsheetDateParser.parse(value, order: .dayMonthYear) != nil || SpreadsheetDateParser.parse(value, order: .monthDayYear) != nil ? 1 : 0
            }
            return max(text, isSerialDates ? 0.75 : 0)
        case .time:
            return rate { SpreadsheetDateParser.parseTime($0) != nil ? 1 : 0 }
        case .amount:
            return rate { value in
                guard let dose = SpreadsheetDoseParser.parse(value, style: style), dose.amount != nil else { return 0 }
                if dose.unit != nil { return 1 }
                // A bare number with many decimal places is more often a coordinate.
                return decimals(value) >= 3 ? 0.3 : 1
            }
        case .unit:
            return rate { SpreadsheetUnits.canonical($0) != nil ? 1 : 0 }
        case .route:
            return rate { SpreadsheetRouteParser.route(from: $0) != nil ? 1 : 0 }
        case .substance:
            return rate { resolves($0) ? 1 : 0 }
        case .latitude:
            return coordinateRate(limit: 90, contentOnly: contentOnly)
        case .longitude:
            return coordinateRate(limit: 180, contentOnly: contentOnly)
        case .location:
            return rate { value in
                SpreadsheetLocationParser.isLink(value) && SpreadsheetLocationParser.place(from: value)?.coordinate != nil ? 1 : 0
            }
        case .approximate:
            return rate { SpreadsheetFlag.parse($0) != nil ? 1 : 0 }
        case .notes, .tags, .ignore:
            return 0
        }
    }

    private func coordinateRate(limit: Double, contentOnly: Bool) -> Double {
        let scores = values.map { value -> Double in
            guard let number = style.parse(value), abs(number) <= limit else { return 0 }
            if contentOnly { return decimals(value) >= 2 ? 1 : 0 }
            return 1
        }
        return scores.reduce(0, +) / Double(values.count)
    }

    private func decimals(_ value: String) -> Int {
        guard let mark = value.lastIndex(where: { $0 == "." || $0 == "," }) else { return 0 }
        return value[value.index(after: mark)...].count(where: \.isNumber)
    }
}

/// Reads yes/no cells in the languages headers are matched in.
enum SpreadsheetFlag {
    static func parse(_ text: String) -> Bool? {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        if truthy.contains(key) { return true }
        if falsy.contains(key) { return false }
        return nil
    }

    private static let truthy: Set<String> = ["yes", "y", "true", "1", "x", "✓", "✔", "ja", "j", "sí", "si", "s", "oui", "o", "wahr", "waar", "是", "~"]
    private static let falsy: Set<String> = ["no", "n", "false", "0", "nee", "nein", "non", "falso", "onwaar", "否", "-"]
}
