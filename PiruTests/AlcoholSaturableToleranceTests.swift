import Foundation
import Testing
@testable import Piru

/// Gate for the **capacity-limited exposure path** on the bundled pharmacology: ethanol has no
/// half-life anywhere (its clearing enzyme is saturated across the whole drinking range), so the
/// occupancy pipeline runs it on `(ka, F, Vmax, Km, Vd)` instead of `(ka, t½, Vd)`.
///
/// The numbers these assert against are the published ones the model is built from — Norberg 2000's
/// Vmax/Km, Levitt 2002's absorption rate — checked against the elimination rate Jones 2010 reports
/// for drinkers (β = 10–20 mg/100 mL/h): β is the *audit*, never an engine input.
@Suite("Alcohol saturable tolerance")
@MainActor
struct AlcoholSaturableToleranceTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    /// Two US standard drinks (14 g each, NIAAA), the note's worked example.
    private static let twoDrinksMg = 28_000.0
    private static let weightKg = 70.0

    private func parameters(_ name: String) -> PharmacologyParameters {
        SubstanceStore.shared.pharmacologyParameters(forSubstanceName: name)
    }

    private func alcoholTrack() async throws -> PKModel.ConcentrationTrack {
        await SubstanceStore.shared.ensureAllLoaded()
        let alcohol = parameters("Alcohol")
        return try #require(
            alcohol.saturableTrackNanomolar(doseMg: Self.twoDrinksMg, weightKg: Self.weightKg),
        )
    }

    /// nanomolar → mg/100 mL, the unit every published ethanol elimination rate is quoted in.
    private func mgPer100mL(_ nanomolar: Double, molarMass: Double) -> Double {
        nanomolar * molarMass / 1e6 / 10
    }

    @Test
    func `The saturable branch opens for alcohol and stays shut for a first-order substance`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let alcohol = parameters("Alcohol")
        let saturable = try #require(alcohol.saturableElimination, "alcohol carries no saturable row")
        #expect(alcohol.halfLifeMinutes == nil, "a half-life for ethanol would be ~5 min and wrong everywhere it matters")
        #expect(alcohol.canComputeOccupancy)
        #expect(saturable.kmMgPerL > 0)
        #expect(saturable.vmaxMgPerMin > 0)
        #expect(saturable.kaPerMin > 0)
        // The Michaelis-Menten volume, not the forensic Widmark one `pk_routes` carries.
        #expect(saturable.vdLPerKg == 0.55)

        // What alcohol's occupancy is computed against: ethanol's NMDA inhibition IC50 (~30 mM,
        // Lovinger 1989). The GABA-A δ-subunit row carries no half-max — the 3 mM figure attached to
        // it is a detection threshold whose low-concentration claim four laboratories could not
        // reproduce, so it must never come back as the engine's Hill constant.
        let primary = try #require(alcohol.primaryTarget)
        #expect(primary.target.localizedCaseInsensitiveContains("NMDA"))
        #expect(primary.halfMaxNanomolar == 30_000_000)
        #expect(!alcohol.targets.contains { $0.target.localizedCaseInsensitiveContains("GABA") })

        let diazepam = parameters("Diazepam")
        #expect(diazepam.saturableElimination == nil)
        #expect(diazepam.halfLifeMinutes != nil)
        #expect(diazepam.saturableTrackNanomolar(doseMg: 10, weightKg: Self.weightKg) == nil)
    }

    @Test
    func `The concentration curve declines linearly rather than exponentially`() async throws {
        let track = try await alcoholTrack()
        let peak = track.peakMinutes
        // Three equally spaced points well inside the declining phase, after absorption is done.
        let spacing = 30.0
        let first = track.value(atMinutes: peak + 90)
        let second = track.value(atMinutes: peak + 90 + spacing)
        let third = track.value(atMinutes: peak + 90 + 2 * spacing)
        #expect(third > 0, "the sample window must stay inside the decline")

        let firstDrop = first - second
        let secondDrop = second - third
        #expect(firstDrop > 0)
        // Zero-order: equal drops per unit time, so the second difference is ~0.
        #expect(abs(secondDrop - firstDrop) < 0.1 * firstDrop, "drops \(firstDrop) then \(secondDrop)")
        // And the discriminator: a first-order curve through the first two points would still be
        // falling by a *fraction* at the third, so it predicts a higher concentration than this.
        let exponentialPrediction = second * (second / first)
        #expect(third < 0.9 * exponentialPrediction, "third \(third), exponential would give \(exponentialPrediction)")
    }

    @Test
    func `Two drinks in a 70 kg body clear in about four hours at a published elimination rate`() async throws {
        let track = try await alcoholTrack()
        let molarMass = try #require(parameters("Alcohol").molarMassGramsPerMole)
        func bac(_ minutes: Double) -> Double {
            mgPer100mL(track.value(atMinutes: minutes), molarMass: molarMass)
        }

        // Peak lands in the first hour or two and in the range two drinks actually produce.
        #expect(track.peakMinutes > 30 && track.peakMinutes < 150)
        let peakBAC = mgPer100mL(track.peakValue, molarMass: molarMass)
        #expect(peakBAC > 25 && peakBAC < 60, "peak BAC \(peakBAC) mg/100 mL")

        // Jones 2010 (Forensic Sci Int 200:1-20): β = 10-15 mg/100 mL/h fasted, 15-20 non-fasted.
        let early = track.peakMinutes + 60
        let late = early + 60
        let slope = bac(early) - bac(late)
        #expect(slope > 10 && slope < 20, "decline \(slope) mg/100 mL/h")

        // Clear in roughly 3-4 h: under the 10 mg/100 mL mark (below where impairment is detectable)
        // inside 4 h, and past the sub-Km tail — the only stretch ethanol is first-order over, and the
        // only one a 5 min half-life would have described — inside 5 h.
        #expect(bac(4 * 60) < 10, "BAC at 4 h: \(bac(4 * 60))")
        #expect(bac(3 * 60) > 5, "two drinks should not have vanished at 3 h: \(bac(3 * 60))")
        #expect(bac(5 * 60) < 1, "BAC at 5 h: \(bac(5 * 60))")
    }

    // MARK: - Replay

    private func nmda(_ entries: [DoseEntry], at now: Date = AlcoholSaturableToleranceTests.now) -> ClassTolerance? {
        ToleranceStore.simulate(entries: entries, now: now, weightKg: Self.weightKg) {
            SubstanceStore.shared.pharmacologyParameters(forSubstanceName: $0)
        }[.nmdaAntagonist]
    }

    private func alcohol(_ amount: Double, unit: String, hoursAgo: Double) -> DoseEntry {
        DoseEntry(
            substance: "Alcohol", amount: amount, unit: unit,
            timestamp: Self.now.addingTimeInterval(-hoursAgo * 3_600),
        )
    }

    @Test
    func `Alcohol drives its own NMDA tolerance on its own kinetics`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let state = try #require(nmda([alcohol(28, unit: "g", hoursAgo: 1)]))
        #expect(state.contributors.contains("Alcohol"))
        #expect(state.occupancyNow > 0.1, "an hour in, alcohol is on board: \(state.occupancyNow)")
        // Modeled from sourced parameters, so the card is a prediction rather than a stand-in guess.
        #expect(state.confidence != .unverified)

        // Nine hours on there is nothing left at all — a first-order surrogate always leaves a tail.
        let cleared = try #require(nmda([alcohol(28, unit: "g", hoursAgo: 9)]))
        #expect(cleared.occupancyNow == 0)
    }

    @Test
    func `A drink logged by volume and the same ethanol logged by mass replay identically`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        // A 330 mL can at 5% ABV, converted the way the dose form converts it on save.
        let grams = ByVolumeDosing.grams(volumeML: 330, abv: 5)
        #expect(grams > 0)
        let byVolume = alcohol(grams, unit: "g", hoursAgo: 1)
        let byMass = alcohol(grams * 1_000, unit: "mg", hoursAgo: 1)
        #expect(byVolume.quantity?.milligrams == byMass.quantity?.milligrams)

        let fromVolume = try #require(nmda([byVolume]))
        let fromMass = try #require(nmda([byMass]))
        #expect(fromVolume.shiftFactor == fromMass.shiftFactor)
        #expect(fromVolume.occupancyNow == fromMass.occupancyNow)
    }

    @Test
    func `A dose in a unit that converts to no mass is not replayed`() async {
        await SubstanceStore.shared.ensureAllLoaded()
        // "units" is a count, not a mass: there is no number of milligrams to expose, and guessing
        // one is how a 1000x dose error gets modeled as tolerance.
        #expect(nmda([alcohol(2, unit: "units", hoursAgo: 1)]) == nil)
        #expect(nmda([alcohol(2, unit: "drink", hoursAgo: 1)]) == nil)
    }
}
