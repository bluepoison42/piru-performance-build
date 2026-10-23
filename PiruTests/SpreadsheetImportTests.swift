import Foundation
import SwiftData
import Testing
@testable import Piru

private typealias Fixtures = SpreadsheetFixtures

// MARK: - Delimited text

@Suite("Spreadsheet import — delimited text")
struct DelimitedTextTests {
    @Test
    func `Quoted fields keep delimiters, doubled quotes and line breaks`() {
        let text = "a,b,c\r\n\"x, y\",\"she said \"\"hi\"\"\",\"line one\nline two\"\r\n"
        let records = DelimitedText.parse(text, delimiter: ",")
        #expect(records.count == 2)
        #expect(records[1].cells == ["x, y", "she said \"hi\"", "line one\nline two"])
    }

    @Test
    func `A byte-order mark, CR line endings and blank rows are absorbed`() throws {
        let data = Data(("\u{FEFF}" + "Date,Drug\r,,\r2024-01-01,Caffeine\r\r").utf8)
        let table = try #require(DelimitedText.read(data))
        #expect(table.records.map(\.cells) == [["Date", "Drug"], ["2024-01-01", "Caffeine"]])
        // Row numbers count the blank row, as the spreadsheet shows them.
        #expect(table.records.map(\.row) == [1, 3])
    }

    @Test
    func `A missing final line break still ends the last record`() {
        #expect(DelimitedText.parse("a,b\nc,", delimiter: ",").map(\.cells) == [["a", "b"], ["c", ""]])
    }

    @Test
    func `Delimiter detection prefers the consistent split`() {
        #expect(DelimitedText.detectDelimiter(in: "a\tb\tc\n1\t2\t3\n") == "\t")
        #expect(DelimitedText.detectDelimiter(in: "a,b,c\n1,2,3\n") == ",")
        // Every row also has one decimal comma; the semicolon split is wider.
        #expect(DelimitedText.detectDelimiter(in: "Date;Drug;Dose;Unit\n2015-07-01;Cocaine;0,2;g\n2015-07-02;Kratom;2,5;g\n") == ";")
        #expect(DelimitedText.detectDelimiter(in: Fixtures.europeanSheet) == ";")
        #expect(DelimitedText.detectDelimiter(in: Fixtures.iftttSheet) == ",")
    }

    @Test
    func `UTF-16 text with and without a byte-order mark decodes`() throws {
        let text = "Date\tDrug\n2024-01-01\tCaffeine\n"
        let marked = try #require(text.data(using: .utf16))
        let unmarked = try #require(text.data(using: .utf16LittleEndian))
        #expect(DelimitedText.decode(marked) == text)
        #expect(DelimitedText.decode(unmarked) == text)
    }

    @Test
    func `Writing quotes only the fields that need it`() {
        let csv = DelimitedText.write([["plain", "a,b", "say \"hi\"", "two\nlines"]])
        #expect(csv == "plain,\"a,b\",\"say \"\"hi\"\"\",\"two\nlines\"\r\n")
        #expect(DelimitedText.parse(csv, delimiter: ",").first?.cells == ["plain", "a,b", "say \"hi\"", "two\nlines"])
    }
}

// MARK: - Dates

@Suite("Spreadsheet import — dates")
struct SpreadsheetDateParserTests {
    @Test
    func `The IFTTT format reads with its 12-hour clock`() throws {
        let value = try #require(SpreadsheetDateParser.parse("June 25, 2015 at 11:28PM", order: .dayMonthYear))
        #expect(value == SpreadsheetDateValue(year: 2015, month: 6, day: 25, hour: 23, minute: 28, hasTime: true))
        let midnight = try #require(SpreadsheetDateParser.parse("July 01, 2015 at 12:10AM", order: .dayMonthYear))
        #expect(midnight.hour == 0)
    }

