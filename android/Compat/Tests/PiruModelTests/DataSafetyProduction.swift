import Foundation
import PortableData
import os

// MedicationDayProduction supplies AppIdentity and UserDefaults.androidAppGroup.
// Keep that shim in the same test target: StageSources rewrites production suiteName.
extension Logger {
    static let storeRecovery = Logger(subsystem: "piru.test", category: "recovery")
    static let backupManager = Logger(subsystem: "piru.test", category: "backup")
}
extension Date {
    nonisolated var msSince1970: Int64 {
        Int64(timeIntervalSince1970 * 1_000)
    }
    nonisolated init(ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1_000.0)
    }
}
nonisolated struct PiruDoseData: Codable {
    /// The dose's stable ``DoseEntry/id``. Always emitted on export; optional
    /// on decode so files written before schema V4 still import (those doses
    /// get fresh UUIDs). Present IDs take precedence over content dedup;
    /// content keys are used only for records without an ID.
    var id: UUID?
    var substance: String
    var amount: Double
    var unit: String
    var route: RouteOfAdministration
    /// The salt/ester form logged (Magnesium Glycinate, Lithium Orotate…).
    /// Optional on both encode and decode — omitted for the vast majority of
    /// doses, and absent from files written before salt-form support, which
    /// import with `saltForm == nil` unchanged.
    var saltForm: String?
    /// PSID identity + the user's product word, carried so a backup→restore keeps
    /// a Concerta dose Concerta. All optional on both sides: omitted for a plain
    /// dose, and absent from files written before PSID (which import unresolved and
    /// self-heal via the launch backfill). `productName` especially must ride
    /// along — the backfill can recover the facets from the canonical name but not
    /// the brand word, which is gone once `substance` is canonical.
    var substanceUID: String?
    var isomer: String?
    var releaseForm: String?
    var productName: String?
    var displayNameSnapshot: String?
    var timestamp: Int64
    var notes: String?
    var tags: [String]
    var isBackgroundMed: Bool
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
    /// The dose's amount qualifiers. Always emitted; optional on decode so files
    /// written before either flag existed import with both `false`.
    var isApproximate: Bool?
    var isUnknownDose: Bool?
    /// The grapefruit flag and a by-volume drink's detail. Optional on both
    /// sides: omitted for an ordinary dose, absent from older files.
    var hadGrapefruit: Bool?
    /// ``MealState`` raw value; absent when no meal was recorded.
    var meal: String?
    var volumeML: Double?
    var abv: Double?
    var drinkName: String?
    /// The combination product the dose was logged as part of. Optional on
    /// both sides: omitted for a dose logged on its own, absent from older files.
    var combinationName: String?
    /// ``InjectionSite/rawValue`` (`"thigh.left"`); absent when no site was
    /// recorded and from older files.
    var injectionSite: String?
}

nonisolated struct PiruSessionData: Codable {
    var id: UUID
    var startDate: Int64
    var title: String?
    var note: String?
    var doses: [PiruDoseData]
    /// Timestamped notes. Optional on decode so files written before session
    /// notes still import (they decode as `nil`, treated as none).
    var notes: [PiruSessionNoteData]?
    /// Check-in cadence (see ``Session/checkInIntervalMinutes``); optional for
    /// the same back-compat reason.
    var checkInIntervalMinutes: Double?
    /// Custom check-in times (``Session/checkInOffsetMinutes``) and whether the
    /// check-in offer was already shown; optional for the same reason.
    var checkInOffsetMinutes: [Int]?
    var checkInOffered: Bool?
    /// Whether the times follow the doses (``Session/checkInFollowsDoses``);
    /// optional for the same reason.
    var checkInFollowsDoses: Bool?
}
nonisolated struct PiruSessionNoteData: Codable {
    var id: UUID
    var timestamp: Int64
    var text: String
    var shulgin: Int?
    var mood: Int?
    var energy: Int?
    var social: Int?
    var worked: Int?
    var descriptors: [String]
    var heartRate: Double?
    var kind: String

    init(_ note: SessionNote) {
        id = note.id
        timestamp = note.timestamp.msSince1970
        text = note.text
        shulgin = note.shulgin
        mood = note.mood
        energy = note.energy
        social = note.social
        worked = note.worked
        descriptors = note.descriptors
        heartRate = note.heartRate
        kind = note.kindRaw
    }
}

