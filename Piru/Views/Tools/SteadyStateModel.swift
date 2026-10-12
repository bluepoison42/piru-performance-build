import Foundation
import Observation

/// Pure steady-state pharmacokinetics for a fixed repeated-dosing schedule.
///
/// Builds on the same one-compartment oral model as the single-dose
/// ``HalfLifeCalculatorView``: it superimposes `PKModel.fractionRemainingInBody`
/// at a fixed interval, so the plateau is the existing curve summed — no new
/// pharmacology. Amounts are in the dose's own units (a body-content mass), which
/// needs no volume of distribution; the accumulation ratio is dimensionless and
/// depends only on the half-life and the interval.
nonisolated enum SteadyStateModel {
    struct Result: Equatable {
        let dose: Double

        /// Body-content curve while climbing to plateau, as `(minutes, amount)`.
        let curve: [CurvePoint]
        let totalMinutes: Double

        /// Body content just after / just before a dose at steady state, and the
        /// interval mean — all in the dose's units.
        let peakAmount: Double
        let troughAmount: Double
        let averageAmount: Double

        /// Trough-based accumulation ratio `1/(1 − e^(−ke·τ))` — how many single
        /// doses' worth accumulate. Depends only on half-life and interval.
        let accumulationRatio: Double
        /// Peak-to-trough swing as a percentage of the interval mean.
        let fluctuationPercent: Double

        /// Time to reach ~90% / ~95% / ~97% of steady state (a function of the
        /// half-life alone, not the dose or interval), in minutes.
        let time90: Double
        let time95: Double
        let time97: Double
    }

    struct CurvePoint: Equatable {
        let minutes: Double
        let amount: Double
    }

    /// Half-lives the model projects, in minutes: one minute to ten years.
    /// The bounds keep every derived time (the curve's span, the dose count, the
    /// chart's axis ticks) finite and inside `Int`, whatever a user types.
    static let halfLifeRange: ClosedRange<Double> = 1 ... 10 * 365.25 * 1_440

    /// Dosing intervals the model projects, in minutes: one minute to a year
    /// (the longest real schedule is a once-yearly infusion).
    static let intervalRange: ClosedRange<Double> = 1 ... 365.25 * 1_440

    /// Most doses one projection sums; see ``compute(dose:halfLifeMinutes:intervalMinutes:ke:ka:)``.
    static let maximumDoses: Double = 5_000

    /// Why a schedule gets no projection.
    enum Refusal: Equatable {
        /// The half-life falls outside ``halfLifeRange``.
        case halfLifeOutOfRange
        /// The interval falls outside ``intervalRange``.
        case intervalOutOfRange
        /// The schedule needs more than ``maximumDoses`` doses to settle.
        case tooManyDoses
    }

    /// The reason ``compute(dose:halfLifeMinutes:intervalMinutes:ke:ka:)`` refuses
    /// a half-life and interval, or `nil` when it projects them.
    static func refusal(halfLifeMinutes: Double, intervalMinutes: Double) -> Refusal? {
        guard halfLifeRange.contains(halfLifeMinutes) else { return .halfLifeOutOfRange }
        guard intervalRange.contains(intervalMinutes) else { return .intervalOutOfRange }
        // The cap bounds the O(samples × doses) accumulation: a near-zero typed
        // interval against a long half-life otherwise yields hundreds of
        // thousands of doses and a multi-second hang per keystroke. A schedule
        // that needs more doses than the cap to settle gets no projection,
        // since a truncated sum would report a plateau it never reached.
        let doses = scheduledDoses(halfLifeMinutes: halfLifeMinutes, intervalMinutes: intervalMinutes)
        guard doses <= maximumDoses else { return .tooManyDoses }
        return nil
    }

    /// How long a projection runs: past ~97 % of steady state with room to
    /// spare, and at least six intervals.
    private static func projectedMinutes(halfLifeMinutes: Double, intervalMinutes: Double) -> Double {
        max(5.0 * halfLifeMinutes * 1.2, intervalMinutes * 6, intervalMinutes + 1)
    }

    private static func scheduledDoses(halfLifeMinutes: Double, intervalMinutes: Double) -> Double {
        projectedMinutes(halfLifeMinutes: halfLifeMinutes, intervalMinutes: intervalMinutes) / intervalMinutes + 1
    }

    /// `nil` when the dose or a rate constant is non-positive or non-finite, or
    /// ``refusal(halfLifeMinutes:intervalMinutes:)`` names a reason.
    static func compute(dose: Double, halfLifeMinutes: Double, intervalMinutes: Double, ke: Double, ka: Double) -> Result? {
        guard dose > 0, dose.isFinite,
              ke > 0, ke.isFinite, !ka.isNaN,
              refusal(halfLifeMinutes: halfLifeMinutes, intervalMinutes: intervalMinutes) == nil
        else { return nil }

        // Fraction-of-steady-state approach depends only on half-life:
        // 1 − 2^(−t/t½). 90% at 3.32·t½, 95% at 4.32·t½, ~97% at 5·t½.
        let time90 = 3.3219 * halfLifeMinutes
        let time95 = 4.3219 * halfLifeMinutes
        let time97 = 5.0 * halfLifeMinutes

        let totalMinutes = projectedMinutes(halfLifeMinutes: halfLifeMinutes, intervalMinutes: intervalMinutes)
        let doseCount = Int(scheduledDoses(halfLifeMinutes: halfLifeMinutes, intervalMinutes: intervalMinutes))

        /// Body content = Σ over already-taken doses of dose · fractionRemaining.
        func bodyContent(at t: Double) -> Double {
            var total = 0.0
            for n in 0 ..< doseCount {
                let elapsed = t - Double(n) * intervalMinutes
                if elapsed < 0 { break }
                total += dose * PKModel.fractionRemainingInBody(at: elapsed, ke: ke, ka: ka)
            }
            return total
        }

        let sampleCount = 600
        let step = totalMinutes / Double(sampleCount)
        var curve: [CurvePoint] = []
        curve.reserveCapacity(sampleCount + 1)
        for i in 0 ... sampleCount {
            let t = Double(i) * step
            curve.append(CurvePoint(minutes: t, amount: bodyContent(at: t)))
        }

        // Peak / trough over the final full interval (the plateau).
        let ssStart = totalMinutes - intervalMinutes
        var peak = 0.0
        var trough = Double.infinity
        let ssSteps = 240
        for i in 0 ... ssSteps {
            let t = ssStart + intervalMinutes * Double(i) / Double(ssSteps)
            let c = bodyContent(at: t)
            peak = max(peak, c)
            trough = min(trough, c)
        }
        if !trough.isFinite { trough = 0 }
        let average = (peak + trough) / 2
        let fluctuation = average > 0 ? (peak - trough) / average * 100 : 0
        let accumulation = 1 / (1 - exp(-ke * intervalMinutes))

        return Result(
            dose: dose,
            curve: curve, totalMinutes: totalMinutes,
            peakAmount: peak, troughAmount: trough, averageAmount: average,
            accumulationRatio: accumulation, fluctuationPercent: fluctuation,
            time90: time90, time95: time95, time97: time97,
        )
    }
}

