import Foundation

/// How far a meal moves one oral dose's onset, and whether that figure is the substance's own
/// or the generic stand-in.
struct MealOnsetDelay: Equatable {
    let minutes: Double
    let isGeneric: Bool

    /// The shift as a person reads it: rounded to five minutes, since no food
    /// study resolves finer than that ("55 min", "1 hr, 55 min").
    static func formatted(_ minutes: Double) -> String {
        Duration.seconds((minutes / 5).rounded() * 5 * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

extension MealState {
    /// The onset delay this state gives a dose of `substance`: its fed-vs-fasted Tmax delay (the
    /// product's own row, the base form's, or the generic one) scaled by ``fedFraction``. `nil`
    /// for a route that never reaches the stomach, for a zero-order substance (alcohol), whose
    /// curve comes from an absorption rate rather than phase lengths and is left unshifted, or when
    /// the table holds no answer at all. A substance whose study found no delay returns `0`
    /// minutes, which is a real answer.
    @MainActor
    func onsetDelay(
        forSubstance substance: String,
        product: String?,
        route: RouteOfAdministration,
    ) -> MealOnsetDelay? {
        guard route == .oral,
              SubstanceStore.shared.zeroOrderProfiles()[substance.lowercased()] == nil,
              let effect = SubstanceLibrary.foodEffect(for: substance, product: product)
        else { return nil }
        return MealOnsetDelay(minutes: effect.tmaxDelayMinutes * fedFraction, isGeneric: effect.isGeneric)
    }
}

/// How the meal logged with a dose moves its curve. Every site that turns an entry into a
/// duration (the timeline, the Live Activity, notifications, body load) passes its resolved
/// profile through ``applyingMeal(to:)``, so they all shift by the same minutes.
extension DoseEntry {
    /// `duration` with its onset moved later by what was eaten before this dose.
    @MainActor
    func applyingMeal(to duration: DurationProfile?) -> DurationProfile? {
        MealState.shifting(duration, by: meal, substance: substance, product: productName, route: route)
    }
}

extension MealState {
    /// `duration` with its onset moved later by `meal`, eaten before a dose of `substance`
    /// (logged as `product`) taken by `route`: what ``DoseEntry/applyingMeal(to:)`` does,
    /// for a caller holding a value snapshot of the dose.
    @MainActor
    static func shifting(
        _ duration: DurationProfile?, by meal: MealState?, substance: String, product: String?, route: RouteOfAdministration,
    ) -> DurationProfile? {
        guard let duration, let meal,
              let delay = meal.onsetDelay(forSubstance: substance, product: product, route: route),
              delay.minutes > 0
        else { return duration }
        return duration.delayingOnset(by: delay.minutes)
    }
}