nonisolated struct NativeDoseFile: Codable {
    var sessions: [PiruSessionData]
    var orphanDoses: [PiruDoseData]
}
// These tests never import custom definitions or cosmetic palette rows.
nonisolated struct PiruCustomSubstanceData: Codable {}
final class CustomSubstanceStore {
    static let shared = CustomSubstanceStore()
    func resetAfterDeletion() {}
    var productMeds: [String: MedSchedule.ProductMed] { MedSchedule.productMeds() }
    func displayName(for name: String) -> String { name }
}
enum SubstanceColorStore {
    static func ensureRow(for name: String, existing: [SubstanceColor], in context: ModelContext) -> SubstanceColor? { nil }
}
enum SessionNoteService {
    static func ensureSummaryNote(for session: Session) {}
}
nonisolated struct PsyLogFile: Codable {
    var experiences: [PsyLogExperience]
    var substanceCompanions: [PsyLogCompanion]
    var customUnits: [PsyLogCustomUnit]
    var customSubstances: [PiruCustomSubstanceData]
    var dailyDoseItems: [PsyLogDailyDoseItem]

    private enum CodingKeys: String, CodingKey {
        case experiences
        case substanceCompanions
        case customUnits
        case customSubstances
        case dailyDoseItems
        case exportSource
    }

    /// Stamped on export so PsychonautWiki recognizes the file as the modern
    /// format. PW's importer rejects files with no `exportSource` as "legacy".
    /// Verified: a file carrying this key (and none of Piru's own top-level
    /// keys) imports cleanly into the current PsychonautWiki Journal app.
    static let exportSourceValue = "iOS Journal 15.0"

    init(
        experiences: [PsyLogExperience],
        companions: [PsyLogCompanion],
        dailyDoseItems: [PsyLogDailyDoseItem] = [],
        customSubstances: [PiruCustomSubstanceData] = [],
    ) {
        self.experiences = experiences
        self.substanceCompanions = companions
        self.customUnits = []
        self.customSubstances = customSubstances
        self.dailyDoseItems = dailyDoseItems
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        experiences = try c.decode([PsyLogExperience].self, forKey: .experiences)
        substanceCompanions = try c.decodeIfPresent([PsyLogCompanion].self, forKey: .substanceCompanions) ?? []
        customUnits = try c.decodeIfPresent([PsyLogCustomUnit].self, forKey: .customUnits) ?? []
        dailyDoseItems = try c.decodeIfPresent([PsyLogDailyDoseItem].self, forKey: .dailyDoseItems) ?? []
        // PsyLog historically writes `customSubstances: []` (string array
        // placeholder); older Piru exports wrote a proper array of custom
        // substance objects. Decode whichever shape is present; treat anything
        // unparseable as empty so a malformed `customSubstances` field never
        // blocks an import that would otherwise succeed.
        if let parsed = try? c.decodeIfPresent([PiruCustomSubstanceData].self, forKey: .customSubstances) {
            customSubstances = parsed
        } else {
            customSubstances = []
        }
    }

    /// Encodes the **exact** PsychonautWiki modern shape — `exportSource`,
    /// `experiences`, `substanceCompanions`, `customUnits` — and nothing else.
    /// Piru-only data (custom substances, daily-dose items, per-dose location)
    /// is deliberately omitted; full-fidelity round-trips use the Piru-native
    /// format instead. This keeps the file importable by PsychonautWiki.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.exportSourceValue, forKey: .exportSource)
        try c.encode(experiences, forKey: .experiences)
        try c.encode(substanceCompanions, forKey: .substanceCompanions)
        try c.encode([PsyLogCustomUnit](), forKey: .customUnits)
    }
}

/// A place attached to an experience (and, as a Piru extension, to an
/// individual ingestion). Matches PsyLog's `{name, latitude, longitude}` shape.
/// Coordinates are optional to mirror PsychonautWiki's `LocationCodable` —
/// its users can name a location without attaching coordinates, and such
/// files must still import.
nonisolated struct PsyLogLocation: Codable {
    var name: String
    var latitude: Double?
    var longitude: Double?
}

