import Foundation
@testable import Piru

/// Synthetic sheets for the spreadsheet importer, each in the style of a real
/// layout people keep. No row comes from a real person's log.
enum SpreadsheetFixtures {
    /// An IFTTT → Google Sheets log: "Month dd, yyyy at hh:mmPM" dates, the
    /// Longitude and Latitude labels on the wrong columns, a Location column
    /// holding maps links or a place name, Dutch dose words and comments.
    static let iftttSheet = """
    Date,Longitude,Latitude,Location,Drug,Dose,Comments
    "June 25, 2015 at 11:28PM",52.3531,4.9124,"https://maps.google.com/?q=52.3531,4.9124",2C-D,3 kwart pill,gewoon omdat het kan
    "July 01, 2015 at 01:10AM",52.3702,4.8952,"https://maps.google.com/?q=52.3702,4.8952",Cocaine,200 mg,
    "July 05, 2015 at 11:44PM",,,,EGCg,,slaap
    "July 07, 2015 at 03:35AM",,,,Cannabis,"0,75 joint",gemengd
    "July 10, 2015 at 02:32AM",,,,2C-E,halve pil,
    "July 05, 2015 at 11:35PM",,,,Kratom,5000 mg,zakje opgemaakt
    "July 21, 2015 at 04:45AM",,,Amsterdam,Etizolam,2 mg,slapen
    
    """

    /// A Dutch Excel export: semicolons, decimal commas, a grouped thousand
    /// ("1.250"), day-first dates, separate unit and route columns.
    static let europeanSheet = """
    Datum;Middel;Hoeveelheid;Eenheid;Toediening;Opmerkingen
    13-06-2015 23:28;MDMA;0,5;pil;geslikt;met vrienden
    01-07-2015 01:10;Cocaine;1.250;mg;gesnoven;"veel; te veel"
    02-07-2015 22:00;Kratom;2,5;g;oraal;
    
    """

    /// Date and time in their own columns, one row without a time.
    static let dateTimeSheet = """
    Date,Time,Substance,Amount,Unit
    2024-03-01,08:15,Caffeine,100,mg
    2024-03-01,2:30 PM,Caffeine,80,mg
    2024-03-02,,Caffeine,100,mg
    
    """

    /// Dates as Excel serial day numbers.
    static let serialDateSheet = """
    Date,Drug,Dose
    45352.34375,Caffeine,100 mg
    45353.5,Caffeine,50 mg
    
    """

    /// Spanish headers, day-first dates.
    static let spanishSheet = """
    Fecha,Sustancia,Dosis,Vía,Notas
    02/03/2024 21:00,MDMA,120 mg,oral,con amigos
    15/03/2024 22:30,MDMA,100 mg,oral,
    
    """

    /// Simplified Chinese headers.
    static let chineseSheet = """
    日期,药物,剂量,备注
    2024-03-01 20:00,Caffeine,100 mg,咖啡
    
    """

    /// No header row at all.
    static let headerlessSheet = """
    2024-03-01 08:00,Caffeine,100 mg,morning coffee at the office
    2024-03-02 08:30,Caffeine,120 mg,second cup before the meeting
    
    """

    /// Two exported tabs of one log that overlap by a day.
    static let firstTab = """
    Date,Substance,Dose
    2024-01-01 10:00,Caffeine,100 mg
    2024-01-02 10:00,Caffeine,100 mg
    2024-01-03 10:00,Caffeine,100 mg
    
    """

    static let secondTab = """
    Date,Substance,Dose
    2024-01-03 10:00,Caffeine,100 mg
    2024-01-04 10:00,Caffeine,100 mg
    
    """

    static let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!

    /// A resolver over a handful of names, so inference and conversion tests
    /// don't depend on the bundled catalog.
    static let resolver: SpreadsheetSubstanceResolver = { name in
        let catalog: [String: (String, RouteOfAdministration)] = [
            "2c-d": ("2C-D", .oral), "2c-e": ("2C-E", .oral), "cocaine": ("Cocaine", .insufflation),
            "coke": ("Cocaine", .insufflation), "cannabis": ("Cannabis", .inhalation), "kratom": ("Kratom", .oral),
            "etizolam": ("Etizolam", .oral), "caffeine": ("Caffeine", .oral), "mdma": ("MDMA", .oral),
        ]
        return catalog[name.lowercased()].map { SpreadsheetSubstanceMatch(name: $0.0, defaultUnit: "mg", defaultRoute: $0.1) }
    }

    static func analyze(_ text: String, region: String = "NL") -> SpreadsheetAnalysis {
        SpreadsheetInference.analyze(DelimitedText.read(text), resolver: resolver, region: region)
    }

    static func convert(_ text: String, region: String = "NL") -> (SpreadsheetAnalysis, SpreadsheetConversion) {
        let analysis = analyze(text, region: region)
        let conversion = SpreadsheetConverter.convert(analysis, mapping: analysis.suggestedMapping, resolver: resolver, timeZone: amsterdam)
        return (analysis, conversion)
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in timeZone: TimeZone = amsterdam) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