    @Test
    func `ISO 8601 keeps its offset and milliseconds`() throws {
        let value = try #require(SpreadsheetDateParser.parse("2015-06-25T23:28:05.250+02:00", order: .dayMonthYear))
        #expect(value.utcOffset == 7_200)
        #expect(value.millisecond == 250)
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let instant = try #require(value.date(in: newYork))
        #expect(instant == Date(timeIntervalSince1970: 1_435_267_685.25))
        #expect(SpreadsheetDateParser.parse("2024-03-01", order: .dayMonthYear)?.hasTime == false)
        #expect(SpreadsheetDateParser.parse("2024-03-01 08:15:30Z", order: .dayMonthYear)?.utcOffset == 0)
    }

    @Test
    func `Month names read in five languages`() {
        let expected = SpreadsheetDateValue(year: 2015, month: 6, day: 25, hour: 23, minute: 28, hasTime: true)
        for text in ["25. Juni 2015 23:28", "25 de junio de 2015 23:28", "25 juin 2015 23h28", "25 juni 2015 om 23:28", "Thursday, Jun 25 2015 11:28 p.m."] {
            #expect(SpreadsheetDateParser.parse(text, order: .monthDayYear) == expected, "\(text)")
        }
    }

    @Test
    func `Numeric dates follow the column's order unless a number settles it`() {
        #expect(SpreadsheetDateParser.parse("03/04/2024", order: .dayMonthYear)?.month == 4)
        #expect(SpreadsheetDateParser.parse("03/04/2024", order: .monthDayYear)?.month == 3)
        #expect(SpreadsheetDateParser.parse("13/04/2024", order: .monthDayYear)?.month == 4)
        #expect(SpreadsheetDateParser.parse("25.06.15 23:28", order: .dayMonthYear)?.year == 2015)
        let evidence = SpreadsheetDateParser.orderEvidence(["13/04/2024", "03/04/2024", "28/02/2024 10:00", "2024-01-01"])
        #expect(evidence == .init(dayFirst: 2, monthFirst: 0, ambiguous: 1))
    }

    @Test
    func `Serial day numbers and times of day`() {
        #expect(SpreadsheetDateParser.parseSerial("45352.34375") == SpreadsheetDateValue(year: 2024, month: 3, day: 1, hour: 8, minute: 15, hasTime: true))
        #expect(SpreadsheetDateParser.parseSerial("200") == nil)
        #expect(SpreadsheetDateParser.parseTime("2:30 PM") == SpreadsheetTimeValue(hour: 14, minute: 30))
        #expect(SpreadsheetDateParser.parseTime("23:28:15") == SpreadsheetTimeValue(hour: 23, minute: 28, second: 15))
        #expect(SpreadsheetDateParser.parseTime("0.5") == SpreadsheetTimeValue(hour: 12, minute: 0))
        #expect(SpreadsheetDateParser.parseTime("2024-03-01 08:00") == nil)
    }

    @Test
    func `Text that is not a date reads as none`() {
        for text in ["200 mg", "Caffeine", "5", "slaap", "13/13/2024"] {
            #expect(SpreadsheetDateParser.parse(text, order: .dayMonthYear) == nil, "\(text)")
        }
    }
}

// MARK: - Doses