/// PsychonautWiki's timed note (`TimedNoteCodable`): a free-text note pinned to a
/// moment inside an experience. `color` is one of PW's named substance colors and
/// `isPartOfTimeline` whether PW draws it on its graph; Piru writes `blue` and
/// `true` and reads neither back.
nonisolated struct PsyLogTimedNote: Codable {
    var creationDate: Int64
    var time: Int64
    var note: String
    var color: String
    var isPartOfTimeline: Bool

    init(time: Int64, note: String, creationDate: Int64? = nil) {
        self.time = time
        self.note = note
        self.creationDate = creationDate ?? time
        color = "blue"
        isPartOfTimeline = true
    }

    private enum CodingKeys: String, CodingKey {
        case creationDate
        case time
        case note
        case color
        case isPartOfTimeline
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Int64.self, forKey: .time)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        creationDate = try c.decodeIfPresent(Int64.self, forKey: .creationDate) ?? time
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "blue"
        isPartOfTimeline = try c.decodeIfPresent(Bool.self, forKey: .isPartOfTimeline) ?? true
    }
}

nonisolated struct PsyLogExperience: Codable {
    var title: String
    var isFavorite: Bool
    var creationDate: Int64
    var sortDate: Int64
    var text: String
    var location: PsyLogLocation?
    var ingestions: [PsyLogIngestion]
    var timedNotes: [PsyLogTimedNote]

    private enum CodingKeys: String, CodingKey {
        case title
        case isFavorite
        case creationDate
        case sortDate
        case text
        case ingestions
        case ratings
        case location
        case timedNotes
    }

    init(title: String, text: String = "", creationDate: Int64, sortDate: Int64, location: PsyLogLocation? = nil, ingestions: [PsyLogIngestion], timedNotes: [PsyLogTimedNote] = []) {
        self.title = title
        self.isFavorite = false
        self.creationDate = creationDate
        self.sortDate = sortDate
        self.text = text
        self.location = location
        self.ingestions = ingestions
        self.timedNotes = timedNotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        location = try c.decodeIfPresent(PsyLogLocation.self, forKey: .location)
        ingestions = try c.decodeIfPresent([PsyLogIngestion].self, forKey: .ingestions) ?? []
        // Older Piru exports wrote `timedNotes: []` as a string-array placeholder;
        // anything that isn't PW's object shape reads as no notes.
        timedNotes = (try? c.decodeIfPresent([PsyLogTimedNote].self, forKey: .timedNotes)) ?? []
        // PsychonautWiki writes `sortDate: null` for experiences that never had
        // one, and its own importer falls back to the earliest ingestion — so
        // must we. Both dates are lenient: a missing one falls back to the
        // other, then to the earliest ingestion time.
        let decodedCreation = try c.decodeIfPresent(Int64.self, forKey: .creationDate)
        let decodedSort = try c.decodeIfPresent(Int64.self, forKey: .sortDate)
        let earliestIngestion = ingestions.map(\.time).min()
        creationDate = decodedCreation ?? decodedSort ?? earliestIngestion ?? 0
        sortDate = decodedSort ?? earliestIngestion ?? creationDate
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode([String](), forKey: .ratings)
        try c.encode(title, forKey: .title)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(creationDate, forKey: .creationDate)
        try c.encode(location, forKey: .location)
        try c.encode(sortDate, forKey: .sortDate)
        try c.encode(text, forKey: .text)
        try c.encode(timedNotes, forKey: .timedNotes)
        try c.encode(ingestions, forKey: .ingestions)
    }
}

