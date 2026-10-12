import Foundation

/// A session's trip report as dose.wiki's report form reads it: the `#piru=`
/// fragment of `https://dose.wiki/reports/submit`, carrying base64url (no
/// padding) of UTF-8 JSON, version 1.
///
/// The payload holds the report and nothing about the person: no age, weight
/// or sex, no contact or consent data, no location, no other session. Opening
/// the URL fills dose.wiki's form in the browser; nothing leaves the device
/// until the user submits it there.
///
/// **Phase bucketing.** Each note lands in onset, peak or offset by the
/// modeled arc of the session's *primary substance*: the first dose that
/// carries phases names it, and every dose of that substance (redoses
/// included) contributes its peak window. A note before the earliest
/// "peak begins" is onset (notes before the first dose included); a note inside
/// any of the primary substance's windows, from "peak begins" up to "starts
/// wearing off", is peak; every other note is offset. Other substances in the
/// session never move a note, so a joint at T+6 cannot pull a late LSD note
/// back into peak. With no phased dose at all, every note is onset.
struct DoseWikiReportDraft {
    nonisolated static let submitEndpoint = "https://dose.wiki/reports/submit"

    /// The JSON size the encoder shortens notes to fit, keeping the URL a size
    /// every browser opens.
    nonisolated static let maxPayloadBytes = 32 * 1024

    /// dose.wiki's per-field and per-list caps; anything longer it would cut
    /// itself, so the draft cuts first and says so.
    nonisolated enum Limit {
        static let title = 200
        static let substanceName = 120
        static let dose = 60
        static let description = 4000
        static let conclusion = 20000
        static let substances = 20
        static let entriesPerPhase = 40
        static let tags = 500
    }

    /// The shortest a note is cut to when shrinking toward the size cap.
    nonisolated static let minimumTruncatedLength = 80

    let payload: Payload
    /// Whether any text was shortened or any entry left out to fit.
    let wasTruncated: Bool
    let json: Data

    var url: URL {
        // base64url's alphabet is fragment-safe, so the string needs no escaping.
        URL(string: "\(Self.submitEndpoint)#piru=\(Self.base64URL(json))")!
    }

    // MARK: - Payload

    nonisolated struct Payload: Codable, Equatable {
        var v = 1
        var source = "piru"
        var title: String?
        var substances: [Substance]?
        var introduction: String?
        var timeline: Timeline?
        var conclusion: String?
        var tags: [String]?
    }

    nonisolated struct Substance: Codable, Equatable {
        let name: String
        var slug: String?
        var dose: String?
        var roa: String?
    }

    nonisolated struct Timeline: Codable, Equatable {
        var onset: [Entry]?
        var peak: [Entry]?
        var offset: [Entry]?
    }

    nonisolated struct Entry: Codable, Equatable {
        let time: String
        var description: String
    }

    nonisolated enum Phase: Equatable {
        case onset
        case peak
        case offset
    }

    // MARK: - Build

    /// The draft for a stored session, with each dose's dose.wiki slug looked
    /// up from the catalog by the substance it was logged as.
    @MainActor
    static func build(session: Session) -> DoseWikiReportDraft {
        let logged = Dictionary(
            session.orderedDoses.map { ($0.id, $0.substance) }, uniquingKeysWith: { first, _ in first },
        )
        return DoseWikiReportDraft(report: TripReport.build(session: session)) { dose in
            logged[dose.id].flatMap(SubstanceLibrary.dosewikiSlug(for:))
        }
    }