@Suite("Spreadsheet import — doses")
struct SpreadsheetDoseParserTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        let text: String
        let amount: Double?
        let unit: String?
        var approximate = false
        var style = SpreadsheetNumberStyle.point

        var testDescription: String {
            text
        }
    }

    nonisolated static let cases: [Case] = [
        Case(text: "3 kwart pill", amount: 0.75, unit: "pills"),
        Case(text: "halve pil", amount: 0.5, unit: "pills"),
        Case(text: "een halve pil", amount: 0.5, unit: "pills"),
        Case(text: "anderhalve pil", amount: 1.5, unit: "pills"),
        Case(text: "0,75 joint", amount: 0.75, unit: "joints"),
        Case(text: "1 hit", amount: 1, unit: "hits"),
        Case(text: "200 mg", amount: 200, unit: "mg"),
        Case(text: "5000mg", amount: 5_000, unit: "mg"),
        Case(text: "1 1/2 tabs", amount: 1.5, unit: "tabs"),
        Case(text: "½ pill", amount: 0.5, unit: "pills"),
        Case(text: "2 x 10 mg", amount: 20, unit: "mg"),
        Case(text: "~5 mg", amount: 5, unit: "mg", approximate: true),
        Case(text: "ongeveer 2 lijntjes", amount: 2, unit: "lines", approximate: true),
        Case(text: "1-2 pills", amount: 1.5, unit: "pills", approximate: true),
        Case(text: "one and a half pills", amount: 1.5, unit: "pills"),
        Case(text: "dos y media pastillas", amount: 2.5, unit: "pills"),
        Case(text: "eine halbe Tablette", amount: 0.5, unit: "tabs"),
        Case(text: "500 µg", amount: 500, unit: "µg"),
        Case(text: "2 mcg", amount: 2, unit: "µg"),
        Case(text: "5 ml", amount: 5, unit: "mL"),
        Case(text: "1,500 mg", amount: 1_500, unit: "mg"),
        Case(text: "1,500 mg", amount: 1.5, unit: "mg", style: .comma),
        Case(text: "1.250", amount: 1_250, unit: nil, style: .comma),
        Case(text: "3 blotters", amount: 3, unit: "blotters"),
        Case(text: "pil", amount: 1, unit: "pills"),
        Case(text: "100", amount: 100, unit: nil),
        Case(text: "veel", amount: nil, unit: nil),
    ]

    @Test(arguments: cases)
    func `Dose cells read as an amount and unit`(_ testCase: Case) throws {
        let dose = try #require(SpreadsheetDoseParser.parse(testCase.text, style: testCase.style))
        if let amount = testCase.amount {
            #expect(abs((dose.amount ?? -1) - amount) < 1e-9)
        } else {
            #expect(dose.amount == nil)
        }
        #expect(dose.unit == testCase.unit)
        #expect(dose.isApproximate == testCase.approximate)
    }

    @Test
    func `An empty cell is no dose, and unplaced words are kept`() {
        #expect(SpreadsheetDoseParser.parse("  ", style: .point) == nil)
        #expect(SpreadsheetDoseParser.parse("veel", style: .point)?.leftover == "veel")
        #expect(SpreadsheetDoseParser.parse("200 mg poeder", style: .point)?.leftover == "poeder")
    }

    @Test
    func `Number style follows the column's own decimals`() {
        #expect(SpreadsheetNumberStyle.infer(from: ["0,75 joint", "200 mg"], delimiter: ",") == .comma)
        #expect(SpreadsheetNumberStyle.infer(from: ["0.75", "1,500"], delimiter: ";") == .point)
        #expect(SpreadsheetNumberStyle.infer(from: ["1,500"], delimiter: ";") == .comma)
        #expect(SpreadsheetNumberStyle.infer(from: ["1,500"], delimiter: ",") == .point)
    }
}

// MARK: - Locations

@Suite("Spreadsheet import — locations")
struct SpreadsheetLocationTests {
    @Test
    func `Maps links carry a coordinate, latitude first`() {
        let expected = SpreadsheetCoordinate(latitude: 52.358, longitude: 4.868)
        for link in [
            "https://maps.google.com/?q=52.358,4.868",
            "https://www.google.com/maps/place/Vondelpark/@52.358,4.868,15z",
            "https://maps.apple.com/?ll=52.358,4.868&q=Vondelpark",
            "geo:52.358,4.868",
            "https://maps.google.com/?q=52.358%2C4.868",
        ] {
            #expect(SpreadsheetLocationParser.place(from: link)?.coordinate == expected, "\(link)")
        }
    }