nonisolated struct PsyLogIngestion: Codable {
    var substanceName: String?
    var customUnitId: Int?
    var dose: Double?
    var isUnknownDose: Bool
    var time: Int64
    var administrationRoute: String
    var notes: String
    var units: String
    /// Piru extension: per-ingestion location. PsyLog stores location only at
    /// the experience level, so this key is absent in cross-app files and is
    /// encoded only when set — letting a Piru→Piru round-trip preserve a
    /// dose's own location even when its session spans multiple places.
    var location: PsyLogLocation?

    private enum CodingKeys: String, CodingKey {
        case substanceName
        case dose
        case isUnknownDose
        case time
        case administrationRoute
        case notes
        case units
        case customUnitId
        case creationDate
        case consumerName
        case estimatedDoseStandardDeviation
        case isDoseAnEstimate
        case stomachFullness
        case endTime
        case location
        case isHiddenInTimeline
    }

    init(substanceName: String, dose: Double, time: Int64, route: String, notes: String, units: String, location: PsyLogLocation? = nil, isUnknownDose: Bool = false) {
        self.substanceName = substanceName
        self.customUnitId = nil
        self.dose = dose
        self.isUnknownDose = isUnknownDose
        self.time = time
        self.administrationRoute = route
        self.notes = notes
        self.units = units
        self.location = location
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        substanceName = try c.decodeIfPresent(String.self, forKey: .substanceName)
        customUnitId = try c.decodeIfPresent(Int.self, forKey: .customUnitId)
        dose = try c.decodeIfPresent(Double.self, forKey: .dose)
        isUnknownDose = try c.decodeIfPresent(Bool.self, forKey: .isUnknownDose) ?? false
        time = try c.decode(Int64.self, forKey: .time)
        administrationRoute = try c.decodeIfPresent(String.self, forKey: .administrationRoute) ?? "ORAL"
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        units = try c.decodeIfPresent(String.self, forKey: .units) ?? "mg"
        location = try c.decodeIfPresent(PsyLogLocation.self, forKey: .location)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNil(forKey: .customUnitId)
        try c.encode(time, forKey: .creationDate)
        try c.encodeNil(forKey: .consumerName)
        try c.encode(substanceName, forKey: .substanceName)
        try c.encodeNil(forKey: .estimatedDoseStandardDeviation)
        try c.encode(false, forKey: .isDoseAnEstimate)
        try c.encodeNil(forKey: .stomachFullness)
        try c.encode(dose, forKey: .dose)
        if isUnknownDose { try c.encode(true, forKey: .isUnknownDose) }
        try c.encodeNil(forKey: .endTime)
        try c.encode(time, forKey: .time)
        try c.encode(administrationRoute, forKey: .administrationRoute)
        try c.encode(notes, forKey: .notes)
        try c.encode(units, forKey: .units)
        // PsychonautWiki's modern ingestions always carry this flag; include it
        // so the file matches their shape exactly. Per-dose location is NOT
        // emitted here — PsyLog keeps location at the experience level only.
        try c.encode(false, forKey: .isHiddenInTimeline)
    }
}

nonisolated struct PsyLogCompanion: Codable {
    var color: String
    var substanceName: String
}

nonisolated struct PsyLogDailyDoseItem: Codable {
    var substance: String
    var amount: Double
    var unit: String
    var route: String
    var sortOrder: Int
}

nonisolated struct PsyLogCustomUnit: Codable {
    var id: Int
    var name: String
    var unit: String
    var color: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case unit
        case color
        case isArchived
        case doseComponents
        case unitPlural
        case note
        case creationDate
        case roaInfos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? "mg"
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(unit, forKey: .unit)
    }
}

// MARK: - PsyLog Export / Import


private extension RouteOfAdministration {
    var psylogName: String {
        switch self {
        case .oral: "ORAL"
        case .sublingual: "SUBLINGUAL"
        // PsychonautWiki's journal `AdministrationRoute` has BUCCAL, so this
        // round-trips rather than degrading to ORAL.
        case .buccal: "BUCCAL"
        case .insufflation: "INSUFFLATED"
        case .inhalation: "INHALED"
        case .intravenous: "INTRAVENOUS"
        case .intramuscular: "INTRAMUSCULAR"
        case .subcutaneous: "SUBCUTANEOUS"
        case .transdermal: "TRANSDERMAL"
        case .rectal: "RECTAL"
        case .other: "ORAL"
        }
    }
}
import Foundation

enum TagExtractor {
    /// Extract hashtags from text (e.g., "#headache #sleep" -> ["headache", "sleep"])
    static func extractTags(from text: String) -> [String] {
        let pattern = #"#(\w+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        var seen = Set<String>()
        return matches.compactMap { match in
            guard let tagRange = Range(match.range(at: 1), in: text) else { return nil }
            let tag = String(text[tagRange]).lowercased()
            guard !seen.contains(tag) else { return nil }
            seen.insert(tag)
            return tag
        }
    }

    /// Common tag suggestions for quick access
    static let suggestions = [
        "headache", "anxiety", "sleep", "pain", "nausea",
        "mood", "energy", "focus", "relax", "appetite",
    ]
}

