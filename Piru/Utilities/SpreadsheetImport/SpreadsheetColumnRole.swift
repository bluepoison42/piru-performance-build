import Foundation

/// The Piru field a spreadsheet column fills. Every role but ``ignore`` maps
/// to at most one column.
enum SpreadsheetColumnRole: String, CaseIterable, Identifiable {
    case ignore
    /// A date, with or without a time of day.
    case date
    /// A time of day, combined with the date column's day.
    case time
    case substance
    /// The dose, a number with or without its unit ("200 mg", "halve pil").
    case amount
    /// The unit for amounts written without one.
    case unit
    case route
    case notes
    /// A place name, or a maps link carrying a coordinate.
    case location
    case latitude
    case longitude
    /// Whether the amount is an estimate ("yes", "1", "x").
    case approximate
    case tags

    var id: String {
        rawValue
    }

    /// The roles a column can be assigned, in the order the picker lists them.
    static let assignable: [SpreadsheetColumnRole] = [
        .date, .time, .substance, .amount, .unit, .route, .notes, .location, .latitude, .longitude, .approximate, .tags, .ignore,
    ]

    /// Whether the column's values can confirm or contradict a header naming
    /// this role. Free text (notes, place names, tags) cannot.
    var hasContentTest: Bool {
        switch self {
        case .notes, .location, .tags, .ignore: false
        default: true
        }
    }

    /// How far content alone may carry a column with no recognizable header.
    /// Numbers in a coordinate's range could be many things, and free text
    /// says nothing about which free-text field it is.
    var contentOnlyWeight: Double {
        switch self {
        case .date, .time, .substance: 0.8
        case .amount: 0.75
        case .unit, .route, .location: 0.7
        case .latitude, .longitude: 0.6
        case .notes, .approximate, .tags, .ignore: 0
        }
    }

    // MARK: - Header synonyms

    /// How well `header` names this role: 1 for a known header word or phrase,
    /// 0.6 when one of its words is one, 0 otherwise.
    func headerScore(_ header: String) -> Double {
        let normalized = Self.normalize(header)
        guard !normalized.isEmpty, let synonyms = Self.synonyms[self] else { return 0 }
        if synonyms.contains(normalized) { return 1 }
        let words = Set(normalized.split(separator: " ").map(String.init))
        for synonym in synonyms {
            if synonym.unicodeScalars.contains(where: { $0.value >= 0x3000 }) {
                if normalized.contains(synonym) { return 0.6 }
            } else if !synonym.contains(" "), synonym.count >= 3, !Self.wholeHeaderOnly.contains(synonym), words.contains(synonym) {
                return 0.6
            }
        }
        return 0
    }

    /// Synonyms that name a role only as the whole header: as one word among
    /// others ("Long notes", "What happened") they mean something else.
    private static let wholeHeaderOnly: Set<String> = [
        "long", "was", "art", "how", "what", "que", "day", "med", "name", "via", "when", "map", "dag", "uur", "hoe", "wat",
        "dia", "ort", "lange", "mode", "product", "breite", "lengte", "breedte",
    ]