    @Test
    func `A place name stays a name`() {
        #expect(SpreadsheetLocationParser.place(from: "Amsterdam") == SpreadsheetPlace(name: "Amsterdam"))
        #expect(SpreadsheetLocationParser.place(from: "https://maps.google.com/?q=Vondelpark+Amsterdam") == SpreadsheetPlace(name: "Vondelpark Amsterdam"))
        #expect(SpreadsheetLocationParser.place(from: "https://maps.google.com/?q=95,200")?.coordinate == nil)
    }

    @Test
    func `Swapped labels are found by range and by maps links`() {
        let amsterdam = SpreadsheetCoordinate(latitude: 52.35, longitude: 4.9)
        // The labels say latitude 4.9, longitude 52.35; the link says otherwise.
        let byLink = SpreadsheetCoordinateSwap.evidence([.init(labeled: amsterdam.swapped, link: amsterdam)])
        #expect(byLink == .mapsLinks(rows: 1))
        let honest = SpreadsheetCoordinateSwap.evidence([.init(labeled: amsterdam, link: amsterdam)])
        #expect(honest == nil)
        // A "latitude" of 151 can only be a longitude (Sydney, -33.87 151.21).
        let sydney = SpreadsheetCoordinate(latitude: 151.21, longitude: -33.87)
        #expect(SpreadsheetCoordinateSwap.evidence([.init(labeled: sydney, link: nil)]) == .outOfRange(rows: 1))
        // No evidence: the labels stand.
        #expect(SpreadsheetCoordinateSwap.evidence([.init(labeled: amsterdam.swapped, link: nil)]) == nil)
    }

    @Test
    func `Route words read in several languages`() {
        #expect(SpreadsheetRouteParser.route(from: "gesnoven") == .insufflation)
        #expect(SpreadsheetRouteParser.route(from: "Oral") == .oral)
        #expect(SpreadsheetRouteParser.route(from: "fumada") == .inhalation)
        #expect(SpreadsheetRouteParser.route(from: "other") == .other)
        #expect(SpreadsheetRouteParser.route(from: "with friends") == nil)
    }
}

// MARK: - Inference

@Suite("Spreadsheet import — column inference")
@MainActor
struct SpreadsheetInferenceTests {
    @Test
    func `The IFTTT sheet maps every column and swaps its coordinates`() {
        let analysis = Fixtures.analyze(Fixtures.iftttSheet)
        #expect(analysis.headerRow == 1)
        #expect(analysis.suggestedMapping.roles == [.date, .longitude, .latitude, .location, .substance, .amount, .notes])
        #expect(analysis.suggestedMapping.swapCoordinates)
        #expect(analysis.swapEvidence(analysis.suggestedMapping) == .mapsLinks(rows: 2))
        #expect(analysis.columns[0].samples.first == "June 25, 2015 at 11:28PM")
        #expect(analysis.columns.allSatisfy { $0.confidence >= 0.9 })
    }

    @Test
    func `A semicolon sheet with decimal commas`() {
        let analysis = Fixtures.analyze(Fixtures.europeanSheet)
        #expect(analysis.table.delimiter == ";")
        #expect(analysis.suggestedMapping.roles == [.date, .substance, .amount, .unit, .route, .notes])
        #expect(analysis.suggestedMapping.dateOrder == .dayMonthYear)
        #expect(analysis.numberStyles[2] == .comma)
    }

    @Test
    func `Separate date and time columns`() {
        let analysis = Fixtures.analyze(Fixtures.dateTimeSheet)
        #expect(analysis.suggestedMapping.roles == [.date, .time, .substance, .amount, .unit])
    }

    @Test
    func `Excel serial dates`() {
        let analysis = Fixtures.analyze(Fixtures.serialDateSheet)
        #expect(analysis.suggestedMapping.roles == [.date, .substance, .amount])
        #expect(analysis.serialDateColumns == [0])
    }

    @Test
    func `Headers in Spanish and Chinese`() {
        let spanish = Fixtures.analyze(Fixtures.spanishSheet)
        #expect(spanish.suggestedMapping.roles == [.date, .substance, .amount, .route, .notes])
        #expect(spanish.suggestedMapping.dateOrder == .dayMonthYear)
        let chinese = Fixtures.analyze(Fixtures.chineseSheet)
        #expect(chinese.suggestedMapping.roles == [.date, .substance, .amount, .notes])
    }

