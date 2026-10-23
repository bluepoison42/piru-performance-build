import Foundation

/// A latitude/longitude pair in degrees.
nonisolated struct SpreadsheetCoordinate: Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    /// Within the globe's ranges and away from (0, 0), the value an app writes
    /// when it has no fix.
    var isValid: Bool {
        (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude) && !(latitude == 0 && longitude == 0)
    }

    var swapped: SpreadsheetCoordinate {
        SpreadsheetCoordinate(latitude: longitude, longitude: latitude)
    }

    /// Whether the two points are the same place to about a kilometer.
    func matches(_ other: SpreadsheetCoordinate) -> Bool {
        abs(latitude - other.latitude) < 0.01 && abs(longitude - other.longitude) < 0.01
    }
}

/// What a location cell holds: a coordinate from a maps link, a place name, or both.
nonisolated struct SpreadsheetPlace: Equatable, Sendable {
    var name: String?
    var coordinate: SpreadsheetCoordinate?
}

/// Reads location cells: place names, and the links Google Maps, Apple Maps
/// and `geo:` URIs write, which carry the coordinate as `?q=lat,lng`, `ll=`,
/// `@lat,lng` or `geo:lat,lng`, always latitude first.
nonisolated enum SpreadsheetLocationParser {
    static func place(from text: String) -> SpreadsheetPlace? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isLink(trimmed) else { return SpreadsheetPlace(name: trimmed) }
        let decoded = (trimmed.removingPercentEncoding ?? trimmed).replacingOccurrences(of: "+", with: " ")
        if let coordinate = linkCoordinate(decoded) {
            return SpreadsheetPlace(coordinate: coordinate)
        }
        // A link that searches for a place by name: `?q=Vondelpark`.
        if let query = queryValue(decoded, keys: ["q", "query", "address"]), !query.isEmpty {
            return SpreadsheetPlace(name: query)
        }
        return SpreadsheetPlace()
    }

    static func isLink(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("geo:")
            || lower.hasPrefix("maps.") || lower.hasPrefix("www.") || lower.hasPrefix("goo.gl/")
    }

    /// The first `lat,lng` after a marker that introduces one.
    private static func linkCoordinate(_ link: String) -> SpreadsheetCoordinate? {
        let lower = link.lowercased()
        let markers = ["geo:", "@", "?q=", "&q=", "?query=", "&query=", "?ll=", "&ll=", "?sll=", "&sll=", "?center=", "&center=", "?daddr=", "&daddr=", "?destination=", "&destination=", "/place/", "/search/"]
        for marker in markers {
            var searchStart = lower.startIndex
            while let range = lower.range(of: marker, range: searchStart ..< lower.endIndex) {
                if let coordinate = pair(in: lower[range.upperBound...]) {
                    return coordinate
                }
                searchStart = range.upperBound
            }
        }
        return nil
    }

    /// `lat,lng` at the start of `text`, both decimal numbers.
    private static func pair(in text: Substring) -> SpreadsheetCoordinate? {
        var cursor = text.startIndex
        func number() -> Double? {
            while cursor < text.endIndex, text[cursor] == " " {
                cursor = text.index(after: cursor)
            }
            let start = cursor
            if cursor < text.endIndex, text[cursor] == "-" || text[cursor] == "+" {
                cursor = text.index(after: cursor)
            }
            while cursor < text.endIndex, text[cursor].isNumber || text[cursor] == "." {
                cursor = text.index(after: cursor)
            }
            return Double(text[start ..< cursor])
        }
        guard let latitude = number() else { return nil }
        guard cursor < text.endIndex, text[cursor] == "," else { return nil }
        cursor = text.index(after: cursor)
        guard let longitude = number() else { return nil }
        let coordinate = SpreadsheetCoordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }

    private static func queryValue(_ link: String, keys: [String]) -> String? {
        guard let questionMark = link.firstIndex(of: "?") else { return nil }
        for item in link[link.index(after: questionMark)...].split(separator: "&") {
            let parts = item.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, keys.contains(parts[0].lowercased()) else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// Why the importer decided a sheet's latitude and longitude labels are swapped.
nonisolated enum SpreadsheetSwapEvidence: Equatable, Sendable {
    /// The column labeled latitude holds values beyond ±90°, which only a longitude can take.
    case outOfRange(rows: Int)
    /// The sheet's own maps links put the coordinate the other way round.
    case mapsLinks(rows: Int)
}

/// Decides whether a sheet's latitude and longitude columns are labeled the
/// wrong way round. Both orders of most real coordinates are valid numbers
/// (Amsterdam, 52.35 N 4.90 E, read swapped is a point in the Gulf of Guinea),
/// so the labels are only overruled by evidence in the sheet itself:
///
/// 1. **Range.** Rows where the "latitude" is beyond ±90° while the "longitude"
///    is within it can only be swapped; rows the other way confirm the labels.
/// 2. **Maps links.** A location cell holding a maps link carries the same
///    coordinate latitude-first. Rows whose columns match the link crosswise
///    vote for a swap; rows that match it straight vote against.
///
/// The labels win a tie and when there is no evidence. The import screen
/// shows the verdict and lets the person flip it.
nonisolated enum SpreadsheetCoordinateSwap {
    struct Sample {
        var labeled: SpreadsheetCoordinate
        var link: SpreadsheetCoordinate?
    }

    static func evidence(_ samples: [Sample]) -> SpreadsheetSwapEvidence? {
        var rangeSwapped = 0
        var rangeStraight = 0
        var linkSwapped = 0
        var linkStraight = 0
        for sample in samples {
            let lat = abs(sample.labeled.latitude)
            let lng = abs(sample.labeled.longitude)
            if lat > 90, lat <= 180, lng <= 90 {
                rangeSwapped += 1
            } else if lng > 90, lng <= 180, lat <= 90 {
                rangeStraight += 1
            }
            if let link = sample.link {
                if sample.labeled.matches(link) {
                    linkStraight += 1
                } else if sample.labeled.swapped.matches(link) {
                    linkSwapped += 1
                }
            }
        }
        if rangeSwapped > rangeStraight { return .outOfRange(rows: rangeSwapped) }
        if rangeStraight == 0, linkSwapped > linkStraight { return .mapsLinks(rows: linkSwapped) }
        return nil
    }
}

/// Reads route cells: Piru's own route names and the words people use for
/// them in English, Dutch, Spanish, German and French.
enum SpreadsheetRouteParser {
    static func route(from text: String) -> RouteOfAdministration? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if key == "other" { return .other }
        let parsed = RouteOfAdministration.from(string: key)
        if parsed != .other { return parsed }
        return synonyms[key]
    }

    private static let synonyms: [String: RouteOfAdministration] = {
        let groups: [(RouteOfAdministration, [String])] = [
            (.oral, ["orally", "swallowed", "eaten", "drunk", "by mouth", "mouth", "po", "oraal", "geslikt", "slikken", "gegeten", "gedronken", "oral (swallowed)", "vía oral", "via oral", "tragado", "ingerido", "geschluckt", "gegessen", "getrunken", "orale", "avalé", "bu", "口服"]),
            (.sublingual, ["under tongue", "under the tongue", "sl", "onder de tong", "sublinguaal", "sublingual", "bajo la lengua", "unter der zunge", "sublinguale", "舌下"]),
            (.buccal, ["buccaal", "bucal", "bukkal", "buccale", "颊", "頰"]),
            (.insufflation, ["snorted", "snort", "sniffed", "nose", "gesnoven", "snuiven", "gesnoven (neus)", "neus", "esnifado", "esnifada", "inhalado nasal", "nasal", "geschnupft", "gesnieft", "nase", "sniffé", "nasale", "鼻吸", "鼻腔"]),
            (.inhalation, ["smoke", "smoking", "vaped", "vape", "vaping", "gerookt", "roken", "gedampt", "dampen", "verdampt", "fumado", "fumada", "vapeado", "inhalado", "inhalada", "geraucht", "gedampft", "verdampft", "fumé", "vapoté", "inhalé", "吸入", "抽吸"]),
            (.intravenous, ["injected", "iv injection", "intraveneus", "gespoten", "intravenoso", "intravenös", "intraveineuse", "静脉", "靜脈"]),
            (.intramuscular, ["intramusculair", "intramuscular", "intramuskulär", "intramusculaire", "肌肉注射"]),
            (.subcutaneous, ["sc", "subq", "sub-q", "subcutaan", "subcutáneo", "subkutan", "sous-cutanée", "皮下"]),
            (.transdermal, ["patch", "pleister", "parche", "pflaster", "skin", "huid", "透皮"]),
            (.rectal, ["boofed", "boofing", "anal", "rectaal", "rectal", "rektal", "直肠", "直腸"]),
        ]
        var table: [String: RouteOfAdministration] = [:]
        for (route, words) in groups {
            for word in words {
                table[word] = route
            }
        }
        return table
    }()
}
