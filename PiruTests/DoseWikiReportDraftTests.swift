import Foundation
import Testing
@testable import Piru

/// The `#piru=` payload dose.wiki's report form reads: the session's notes
/// bucketed by the modeled arc, and nothing about the person.
@Suite("DoseWikiReportDraft")
struct DoseWikiReportDraftTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(minutes: Double) -> Date {
        start.addingTimeInterval(minutes * 60)
    }

    /// A dose whose arc is: kicks in +30, peak begins +60, starts wearing off
    /// +180, effects end +300 — relative to its own timestamp.
    private func dose(
        _ name: String, offset: Double = 0, amount: Double = 120, unit: String = "mg",
        route: String = "Oral", unknown: Bool = false, phased: Bool = true,
    ) -> TripReport.Dose {
        let taken = at(minutes: offset)
        let marks: [Double] = [30, 60, 180, 300]
        return TripReport.Dose(
            id: UUID(), timestamp: taken, name: name, amount: amount, unit: unit, route: route,
            isUnknownDose: unknown,
            phases: phased
                ? zip(TripReport.Phase.reportLabels, marks).map { label, minutes in
                    TripReport.Phase(label: label, at: taken.addingTimeInterval(minutes * 60))
                }
                : [],
        )
    }

    private func note(
        _ minutes: Double, _ text: String = "steady", kind: SessionNote.Kind = .observation,
        shulgin: Int? = nil, mood: Int? = nil, heartRate: Int? = nil,
        descriptors: [TripReport.Descriptor] = [],
    ) -> TripReport.Note {
        TripReport.Note(
            id: UUID(), timestamp: at(minutes: minutes), kind: kind, text: text,
            shulgin: shulgin, mood: mood, energy: nil, social: nil, worked: nil,
            heartRate: heartRate, descriptors: descriptors,
        )
    }

    private func report(
        title: String? = nil, doses: [TripReport.Dose], notes: [TripReport.Note] = [], summary: String? = nil,
    ) -> TripReport {
        TripReport(title: title, sessionStart: start, doses: doses, notes: notes, summary: summary)
    }

    private func object(_ draft: DoseWikiReportDraft) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: draft.json) as? [String: Any])
    }

    private func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // MARK: - Phase bucketing

    @Test
    func `Notes land in onset, peak and offset by the dose's modeled arc`() {
        let draft = DoseWikiReportDraft(report: report(
            doses: [dose("MDMA")],
            notes: [note(-10, "before"), note(30, "coming up"), note(90, "peaking"), note(200, "fading")],
        ))
        let timeline = draft.payload.timeline
        #expect(timeline?.onset?.map(\.description) == ["before", "coming up"])
        #expect(timeline?.peak?.map(\.description) == ["peaking"])
        #expect(timeline?.offset?.map(\.description) == ["fading"])
    }

    @Test
    func `The peak window opens at peak begins and closes at starts wearing off`() {
        let doses = [dose("MDMA")]
        #expect(DoseWikiReportDraft.phase(at: at(minutes: 59), doses: doses) == .onset)
        #expect(DoseWikiReportDraft.phase(at: at(minutes: 60), doses: doses) == .peak)
        #expect(DoseWikiReportDraft.phase(at: at(minutes: 179), doses: doses) == .peak)
        #expect(DoseWikiReportDraft.phase(at: at(minutes: 180), doses: doses) == .offset)
    }

    @Test
    func `A redose of the primary substance extends its peak; another substance does not`() {
        let redosed = [dose("MDMA"), dose("MDMA", offset: 150, amount: 60)]
        // Primary peak 60–180, redose peak 210–330.
        #expect(DoseWikiReportDraft.phase(at: at(minutes: 240), doses: redosed) == .peak)
        #expect(DoseWikiReportDraft.phase(at: at(minutes: 195), doses: redosed) == .offset)

        let combined = [dose("LSD"), dose("Cannabis", offset: 360)]
        // The joint's peak (420–540) leaves the late LSD note in offset.
        #expect(DoseWikiReportDraft.phase(at: at(minutes: 450), doses: combined) == .offset)
    }

    @Test
    func `The first phased dose names the primary substance`() {
        let doses = [dose("Kratom", phased: false), dose("LSD", offset: 30)]
        #expect(DoseWikiReportDraft.phase(at: at(minutes: 60), doses: doses) == .onset)
        #expect(DoseWikiReportDraft.phase(at: at(minutes: 100), doses: doses) == .peak)
    }

    @Test
    func `Without phases every note is onset`() {
        let draft = DoseWikiReportDraft(report: report(
            doses: [dose("Kratom", phased: false)], notes: [note(10), note(500)],
        ))
        #expect(draft.payload.timeline?.onset?.count == 2)
        #expect(draft.payload.timeline?.peak == nil)
        #expect(draft.payload.timeline?.offset == nil)
    }

    // MARK: - Fields

    @Test
    func `T+ offsets are hours and zero-padded minutes, minus before the start`() {
        #expect(DoseWikiReportDraft.tPlus(0) == "T+0:00")
        #expect(DoseWikiReportDraft.tPlus(30 * 60) == "T+0:30")
        #expect(DoseWikiReportDraft.tPlus(65 * 60) == "T+1:05")
        #expect(DoseWikiReportDraft.tPlus(26 * 3_600 + 5 * 60) == "T+26:05")
        #expect(DoseWikiReportDraft.tPlus(-15 * 60) == "T-0:15")
        #expect(DoseWikiReportDraft.tPlus(-20) == "T+0:00")
    }

    @Test
    func `Substances carry name, slug, dose and dose.wiki's route name`() {
        let mdma = dose("MDMA")
        let snorted = dose("Ketamine", amount: 30, route: "Insufflation")
        let draft = DoseWikiReportDraft(report: report(doses: [mdma, snorted])) { dose in
            dose.id == mdma.id ? "mdma" : nil
        }
        let substances = draft.payload.substances
        #expect(substances == [
            .init(name: "MDMA", slug: "mdma", dose: "120 mg", roa: "oral"),
            .init(name: "Ketamine", slug: nil, dose: "30 mg", roa: "insufflated"),
        ])
    }

    @Test
    func `The catalog supplies dose.wiki slugs by name or alias`() async {
        await SubstanceStore.shared.ensureAllLoaded()
        #expect(SubstanceLibrary.dosewikiSlug(for: "MDMA") == "mdma")
        #expect(SubstanceLibrary.dosewikiSlug(for: "Lysergic Acid Diethylamide") == "lsd")
        #expect(SubstanceLibrary.dosewikiSlug(for: "Not A Substance 123") == nil)
    }

    @Test
    func `Every route maps to dose.wiki's vocabulary`() {
        let expected: [RouteOfAdministration: String] = [
            .oral: "oral", .sublingual: "sublingual", .buccal: "buccal", .insufflation: "insufflated",
            .inhalation: "inhaled", .intravenous: "intravenous", .intramuscular: "intramuscular",
            .subcutaneous: "subcutaneous", .transdermal: "transdermal", .rectal: "rectal", .other: "other",
        ]
        for route in RouteOfAdministration.allCases {
            #expect(DoseWikiReportDraft.roa(route.displayName) == expected[route])
        }
    }

    @Test
    func `An unknown amount omits the dose and the title names the substance alone`() throws {
        let draft = DoseWikiReportDraft(report: report(doses: [dose("Cannabis", unknown: true)]))
        let substances = try #require(try object(draft)["substances"] as? [[String: Any]])
        #expect(substances.first?["dose"] == nil)
        #expect(draft.payload.title == "Cannabis")
    }

    @Test
    func `The title is the session's, or each substance once with its first dose`() {
        let doses = [dose("MDMA"), dose("MDMA", offset: 90, amount: 60), dose("LSD", amount: 100, unit: "µg")]
        #expect(DoseWikiReportDraft(report: report(doses: doses)).payload.title == "MDMA, 120 mg + LSD, 100 µg")
        #expect(DoseWikiReportDraft(report: report(title: "Beach day", doses: doses)).payload.title == "Beach day")
        #expect(DoseWikiReportDraft(report: report(doses: [])).payload.title == "Trip report")
    }

    @Test
    func `A check-in renders its ratings, text and descriptors as text`() {
        let euphoria = TripReport.Descriptor(id: "euphoria", name: "euphoria", domain: "emotional")
        let checkIn = note(
            90, "warm", kind: .checkIn, shulgin: 2, mood: 2, heartRate: 84, descriptors: [euphoria],
        )
        #expect(DoseWikiReportDraft.description(for: checkIn) == "Check-in · ++ · mood +2 · ♥ 84\nwarm\neuphoria")
    }

    @Test
    func `The summary is the conclusion, descriptors are the tags`() {
        let euphoria = TripReport.Descriptor(id: "euphoria", name: "euphoria", domain: "emotional")
        let empathy = TripReport.Descriptor(id: "empathy", name: "empathy", domain: "emotional")
        let draft = DoseWikiReportDraft(report: report(
            doses: [dose("MDMA")],
            notes: [note(90, descriptors: [euphoria]), note(120, descriptors: [euphoria, empathy])],
            summary: "Lovely night.",
        ))
        #expect(draft.payload.conclusion == "Lovely night.")
        #expect(draft.payload.tags == ["euphoria", "empathy"])
    }

    // MARK: - Omission and privacy

    @Test
    func `Empty fields are omitted`() throws {
        let draft = DoseWikiReportDraft(report: report(doses: [dose("MDMA")]))
        let json = try object(draft)
        #expect(Set(json.keys) == ["v", "source", "title", "substances"])
        #expect(json["v"] as? Int == 1)
        #expect(json["source"] as? String == "piru")

        let substance = try #require((json["substances"] as? [[String: Any]])?.first)
        #expect(Set(substance.keys) == ["name", "dose", "roa"])
    }

    @Test
    func `The payload never carries subject, contact, consent or location fields`() throws {
        let draft = DoseWikiReportDraft(report: report(
            title: "Night", doses: [dose("MDMA")], notes: [note(90)], summary: "Fine.",
        )) { _ in "mdma" }
        let allowed: Set = ["v", "source", "title", "substances", "introduction", "timeline", "conclusion", "tags"]
        let json = try object(draft)
        #expect(Set(json.keys).isSubset(of: allowed))
        let forbidden = ["age", "weight", "sex", "gender", "email", "contact", "consent", "location", "latitude", "sessions"]
        let raw = try #require(String(data: draft.json, encoding: .utf8))
        for key in forbidden {
            #expect(!raw.contains("\"\(key)\""))
        }
    }

    // MARK: - Size cap and encoding

    @Test
    func `An oversized report shortens its longest notes to fit the cap`() {
        let long = String(repeating: "a very long sentence about the evening. ", count: 90)
        let notes = (0 ..< 20).map { note(Double($0 * 10), long) } + [note(400, "short")]
        let draft = DoseWikiReportDraft(report: report(doses: [dose("MDMA")], notes: notes), maxBytes: 16 * 1024)
        #expect(draft.wasTruncated)
        #expect(draft.json.count <= 16 * 1024)
        let descriptions = [draft.payload.timeline?.onset, draft.payload.timeline?.peak, draft.payload.timeline?.offset]
            .compactMap(\.self).flatMap(\.self).map(\.description)
        #expect(descriptions.contains("short"))
        #expect(descriptions.contains { $0.hasSuffix("…") })
    }

    @Test
    func `A report within the cap is left whole`() {
        let draft = DoseWikiReportDraft(report: report(doses: [dose("MDMA")], notes: [note(90, "fine")]))
        #expect(!draft.wasTruncated)
        #expect(draft.payload.timeline?.peak?.first?.description == "fine")
    }

    @Test
    func `The URL fragment is unpadded base64url that round-trips to the JSON`() throws {
        // "?>" and "ÿ" force "+" / "/" into plain base64.
        let draft = DoseWikiReportDraft(report: report(
            doses: [dose("MDMA")], notes: [note(90, "ÿÿ?>?>~~ ünïcødé 日本語")],
        ))
        let url = draft.url.absoluteString
        let prefix = "https://dose.wiki/reports/submit#piru="
        #expect(url.hasPrefix(prefix))
        let fragment = String(url.dropFirst(prefix.count))
        #expect(!fragment.contains("="))
        #expect(!fragment.contains("+"))
        #expect(!fragment.contains("/"))
        #expect(decodeBase64URL(fragment) == draft.json)

        let decoded = try JSONDecoder().decode(DoseWikiReportDraft.Payload.self, from: draft.json)
        #expect(decoded == draft.payload)
    }
}