    @Test
    func `A headerless sheet is mapped from its content`() {
        let analysis = Fixtures.analyze(Fixtures.headerlessSheet)
        #expect(analysis.headerRow == nil)
        #expect(analysis.dataRecords.count == 2)
        #expect(analysis.suggestedMapping.roles == [.date, .substance, .amount, .notes])
        #expect(analysis.columns[0].title == SpreadsheetInference.columnLetterTitle(0))
        #expect(analysis.columns.allSatisfy { $0.confidence < 1 })
    }

    @Test
    func `Ambiguous day-month order falls back to the region's convention`() {
        let sheet = "Date,Drug,Dose\n03/04/2024 10:00,Caffeine,100 mg\n"
        #expect(Fixtures.analyze(sheet, region: "US").suggestedMapping.dateOrder == .monthDayYear)
        let european = Fixtures.analyze(sheet, region: "NL")
        #expect(european.suggestedMapping.dateOrder == .dayMonthYear)
        #expect(european.dateOrderIsAmbiguous(european.suggestedMapping))
    }

    @Test
    func `Reassigning a role takes it from the column that had it`() {
        var mapping = Fixtures.analyze(Fixtures.iftttSheet).suggestedMapping
        mapping.assign(.notes, to: 3)
        #expect(mapping.roles[3] == .notes)
        #expect(mapping.roles[6] == .ignore)
    }
}

// MARK: - Conversion

@Suite("Spreadsheet import — conversion")
@MainActor
struct SpreadsheetConversionTests {
    @Test
    func `The IFTTT sheet converts row by row`() throws {
        let (_, conversion) = Fixtures.convert(Fixtures.iftttSheet)
        #expect(conversion.rowCount == 7)
        #expect(conversion.skipped.isEmpty)
        let drafts = Dictionary(uniqueKeysWithValues: conversion.drafts.map { ($0.row, $0) })

        let first = try #require(drafts[2])
        #expect(first.substance == "2C-D")
        #expect(first.amount == 0.75)
        #expect(first.unit == "pills")
        #expect(first.timestamp == Fixtures.date(2015, 6, 25, 23, 28))
        #expect(first.notes == "gewoon omdat het kan")
        #expect(first.latitude == 52.3531)
        #expect(first.longitude == 4.9124)

        let cocaine = try #require(drafts[3])
        #expect(cocaine.amount == 200)
        #expect(cocaine.route == .insufflation)
        #expect(cocaine.notes == nil)

        let unknown = try #require(drafts[4])
        #expect(unknown.isUnknownDose)
        #expect(!unknown.resolved)
        #expect(unknown.substance == "EGCg")

        #expect(drafts[5]?.unit == "joints")
        #expect(drafts[5]?.amount == 0.75)
        #expect(drafts[6]?.amount == 0.5)
        #expect(drafts[8]?.locationName == "Amsterdam")
        #expect(drafts[8]?.latitude == nil)

        #expect(conversion.warnings.contains(.unresolvedSubstances(["EGCg"])))
        #expect(conversion.warnings.contains(.coordinatesSwapped(.mapsLinks(rows: 2))))
    }

    @Test
    func `European rows read decimal commas, grouped thousands and Dutch routes`() {
        let (_, conversion) = Fixtures.convert(Fixtures.europeanSheet)
        #expect(conversion.drafts.map(\.amount) == [0.5, 1_250, 2.5])
        #expect(conversion.drafts.map(\.unit) == ["pills", "mg", "g"])
        #expect(conversion.drafts.map(\.route) == [.oral, .insufflation, .oral])
        #expect(conversion.drafts[0].timestamp == Fixtures.date(2015, 6, 13, 23, 28))
        #expect(conversion.drafts[1].notes == "veel; te veel")
    }