    init(
        report: TripReport,
        maxBytes: Int = maxPayloadBytes,
        slug: (TripReport.Dose) -> String? = { _ in nil },
    ) {
        var truncated = false
        func capped(_ text: String, _ limit: Int) -> String {
            guard text.count > limit else { return text }
            truncated = true
            return Self.truncate(text, to: limit)
        }

        var payload = Payload()
        payload.title = capped(Self.title(for: report), Limit.title)

        if report.doses.count > Limit.substances { truncated = true }
        let substances = report.doses.prefix(Limit.substances).map { dose in
            Substance(
                name: capped(dose.name, Limit.substanceName),
                slug: slug(dose).nilIfBlank,
                dose: Self.doseText(dose).map { capped($0, Limit.dose) },
                roa: Self.roa(dose.route),
            )
        }
        payload.substances = substances.isEmpty ? nil : substances

        var timeline = Timeline()
        for note in report.notes {
            let entry = Entry(
                time: Self.tPlus(note.timestamp.timeIntervalSince(report.sessionStart)),
                description: capped(Self.description(for: note), Limit.description),
            )
            switch Self.phase(at: note.timestamp, doses: report.doses) {
            case .onset: timeline.onset = (timeline.onset ?? []) + [entry]
            case .peak: timeline.peak = (timeline.peak ?? []) + [entry]
            case .offset: timeline.offset = (timeline.offset ?? []) + [entry]
            }
        }
        for path in [\Timeline.onset, \.peak, \.offset] {
            guard let entries = timeline[keyPath: path], entries.count > Limit.entriesPerPhase else { continue }
            truncated = true
            timeline[keyPath: path] = Array(entries.prefix(Limit.entriesPerPhase))
        }
        if timeline != Timeline() { payload.timeline = timeline }

        payload.conclusion = report.summary?.nilIfBlank.map { capped($0, Limit.conclusion) }
        payload.tags = Self.tags(for: report)

        let fitted = Self.fit(payload, maxBytes: maxBytes)
        self.payload = fitted.payload
        wasTruncated = truncated || fitted.truncated
        json = fitted.json
    }

    // MARK: - Fields

    /// The session title, or a neutral one built from what was taken: each
    /// substance once, with its first dose ("MDMA, 120 mg + LSD, 100 µg").
    static func title(for report: TripReport) -> String {
        if let title = report.title?.nilIfBlank { return title }
        var seen = Set<String>()
        let parts = report.doses.filter { seen.insert($0.name).inserted }.map { dose in
            doseText(dose).map { "\(dose.name), \($0)" } ?? dose.name
        }
        return parts.isEmpty ? "Trip report" : parts.joined(separator: " + ")
    }

    /// Amount and unit as the report's dose table prints them; `nil` for a dose
    /// logged without an amount.
    static func doseText(_ dose: TripReport.Dose) -> String? {
        guard !dose.isUnknownDose else { return nil }
        return "\(dose.amountDisplay) \(dose.unit)".trimmingCharacters(in: .whitespaces).nilIfBlank
    }

    /// Piru's route as dose.wiki's form names it. `TripReport` carries the
    /// route's English display name ("Insufflation"), which parses back to the
    /// case.
    nonisolated static func roa(_ route: String) -> String {
        switch RouteOfAdministration.from(string: route) {
        case .oral: "oral"
        case .sublingual: "sublingual"
        case .buccal: "buccal"
        case .insufflation: "insufflated"
        case .inhalation: "inhaled"
        case .intravenous: "intravenous"
        case .intramuscular: "intramuscular"
        case .subcutaneous: "subcutaneous"
        case .transdermal: "transdermal"
        case .rectal: "rectal"
        case .other: "other"
        }
    }

    /// `T+1:05` from the session start; `T-0:15` for a note written before it.
    nonisolated static func tPlus(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((abs(interval) / 60).rounded())
        let sign = interval < 0 && totalMinutes > 0 ? "-" : "+"
        return String(format: "T%@%d:%02d", sign, totalMinutes / 60, totalMinutes % 60)
    }

