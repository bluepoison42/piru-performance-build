import Foundation
import Testing
@testable import Piru

/// The tolerance replay weighs every logged dose in milligrams, and its deep-layer
/// escalation divides that by the substance's reference dose, also in milligrams.
/// Both sides come from a parsed unit, so the same amount written in a different
/// mass unit replays identically, and a dose that is not a mass replays not at all.
@Suite("Tolerance dose units")
@MainActor
struct ToleranceDoseUnitTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private let resolve: (String) -> PharmacologyParameters? = {
        SubstanceStore.shared.pharmacologyParameters(forSubstanceName: $0)
    }

    /// One dose a day for `days` days, ending a day before ``now``.
    private func daily(_ substance: String, _ amount: Double, _ unit: String, days: Int = 10) -> [DoseEntry] {
        (0 ..< days).map { day in
            DoseEntry(
                substance: substance, amount: amount, unit: unit, route: .oral,
                timestamp: Self.now.addingTimeInterval(-Double(day) * 86_400 - 24 * 3_600),
            )
        }
    }

    private func replay(_ entries: [DoseEntry]) -> [ReceptorClasses.ReceptorClass: ClassTolerance] {
        ToleranceStore.simulate(entries: entries, now: Self.now, weightKg: 70, resolve: resolve)
    }

    @Test
    func `A gram-dosed opioid logged in grams replays the same as in milligrams`() throws {
        // Kratom's ladder is in grams. Read as milligrams, 5 g would be a thousandth
        // of a dose, and the deep gate (dose ÷ heavy reference) would never open.
        let grams = try #require(replay(daily("Kratom", 5, "g"))[.muOpioid])
        let milligrams = try #require(replay(daily("Kratom", 5_000, "mg"))[.muOpioid])
        #expect(grams.shiftFactor == milligrams.shiftFactor)
        #expect(grams.sDeep == milligrams.sDeep)
        #expect(grams.shiftFactor > 1, "five grams a day for ten days builds μ-opioid tolerance")
    }

    @Test
    func `A microgram-dosed substance logged in micrograms replays the same as in milligrams`() throws {
        let micrograms = try #require(replay(daily("LSD", 100, "µg"))[.psychedelic5HT2A])
        let milligrams = try #require(replay(daily("LSD", 0.1, "mg"))[.psychedelic5HT2A])
        #expect(micrograms.shiftFactor == milligrams.shiftFactor)
        #expect(micrograms.sDeep == milligrams.sDeep)
    }

    @Test
    func `A dose that is not a mass is left out of the replay rather than read as milligrams`() {
        // 5 mL of kratom has no mass; falling back to the bare number would replay it as 5 mg.
        #expect(replay(daily("Kratom", 5, "mL")).isEmpty)
    }
}