    @Test
    func `A time column completes the date, and a missing time is noon`() {
        let (_, conversion) = Fixtures.convert(Fixtures.dateTimeSheet)
        #expect(conversion.drafts.map(\.timestamp) == [
            Fixtures.date(2024, 3, 1, 8, 15), Fixtures.date(2024, 3, 1, 14, 30), Fixtures.date(2024, 3, 2, 12, 0),
        ])
        #expect(conversion.warnings.contains(.missingTimes(rows: [4])))
    }

    @Test
    func `Serial dates convert to wall-clock times`() {
        let (_, conversion) = Fixtures.convert(Fixtures.serialDateSheet)
        #expect(conversion.drafts.map(\.timestamp) == [Fixtures.date(2024, 3, 1, 8, 15), Fixtures.date(2024, 3, 2, 12, 0)])
        #expect(!conversion.warnings.contains { if case .missingTimes = $0 { true } else { false } })
    }

    @Test
    func `Rows without a substance or a readable date are skipped with a reason`() {
        let sheet = "Date,Drug,Dose\n2024-01-01 10:00,,100 mg\n,Caffeine,100 mg\nsometime,Caffeine,100 mg\n2024-01-02 10:00,Caffeine,100 mg\n"
        let (_, conversion) = Fixtures.convert(sheet)
        #expect(conversion.skipped == [
            SpreadsheetSkippedRow(row: 2, reason: .noSubstance),
            SpreadsheetSkippedRow(row: 3, reason: .noDate),
            SpreadsheetSkippedRow(row: 4, reason: .unreadableDate("sometime")),
        ])
        #expect(conversion.drafts.count == 1)
    }

    @Test
    func `Unreadable doses keep their text, and unknown names are listed by frequency`() {
        let sheet = "Date,Drug,Dose\n2024-01-01 10:00,Mystery,veel\n2024-01-02 10:00,Mystery,1 pil\n2024-01-03 10:00,Other thing,2 mg\n"
        let (_, conversion) = Fixtures.convert(sheet)
        #expect(conversion.drafts[0].isUnknownDose)
        #expect(conversion.drafts[0].notes == String(localized: "Dose as written: veel"))
        #expect(conversion.warnings.contains(.unreadableDoses(rows: [2])))
        #expect(conversion.warnings.contains(.unresolvedSubstances(["Mystery", "Other thing"])))
    }

    @Test
    func `Coordinates out of range are dropped and reported`() {
        let sheet = "Date,Drug,Latitude,Longitude\n2024-01-01 10:00,Caffeine,95,200\n2024-01-02 10:00,Caffeine,52.37,4.89\n"
        let (analysis, conversion) = Fixtures.convert(sheet)
        #expect(!analysis.suggestedMapping.swapCoordinates)
        #expect(conversion.drafts[0].latitude == nil)
        #expect(conversion.drafts[1].latitude == 52.37)
        #expect(conversion.warnings.contains(.coordinatesRejected(rows: [2])))
    }

    @Test
    func `Turning the swap off reads the labels as written`() {
        let analysis = Fixtures.analyze(Fixtures.iftttSheet)
        var mapping = analysis.suggestedMapping
        mapping.swapCoordinates = false
        let conversion = SpreadsheetConverter.convert(analysis, mapping: mapping, resolver: Fixtures.resolver, timeZone: Fixtures.amsterdam)
        #expect(conversion.drafts[0].latitude == 4.9124)
        #expect(!conversion.warnings.contains { if case .coordinatesSwapped = $0 { true } else { false } })
    }
}

// MARK: - Committing and exporting