extension DataExportImport {
static func doseDedupKey(substance: String, timestamp: Date, amount: Double, unit: String, route: RouteOfAdministration) -> String {
        "\(substance.lowercased())|\(timestamp.msSince1970)|\(amount)|\(unit.lowercased())|\(route.rawValue)"
    }
static func importNotes(_ notes: [PiruSessionNoteData], into session: Session, context: ModelContext) {
        var existing = Set((session.notes ?? []).map(\.id))
        for data in notes where !existing.contains(data.id) {
            existing.insert(data.id)
            context.insert(SessionNote(
                id: data.id,
                timestamp: Date(ms: data.timestamp),
                text: data.text,
                shulgin: data.shulgin, mood: data.mood, energy: data.energy,
                social: data.social, worked: data.worked,
                descriptors: data.descriptors, heartRate: data.heartRate,
                kind: SessionNote.Kind(rawValue: data.kind) ?? .observation,
                session: session,
            ))
        }
        SessionNoteService.ensureSummaryNote(for: session)
    }
    static func importNativeDoseFile(_ data: Data, context: ModelContext) throws {
        let file = try JSONDecoder().decode(NativeDoseFile.self, from: data)
        let existingDoses = (try? context.fetch(FetchDescriptor<DoseEntry>())) ?? []
        var seen = Set(existingDoses.map {
            doseDedupKey(substance: $0.substance, timestamp: $0.timestamp, amount: $0.amount, unit: $0.unit, route: $0.route)
        })
        var seenIDs = Set(existingDoses.map(\.id))

        func makeDose(_ d: PiruDoseData) -> DoseEntry? {
            let timestamp = Date(ms: d.timestamp)
            let key = doseDedupKey(substance: d.substance, timestamp: timestamp, amount: d.amount, unit: d.unit, route: d.route)
            if let id = d.id {
                guard seenIDs.insert(id).inserted else { return nil }
                seen.insert(key)
            } else {
                guard seen.insert(key).inserted else { return nil }
            }
            let entry = DoseEntry(
                substance: d.substance, amount: d.amount, unit: d.unit, route: d.route,
                saltForm: d.saltForm,
                isomer: d.isomer, releaseForm: d.releaseForm, productName: d.productName,
                substanceUID: d.substanceUID, displayNameSnapshot: d.displayNameSnapshot,
                timestamp: timestamp, notes: d.notes, tags: d.tags, isBackgroundMed: d.isBackgroundMed,
                locationName: d.locationName, latitude: d.latitude, longitude: d.longitude,
                hadGrapefruit: d.hadGrapefruit,
                meal: d.meal.flatMap(MealState.init(rawValue:)),
                isApproximate: d.isApproximate ?? false, isUnknownDose: d.isUnknownDose ?? false,
                volumeML: d.volumeML, abv: d.abv, drinkName: d.drinkName,
                combinationName: d.combinationName,
                injectionSite: d.injectionSite.flatMap(InjectionSite.init(rawValue:)),
            )
            if let id = d.id {
                entry.id = id
            } else {
                seenIDs.insert(entry.id)
            }
            context.insert(entry)
            return entry
        }

        // Recreate sessions with their original id/title/note; reuse an existing
        // session row if one already carries that id (merge-safe). On a reused
        // row the file fills only what this install left empty, so an edit made
        // here survives a merge.
        let existingSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        var sessionsByID = Dictionary(existingSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for sessionData in file.sessions {
            let doses = sessionData.doses.compactMap(makeDose)
            let session: Session
            if let existing = sessionsByID[sessionData.id] {
                session = existing
                if session.title == nil { session.title = sessionData.title }
                if session.note == nil { session.note = sessionData.note }
            } else {
                session = Session(
                    id: sessionData.id,
                    startDate: Date(ms: sessionData.startDate),
                    title: sessionData.title,
                    note: sessionData.note,
                )
                context.insert(session)
                sessionsByID[sessionData.id] = session
            }
            for dose in doses {
                dose.session = session
            }
            session.refreshDoseBounds()
            importNotes(sessionData.notes ?? [], into: session, context: context)
            if session.checkInIntervalMinutes == nil {
                session.checkInIntervalMinutes = sessionData.checkInIntervalMinutes
                session.checkInFollowsDoses = sessionData.checkInFollowsDoses ?? false
            }
            if session.checkInOffsetMinutes.isEmpty, let offsets = sessionData.checkInOffsetMinutes, !offsets.isEmpty {
                session.checkInOffsetMinutes = offsets
            }
            if sessionData.checkInOffered == true { session.checkInOffered = true }
        }

        // Session-less doses (defensive) are left unassigned; importJSON's
        // clustering pass groups them afterwards.
        for orphan in file.orphanDoses {
            _ = makeDose(orphan)
        }

    }
static func importPsyLog(data: Data, context: ModelContext, customStore: CustomSubstanceStore) throws {
        let file = try JSONDecoder().decode(PsyLogFile.self, from: data)
        importCustomSubstances(file.customSubstances, into: customStore)

        // Build custom unit lookup: id -> custom unit
        let customUnitMap = Dictionary(file.customUnits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Dedup dose entries against what's already stored (and within this
        // import) so a merge restore — or re-importing the same file — stays
        // idempotent instead of multiplying every dose. `DoseEntry` has no
        // natural id, so the key is its content: substance, time, dose, unit, route.
        let existingDoses = (try? context.fetch(FetchDescriptor<DoseEntry>())) ?? []
        var seenDoseKeys = Set(existingDoses.map {
            doseDedupKey(substance: $0.substance, timestamp: $0.timestamp, amount: $0.isUnknownDose ? 0 : $0.amount, unit: $0.unit, route: $0.route) + ($0.isUnknownDose ? "|unknown" : "|known")
        })
        // Stored doses on route Other, keyed as if the file's dose were Other too.
        // An earlier build filed PW's SMOKED as Other; when the same file comes
        // in again, its dose names the real route, so the stored copy takes that
        // route instead of a second copy landing beside it.
        var unroutedDoses = Dictionary(grouping: existingDoses.filter { $0.route == .other }) {
            doseDedupKey(substance: $0.substance, timestamp: $0.timestamp, amount: $0.isUnknownDose ? 0 : $0.amount, unit: $0.unit, route: .other) + ($0.isUnknownDose ? "|unknown" : "|known")
        }

        for experience in file.experiences {
            var sessionDoses: [DoseEntry] = []
            for ingestion in experience.ingestions {
                // Resolve substance name: prefer direct name, fall back to custom unit
                let name: String
                if let directName = ingestion.substanceName {
                    name = directName
                } else if let cuId = ingestion.customUnitId, let cu = customUnitMap[cuId] {
                    name = cu.name
                } else {
                    continue
                }

                // Zero is meaningful only when the file explicitly marks the dose unknown.
                guard let rawDose = ingestion.dose,
                      rawDose > 0 || (rawDose == 0 && ingestion.isUnknownDose)
                else { continue }
                let dose = ingestion.isUnknownDose ? 0 : rawDose

                // The shared parser, never a table of this importer's own: PW
                // writes SMOKED beside INHALED (and PsyLog files carry the same
                // vocabulary), and a local table that missed one filed every
                // such dose as Other.
                let route = RouteOfAdministration.from(string: ingestion.administrationRoute)
                let timestamp = Date(ms: ingestion.time)
                let key = doseDedupKey(substance: name, timestamp: timestamp, amount: dose, unit: ingestion.units, route: route) + (ingestion.isUnknownDose ? "|unknown" : "|known")
                guard seenDoseKeys.insert(key).inserted else { continue }
                if route != .other {
                    let unroutedKey = doseDedupKey(substance: name, timestamp: timestamp, amount: dose, unit: ingestion.units, route: .other) + (ingestion.isUnknownDose ? "|unknown" : "|known")
                    if let stored = unroutedDoses[unroutedKey]?.popLast() {
                        stored.route = route
                        continue
                    }
                }

                let extractedTags = TagExtractor.extractTags(from: ingestion.notes)
                // A dose's own location (a Piru extension, present only in older
                // Piru PsyLog exports) wins; otherwise inherit the experience's
                // location. PsychonautWiki stores location per experience, so we
                // copy it onto every dose to fit Piru's per-dose model.
                let location = ingestion.location ?? experience.location
                let entry = DoseEntry(
                    substance: name,
                    amount: dose,
                    unit: ingestion.units,
                    route: route,
                    timestamp: timestamp,
                    notes: ingestion.notes.isEmpty ? nil : ingestion.notes,
                    tags: extractedTags,
                    locationName: location?.name,
                    latitude: location?.latitude,
                    longitude: location?.longitude,
                    isUnknownDose: ingestion.isUnknownDose,
                )
                context.insert(entry)
                sessionDoses.append(entry)
            }

            // Each PsychonautWiki experience becomes a Piru session, preserving
            // its grouping and carrying the custom title and notes across. Only
            // when it brought in at least one new (non-duplicate) dose, so a
            // re-import doesn't accumulate empty sessions.
            guard !sessionDoses.isEmpty else { continue }
            let start = sessionDoses.map(\.timestamp).min() ?? Date(ms: experience.sortDate)
            let session = Session(
                startDate: start,
                title: experience.title.isEmpty ? nil : experience.title,
                note: experience.text.isEmpty ? nil : experience.text,
            )
            context.insert(session)
            for dose in sessionDoses {
                dose.session = session
            }
            session.refreshDoseBounds()
            for timed in experience.timedNotes where !timed.note.trimmingCharacters(in: .whitespaces).isEmpty {
                context.insert(SessionNote(timestamp: Date(ms: timed.time), text: timed.note, session: session))
            }
            SessionNoteService.ensureSummaryNote(for: session)
        }

        // PsyLog makes every substance carry one of its palette names; those
        // are dropped in favor of Piru's class colors, so an import doesn't
        // arrive as a list of "custom" colors the user never chose here.
        var colorRows = (try? context.fetch(FetchDescriptor<SubstanceColor>())) ?? []
        for name in file.substanceCompanions.map(\.substanceName) {
            if let row = SubstanceColorStore.ensureRow(for: name, existing: colorRows, in: context) {
                colorRows.append(row)
            }
        }

        // Import daily dose items, skip duplicates by substance name
        if !file.dailyDoseItems.isEmpty {
            let existing = (try? context.fetch(FetchDescriptor<DailyDoseItem>())) ?? []
            let existingNames = Set(existing.map { $0.substance.lowercased() })

            for item in file.dailyDoseItems {
                guard !existingNames.contains(item.substance.lowercased()) else { continue }
                context.insert(DailyDoseItem(
                    substance: item.substance,
                    amount: item.amount,
                    unit: item.unit,
                    route: RouteOfAdministration.from(string: item.route),
                    sortOrder: item.sortOrder,
                ))
            }
        }
    }
    static func exportPsyLogIngestion(_ entry: DoseEntry) -> PsyLogIngestion {
                var noteText = entry.notes ?? ""
                if !entry.tags.isEmpty {
                    let tagStr = entry.tags.map { "#\($0)" }.joined(separator: " ")
                    noteText = noteText.isEmpty ? tagStr : "\(noteText) \(tagStr)"
                }
                return PsyLogIngestion(
                    substanceName: entry.substance,
                    dose: entry.amount,
                    time: entry.timestamp.msSince1970,
                    route: entry.route.psylogName,
                    notes: noteText,
                    units: entry.unit,
                    isUnknownDose: entry.isUnknownDose,
                )
    }
nonisolated static func checkedBackup<T>(container: ModelContainer, capture: () throws -> T) throws -> T {
        #if canImport(PortableData)
        try container.requireCompleteBackup()
        #endif
        let captured = try capture()
        #if canImport(PortableData)
        try container.requireCompleteBackup()
        #endif
        return captured
    }
    static func importCustomSubstances(_ values: [PiruCustomSubstanceData], into store: CustomSubstanceStore) {}
    enum ImportMode { case merge, replace }
    static func validate(_ data: Data) throws { _ = try JSONDecoder().decode(NativeDoseFile.self, from: data) }
    static func importJSON(data: Data, context: ModelContext, mode: ImportMode = .merge) throws {
        try importNativeDoseFile(data, context: context)
        try commitImport(context: context)
    }
static func deleteAll(context: ModelContext) throws {
        try PiruSchema.deleteAll(in: context)
    }
}
enum JournalResetGeneration { static let dateKey = "piru-data-safety-test-reset" }
enum StoreRecovery {
    static var testStoreURL = URL(fileURLWithPath: "/unconfigured-piru-test")
    static func canonicalStoreURL() -> URL { testStoreURL }
    static func legacyStoreURL() -> URL? { nil }
    static let storeName = "journal.store"
    static let intentionalReasons: Set<String> = ["predelete", "prerestore", "prepsid"]
    static let storeSuffixes = ["", "-shm", "-wal"]
    @discardableResult
static func snapshotStore(reason: String) -> Bool {
        let fm = FileManager.default
        let store = canonicalStoreURL()
        guard fm.fileExists(atPath: store.path) else {
            Logger.storeRecovery.error("Snapshot failed: the live store is missing.")
            return false
        }
        var succeeded = true
        let dir = store.deletingLastPathComponent()
        let base = store.lastPathComponent
        let stamp = "\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))"
        for suffix in storeSuffixes {
            let src = dir.appendingPathComponent(base + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = dir.appendingPathComponent("\(base).\(reason)-\(stamp)\(suffix)")
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                succeeded = false
                Logger.storeRecovery.error("Snapshot of \(src.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if succeeded {
            Logger.storeRecovery.notice("Snapshot taken before \(reason, privacy: .public)")
        }
        return succeeded
    }
static func sidecarReason(_ fileName: String) -> String? {
        let prefix = storeName + "."
        guard fileName.hasPrefix(prefix) else { return nil }
        var tag = String(fileName.dropFirst(prefix.count))
        for suffix in ["-shm", "-wal"] where tag.hasSuffix(suffix) {
            tag = String(tag.dropLast(suffix.count))
        }
        // Drop the trailing `-<timestamp>`.
        guard let dash = tag.lastIndex(of: "-") else { return tag }
        return String(tag[tag.startIndex ..< dash])
    }
static func sidecarTimestamp(_ fileName: String) -> Date? {
        var tag = fileName
        for suffix in ["-shm", "-wal"] where tag.hasSuffix(suffix) {
            tag = String(tag.dropLast(suffix.count))
        }
        guard let dash = tag.lastIndex(of: "-") else { return nil }
        let stamp = tag[tag.index(after: dash)...]
        let parts = stamp.split(separator: "_", maxSplits: 1)
        guard let value = parts.first, let number = TimeInterval(value) else { return nil }
        let seconds = parts.count == 2 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }
static func recoveryCandidates(excluding canonical: URL, includeIntentional: Bool) -> [URL] {
        var out: [URL] = []
        if let legacy = legacyStoreURL(), legacy.path != canonical.path {
            out.append(legacy)
        }
        let dirs = Set([
            canonical.deletingLastPathComponent(),
            legacyStoreURL()?.deletingLastPathComponent(),
        ].compactMap { $0?.path })
        let fm = FileManager.default
        for dirPath in dirs {
            let dir = URL(fileURLWithPath: dirPath)
            guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for name in entries {
                // Accept both legacy seconds and unique millisecond_UUID snapshots.
                guard name.hasPrefix(storeName + "."), !name.hasSuffix("-shm"), !name.hasSuffix("-wal"), sidecarTimestamp(name) != nil
                else { continue }
                if !includeIntentional, let reason = sidecarReason(name), intentionalReasons.contains(reason) {
                    continue
                }
                out.append(dir.appendingPathComponent(name))
            }
        }
        if !includeIntentional, let resetDate = UserDefaults.standard.object(forKey: JournalResetGeneration.dateKey) as? Date {
            out = out.filter { url in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate else { return false }
                return modified > resetDate
            }
        }
        return out
    }
}
final class BackupManager {
enum RestoreStrategy {
        /// Add the backup's entries to the current data (de-duped by the import layer).
        case merge
        /// Snapshot + wipe the current data, then import only the backup's entries.
        case replace
    }
enum ManagerError: Error, LocalizedError {
        case iCloudUnavailable
        case noBackupFound
        case fileTooLarge
        case snapshotFailed

        var errorDescription: String? {
            switch self {
            case .iCloudUnavailable:
                String(localized: "iCloud Drive isn't available. Check that you're signed in to iCloud and that iCloud Drive is on.")
            case .noBackupFound:
                String(localized: "No iCloud backup was found for this account yet.")
            case .snapshotFailed:
                String(localized: "The safety snapshot could not be saved. Your journal was not replaced.")
            case .fileTooLarge:
                String(localized: "This file is too large to be a Piru backup.")
            }
        }
    }
func apply(plaintext: Data, strategy: RestoreStrategy, context: ModelContext) throws {
        switch strategy {
        case .merge:
            try DataExportImport.importJSON(data: plaintext, context: context)
        case .replace:
            // Decode the whole payload before the wipe: a file that cannot
            // import must leave the journal as it was.
            try DataExportImport.validate(plaintext)
            // Never wipe without a recoverable copy first.
            guard StoreRecovery.snapshotStore(reason: "prerestore") else {
                throw ManagerError.snapshotFailed
            }
            try DataExportImport.deleteAll(context: context)
            // The custom-substance cache still lists the deleted rows until it
            // reloads, and the importer skips any custom it already lists.
            CustomSubstanceStore.shared.resetAfterDeletion()
            try DataExportImport.importJSON(data: plaintext, context: context, mode: .replace)
        }
        Logger.backupManager.notice("Restore (\(String(describing: strategy), privacy: .public)) completed.")
    }
}