    /// Lowercased, accents folded, punctuation as single spaces.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var result = ""
        var lastWasSpace = true
        for character in folded {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Header words per role in English, Dutch, Spanish, German, French and
    /// Chinese, compared after ``normalize(_:)``.
    private static let synonyms: [SpreadsheetColumnRole: Set<String>] = [
        .date: [
            "date", "datetime", "date time", "date and time", "timestamp", "time stamp", "when", "day", "taken at", "logged at",
            "created", "created at", "datum", "datum tijd", "datum en tijd", "wanneer", "dag", "tijdstip", "fecha", "fecha y hora",
            "cuando", "dia", "zeitpunkt", "datum uhrzeit", "datum und uhrzeit", "wann", "jour", "date heure", "quand",
            "日期", "日期时间", "日期時間", "时间戳", "時間戳記",
        ],
        .time: ["time", "time of day", "clock", "hour", "tijd", "uur", "hora", "zeit", "uhrzeit", "heure", "时间", "時間", "时刻", "時刻"],
        .substance: [
            "substance", "substances", "drug", "drugs", "drug name", "medication", "medicine", "med", "meds", "compound", "what",
            "product", "name", "substantie", "stof", "middel", "drug naam", "medicijn", "wat", "sustancia", "droga", "medicamento",
            "farmaco", "que", "substanz", "droge", "medikament", "wirkstoff", "was", "drogue", "medicament", "produit",
            "物质", "物質", "药物", "藥物", "药品", "藥品", "名称", "名稱",
        ],
        .amount: [
            "dose", "doses", "dosage", "amount", "quantity", "qty", "how much", "dosis", "hoeveelheid", "hoeveel", "cantidad",
            "cuanto", "menge", "dosierung", "wieviel", "wie viel", "quantite", "combien", "剂量", "劑量", "用量", "数量", "數量",
        ],
        .unit: ["unit", "units", "dose unit", "eenheid", "unidad", "unidades", "einheit", "unite", "单位", "單位"],
        .route: [
            "route", "roa", "route of administration", "method", "how", "toediening", "toedieningsweg", "manier", "hoe", "via",
            "via de administracion", "metodo", "applikation", "einnahme", "art", "voie", "voie d administration", "mode",
            "途径", "途徑", "给药途径", "給藥途徑", "方式",
        ],
        .notes: [
            "notes", "note", "comment", "comments", "remarks", "remark", "description", "details", "memo", "journal",
            "opmerking", "opmerkingen", "notitie", "notities", "commentaar", "toelichting", "nota", "notas", "comentario",
            "comentarios", "observaciones", "notiz", "notizen", "kommentar", "bemerkung", "bemerkungen", "remarque", "remarques",
            "commentaire", "commentaires", "备注", "備註", "笔记", "筆記", "评论", "評論", "说明", "說明",
        ],
        .location: [
            "location", "place", "where", "address", "map", "maps", "venue", "locatie", "plaats", "waar", "adres", "lugar",
            "ubicacion", "donde", "direccion", "ort", "standort", "wo", "adresse", "lieu", "endroit", "ou",
            "地点", "地點", "位置", "地址",
        ],
        .latitude: ["latitude", "lat", "breedtegraad", "breedte", "latitud", "breitengrad", "breite", "纬度", "緯度"],
        .longitude: ["longitude", "lng", "lon", "long", "lengtegraad", "lengte", "longitud", "langengrad", "lange", "经度", "經度"],
        .approximate: [
            "approximate", "approx", "approximately", "estimated", "estimate", "approximate dose", "geschat", "schatting",
            "ongeveer", "aproximado", "aproximada", "estimado", "ungefahr", "geschatzt", "approximatif", "estime",
            "约", "約", "大约", "大約", "估计", "估計",
        ],
        .tags: ["tags", "labels", "label", "etiketten", "etiquetas", "schlagworter", "etiquettes", "标签", "標籤"],
    ]
}

/// What each column of a sheet is taken to be, and the two sheet-wide choices
/// a mapping can't express per column.
struct SpreadsheetMapping: Equatable {
    var roles: [SpreadsheetColumnRole]
    var dateOrder: SpreadsheetDateOrder
    /// Reads the latitude column as longitude and the longitude column as latitude.
    var swapCoordinates: Bool

    /// The column assigned `role`, if any.
    func column(for role: SpreadsheetColumnRole) -> Int? {
        guard role != .ignore else { return nil }
        return roles.firstIndex(of: role)
    }

    /// Assigns `role` to `column`, taking it from any column that had it.
    mutating func assign(_ role: SpreadsheetColumnRole, to column: Int) {
        guard roles.indices.contains(column) else { return }
        if role != .ignore, let previous = self.column(for: role), previous != column {
            roles[previous] = .ignore
        }
        roles[column] = role
    }
}