@Suite("Spreadsheet import — import and export", .serialized)
@MainActor
struct SpreadsheetImportCommitTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(PiruSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        )
    }

    private func drafts(_ text: String) -> [SpreadsheetDoseDraft] {
        Fixtures.convert(text).1.drafts
    }

    @Test
    func `Two overlapping tabs import each dose once`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let container = try makeContainer()
        let context = container.mainContext

        let first = try DataExportImport.importSpreadsheet(drafts(Fixtures.firstTab), context: context, resolver: Fixtures.resolver)
        #expect(first == .init(imported: 3, duplicates: 0))
        #expect(DataExportImport.spreadsheetDuplicateCount(drafts(Fixtures.secondTab), context: context, resolver: Fixtures.resolver) == 1)
        let second = try DataExportImport.importSpreadsheet(drafts(Fixtures.secondTab), context: context, resolver: Fixtures.resolver)
        #expect(second == .init(imported: 1, duplicates: 1))
        let again = try DataExportImport.importSpreadsheet(drafts(Fixtures.firstTab), context: context, resolver: Fixtures.resolver)
        #expect(again == .init(imported: 0, duplicates: 3))

        let doses = try context.fetch(FetchDescriptor<DoseEntry>())
        #expect(doses.count == 4)
        #expect(doses.allSatisfy { $0.session != nil })
    }

    @Test
    func `Imported doses carry every field the draft had`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let container = try makeContainer()
        let context = container.mainContext
        try DataExportImport.importSpreadsheet(drafts(Fixtures.iftttSheet), context: context, resolver: Fixtures.resolver)

        let doses = try context.fetch(FetchDescriptor<DoseEntry>(sortBy: [SortDescriptor(\.timestamp)]))
        #expect(doses.count == 7)
        let first = try #require(doses.first)
        #expect(first.substance == "2C-D")
        #expect(first.amount == 0.75)
        #expect(first.unit == "pills")
        #expect(first.latitude == 52.3531)
        let unknown = try #require(doses.first { $0.substance == "EGCg" })
        #expect(unknown.isUnknownDose)
        #expect(unknown.amountDisplay == "?")
    }

    @Test
    func `The CSV export reads back with every column recognized for certain`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_000_000.123)
        context.insert(DoseEntry(
            substance: "Caffeine", amount: 200, unit: "mg", route: .oral, timestamp: base,
            notes: "first cup, \"strong\"\nwith milk", tags: ["work", "morning"],
            locationName: "Home", latitude: 52.3676, longitude: 4.9041, isApproximate: true,
        ))
        context.insert(DoseEntry(substance: "Melatonin", amount: 0.5, unit: "mg", route: .sublingual, timestamp: base.addingTimeInterval(50_000)))
        context.insert(DoseEntry(substance: "MDMA", amount: 0, unit: "mg", route: .oral, timestamp: base.addingTimeInterval(90_000), isUnknownDose: true))
        try context.save()

        let data = try DataExportImport.spreadsheetCSV(context: context, timeZone: Fixtures.amsterdam)
        let table = try #require(DelimitedText.read(data))
        let analysis = SpreadsheetInference.analyze(table, resolver: SpreadsheetSubstanceMatch.library, region: "NL")
        #expect(analysis.suggestedMapping.roles == [
            .date, .substance, .amount, .unit, .route, .approximate, .notes, .tags, .location, .latitude, .longitude,
        ])
        for column in analysis.columns {
            #expect(column.confidence == 1, "\(column.title)")
        }
        #expect(!analysis.suggestedMapping.swapCoordinates)

        let conversion = SpreadsheetConverter.convert(
            analysis, mapping: analysis.suggestedMapping, resolver: SpreadsheetSubstanceMatch.library, timeZone: Fixtures.amsterdam,
        )
        #expect(conversion.warnings.isEmpty)
        #expect(DataExportImport.spreadsheetDuplicateCount(conversion.drafts, context: context) == 3)

        let fresh = try makeContainer()
        let outcome = try DataExportImport.importSpreadsheet(conversion.drafts, context: fresh.mainContext)
        #expect(outcome == .init(imported: 3, duplicates: 0))
        let doses = try fresh.mainContext.fetch(FetchDescriptor<DoseEntry>(sortBy: [SortDescriptor(\.timestamp)]))
        let caffeine = try #require(doses.first)
        #expect(caffeine.timestamp.msSince1970 == base.msSince1970)
        #expect(caffeine.notes == "first cup, \"strong\"\nwith milk")
        #expect(caffeine.tags == ["work", "morning"])
        #expect(caffeine.isApproximate)
        #expect(caffeine.locationName == "Home")
        #expect(caffeine.latitude == 52.3676)
        #expect(doses[1].amount == 0.5)
        #expect(doses[1].route == .sublingual)
        #expect(doses[2].isUnknownDose)
    }

    @Test
    func `Typed text that would start a formula exports as text and reads back unchanged`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(DoseEntry(
            substance: "Caffeine", amount: 100, unit: "mg", route: .oral, timestamp: base,
            notes: "=SUM(1,2)", locationName: "Times Square", latitude: 40.758, longitude: -73.98,
        ))
        context.insert(DoseEntry(
            substance: "Caffeine", amount: 50, unit: "mg", route: .oral, timestamp: base.addingTimeInterval(3_600),
            notes: "-shaky", tags: ["@home"], locationName: "'s-Hertogenbosch",
        ))
        try context.save()

        let data = try DataExportImport.spreadsheetCSV(context: context, timeZone: Fixtures.amsterdam)
        let table = try #require(DelimitedText.read(data))
        let cells = table.records.map(\.cells)
        #expect(cells[1][6] == "'=SUM(1,2)")
        #expect(cells[2][6] == "'-shaky")
        #expect(cells[2][7] == "'@home")
        // Numbers Piru writes itself stay bare, a negative longitude included.
        #expect(cells[1][10] == "-73.98")
        #expect(cells[1][2] == "100")
        // An apostrophe the person typed is not a guard.
        #expect(cells[2][8] == "'s-Hertogenbosch")

        let analysis = SpreadsheetInference.analyze(table, resolver: SpreadsheetSubstanceMatch.library, region: "NL")
        let conversion = SpreadsheetConverter.convert(
            analysis, mapping: analysis.suggestedMapping, resolver: SpreadsheetSubstanceMatch.library, timeZone: Fixtures.amsterdam,
        )
        #expect(conversion.drafts.map(\.notes) == ["=SUM(1,2)", "-shaky"])
        #expect(conversion.drafts[1].tags == ["@home"])
        #expect(conversion.drafts[1].locationName == "'s-Hertogenbosch")
        #expect(conversion.drafts[0].longitude == -73.98)

        let fresh = try makeContainer()
        try DataExportImport.importSpreadsheet(conversion.drafts, context: fresh.mainContext)
        let notes = try fresh.mainContext.fetch(FetchDescriptor<DoseEntry>(sortBy: [SortDescriptor(\.timestamp)])).map(\.notes)
        #expect(notes == ["=SUM(1,2)", "-shaky"])
    }

    @Test
    func `The formula guard comes off only where it was put`() {
        #expect(DelimitedText.neutralizingFormula("+31 6 1234") == "'+31 6 1234")
        #expect(DelimitedText.neutralizingFormula("plain") == "plain")
        #expect(DelimitedText.restoringFormula("'=1+1") == "=1+1")
        #expect(DelimitedText.restoringFormula("'s nachts") == "'s nachts")
        #expect(DelimitedText.restoringFormula("''=1") == "''=1")
    }

    @Test
    func `Export times carry their own offset`() throws {
        let date = Fixtures.date(2024, 7, 1, 23, 5)
        #expect(DataExportImport.iso8601(date, timeZone: Fixtures.amsterdam) == "2024-07-01T23:05:00+02:00")
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(DataExportImport.iso8601(date.addingTimeInterval(0.25), timeZone: utc) == "2024-07-01T21:05:00.250+00:00")
        #expect(DataExportImport.spreadsheetNumber(200) == "200")
        #expect(DataExportImport.spreadsheetNumber(0.75) == "0.75")
        #expect(DataExportImport.spreadsheetNumber(0.00001) == "0.00001")
    }
}