    /// A note as plain text, carrying what the Markdown report shows: a first
    /// line with the check-in marker and the structured ratings
    /// (`Check-in · ++ · mood +2 · ♥ 84`), then the note's text, then its
    /// descriptors.
    static func description(for note: TripReport.Note) -> String {
        var header: [String] = []
        if note.kind == .checkIn { header.append("Check-in") }
        let structure = TripReport.structureLine(
            shulgin: note.shulgin, mood: note.mood, energy: note.energy,
            social: note.social, worked: note.worked, heartRate: note.heartRate,
        )
        if !structure.isEmpty { header.append(structure) }

        var lines: [String] = []
        if !header.isEmpty { lines.append(header.joined(separator: " · ")) }
        let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { lines.append(text) }
        if !note.descriptors.isEmpty {
            lines.append(note.descriptors.map(\.name).joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    /// Every descriptor noted, once each, in the order first noted, within
    /// dose.wiki's joined-length cap.
    static func tags(for report: TripReport) -> [String]? {
        var seen = Set<String>()
        var tags: [String] = []
        var joinedLength = 0
        for descriptor in report.notes.flatMap(\.descriptors) where seen.insert(descriptor.name).inserted {
            let added = descriptor.name.count + (tags.isEmpty ? 0 : 2)
            guard joinedLength + added <= Limit.tags else { break }
            tags.append(descriptor.name)
            joinedLength += added
        }
        return tags.isEmpty ? nil : tags
    }

    // MARK: - Phase bucketing

    /// The phase a moment falls in, by the primary substance's arc (see the
    /// type's documentation).
    static func phase(at moment: Date, doses: [TripReport.Dose]) -> Phase {
        let windows = peakWindows(doses)
        guard let firstPeak = windows.map(\.lowerBound).min() else { return .onset }
        if moment < firstPeak { return .onset }
        if windows.contains(where: { $0.contains(moment) }) { return .peak }
        return .offset
    }

    /// The peak windows of every dose of the primary substance: the first dose
    /// carrying both peak boundaries names it.
    static func peakWindows(_ doses: [TripReport.Dose]) -> [Range<Date>] {
        func window(_ dose: TripReport.Dose) -> Range<Date>? {
            guard let start = dose.phases.first(where: { $0.label == TripReport.Phase.peakBegins })?.at,
                  let end = dose.phases.first(where: { $0.label == TripReport.Phase.wearingOff })?.at,
                  start < end
            else { return nil }
            return start ..< end
        }
        let ordered = doses.sorted { $0.timestamp < $1.timestamp }
        guard let primary = ordered.first(where: { window($0) != nil }) else { return [] }
        return ordered.filter { $0.name == primary.name }.compactMap(window)
    }

    // MARK: - Size cap

    /// Shortens the longest texts (timeline notes and the conclusion) to one
    /// common length until the JSON fits `maxBytes`: the longest notes lose the
    /// most and short ones stay whole. Never below ``minimumTruncatedLength``
    /// characters; when every text is at that floor the payload is returned
    /// over the cap, which dose.wiki still accepts.
    nonisolated static func fit(_ payload: Payload, maxBytes: Int) -> (payload: Payload, json: Data, truncated: Bool) {
        var payload = payload
        var truncated = false
        var json = encode(payload)
        while json.count > maxBytes {
            let texts = shortenableTexts(in: payload)
            let lengths = texts.map(\.text.count)
            guard let ceiling = commonLength(lengths: lengths, removing: json.count - maxBytes) else { break }
            for (slot, text) in texts where text.count > ceiling {
                replace(slot, with: truncate(text, to: ceiling), in: &payload)
            }
            truncated = true
            json = encode(payload)
        }
        return (payload, json, truncated)
    }

    /// The largest length that, applied to every longer text, removes at least
    /// `excess` bytes; `nil` when no length at or above the floor shortens
    /// anything. A text cut to `n` characters keeps `n - 1` of them plus a
    /// 3-byte ellipsis, and every character dropped is at least one byte.
    nonisolated static func commonLength(lengths: [Int], removing excess: Int) -> Int? {
        guard let longest = lengths.max(), longest > minimumTruncatedLength else { return nil }
        func removed(_ ceiling: Int) -> Int {
            lengths.reduce(0) { $0 + ($1 > ceiling ? $1 - ceiling - 2 : 0) }
        }
        var low = minimumTruncatedLength
        var high = longest - 1
        guard removed(low) >= excess else { return low }
        while low < high {
            let mid = (low + high + 1) / 2
            if removed(mid) >= excess { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Where a shortenable text lives in the payload.
    private nonisolated enum TextSlot {
        case entry(WritableKeyPath<Timeline, [Entry]?>, Int)
        case conclusion
    }

    private nonisolated static func shortenableTexts(in payload: Payload) -> [(slot: TextSlot, text: String)] {
        var texts: [(slot: TextSlot, text: String)] = []
        for phase in [\Timeline.onset, \.peak, \.offset] {
            for (index, entry) in (payload.timeline?[keyPath: phase] ?? []).enumerated() {
                texts.append((.entry(phase, index), entry.description))
            }
        }
        if let conclusion = payload.conclusion { texts.append((.conclusion, conclusion)) }
        return texts
    }

    private nonisolated static func replace(_ slot: TextSlot, with text: String, in payload: inout Payload) {
        switch slot {
        case let .entry(phase, index): payload.timeline?[keyPath: phase]?[index].description = text
        case .conclusion: payload.conclusion = text
        }
    }

    nonisolated static func truncate(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        let kept = text.prefix(max(0, length - 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return kept + "…"
    }

    // MARK: - Encoding

    nonisolated static func encode(_ payload: Payload) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(payload)) ?? Data()
    }

    /// RFC 4648 §5 base64url without padding.
    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

private extension String? {
    nonisolated var nilIfBlank: String? {
        self?.nilIfBlank
    }
}