/// The schedule ``SteadyStateView`` collects, plus the plateau projected from it.
///
/// ``result`` is **stored**, refreshed by ``refresh()`` only when
/// ``recomputeKey`` changes. Never make it a computed property:
/// ``SteadyStateModel/compute`` sums up to 5,000 superposed doses at each of
/// ~840 sample points, and a `body` that evaluates it runs that integration on
/// every unrelated state change.
@Observable
@MainActor
final class SteadyStateInputs {
    var substanceName = ""
    var selectedSubstance: Substance?
    var doseAmount: Double? = 20
    var doseUnit: String = "mg"
    var intervalHours: Double? = 24
    var useCustomHalfLife = false
    var customHalfLifeHours: Double?
    var selectedRoute: RouteOfAdministration = .oral

    private(set) var result: SteadyStateModel.Result?
    /// Why the schedule as typed gets no projection; `nil` while there is a
    /// result, or an input is still missing.
    private(set) var refusal: SteadyStateModel.Refusal?

    /// Everything ``refresh()`` reads, in one `Equatable` value the view watches
    /// so no input can be added without also driving the recompute.
    struct RecomputeKey: Equatable {
        let doseAmount: Double?
        let intervalHours: Double?
        let useCustomHalfLife: Bool
        let customHalfLifeHours: Double?
        let route: RouteOfAdministration
        let substanceName: String?
        let substanceHalfLife: Double?
    }

    var recomputeKey: RecomputeKey {
        RecomputeKey(
            doseAmount: doseAmount,
            intervalHours: intervalHours,
            useCustomHalfLife: useCustomHalfLife,
            customHalfLifeHours: customHalfLifeHours,
            route: selectedRoute,
            substanceName: selectedSubstance?.name,
            substanceHalfLife: selectedSubstance?.halfLifeMinutes,
        )
    }

    var dose: Double {
        doseAmount ?? 0
    }

    /// A substance is picked, its record knows no half-life, and the user has
    /// not typed one — the only state the no-data card answers.
    var isMissingHalfLife: Bool {
        selectedSubstance != nil && !useCustomHalfLife && selectedSubstance?.halfLifeMinutes == nil
    }

    /// Adopt a substance picked from search, along with the unit and route it is
    /// normally taken by.
    func select(_ substance: Substance) {
        selectedSubstance = substance
        substanceName = substance.name
        doseUnit = substance.defaultUnit
        selectedRoute = substance.defaultRoute
    }

    func refresh() {
        guard let halfLife = effectiveHalfLife, halfLife > 0,
              let hours = intervalHours, hours > 0, dose > 0
        else {
            result = nil
            refusal = nil
            return
        }
        let params = PKResolver.rateConstants(
            halfLifeMinutes: halfLife,
            duration: selectedSubstance?.resolveDuration(for: selectedRoute),
        )
        result = SteadyStateModel.compute(
            dose: dose, halfLifeMinutes: halfLife, intervalMinutes: hours * 60,
            ke: params.ke, ka: params.ka,
        )
        refusal = result == nil
            ? SteadyStateModel.refusal(halfLifeMinutes: halfLife, intervalMinutes: hours * 60)
            : nil
    }

    private var effectiveHalfLife: Double? {
        HalfLifeCalculation.effectiveHalfLife(
            useCustom: useCustomHalfLife,
            customHours: customHalfLifeHours,
            substance: selectedSubstance,
        )
    }
}
