import Foundation

/// The release forms a substance's dose ladder and duration profile describe.
///
/// Every ladder and duration the app carries is measured on the base form: the
/// unspecified product (the PSID `0` sentinel) or immediate release (`IR`),
/// which *is* the base form's kinetics. Every other code — `XR`, `DEP`, and any
/// future extended or delayed system — names a formulation none of those
/// numbers were written for.
enum BaseReleaseForm {
    /// Release-form codes the base ladder describes. `0` is compared literally
    /// rather than via `PSID.unspecifiedFacet`, which is main-actor isolated.
    nonisolated static let codes: Set<String> = ["0", "IR"]

    /// Whether `releaseForm` is one the base ladder describes. A missing or
    /// empty form is the unspecified product and counts.
    nonisolated static func contains(_ releaseForm: String?) -> Bool {
        guard let releaseForm, !releaseForm.isEmpty else { return true }
        return codes.contains(releaseForm.uppercased())
    }
}

/// The one classifier behind every dose tier the app shows: the entry detail
/// pill, the edit readout, journal rows, the quick-log picker and tray, and the
/// Insights tier breakdown.
extension Substance {
    /// The ladder for a route narrowed to a form, paired with that form's unit.
    /// `nil` when the route has no ladder.
    func ladder(for route: RouteOfAdministration, saltForm: String? = nil, isomer: String? = nil) -> DoseLadder? {
        doseRange(for: route, saltForm: saltForm, isomer: isomer).map {
            DoseLadder(range: $0, unit: unit(for: route, saltForm: saltForm, isomer: isomer))
        }
    }

    /// The ladder that scales a dose of this substance on `route`: the route's own,
    /// else the default route's, else any route that has one — each with its own
    /// unit, so a fallback ladder is never read in the logged route's unit. Without
    /// the fallback a dose on a route the library has no ladder for draws at full
    /// height regardless of amount, collapsing light/common/heavy across the journal.
    func scalingLadder(for route: RouteOfAdministration) -> DoseLadder? {
        let candidates = [route, defaultRoute] + routes.map(\.route)
        return candidates.lazy.compactMap { self.ladder(for: $0) }.first { $0.range.hasAnyValue }
    }

    /// The dose a fresh entry pre-fills with and steps from — the ladder's common
    /// floor, else the nearest tier that exists — expressed in `unit`. `nil` when no
    /// ladder describes this route and form, or its unit can't be expressed in `unit`.
    func referenceDose(route: RouteOfAdministration, unit: String, saltForm: String? = nil, isomer: String? = nil) -> Double? {
        guard let ladder = ladder(for: route, saltForm: saltForm, isomer: isomer) else { return nil }
        let doses = ladder.range
        let reference = doses.common?.lowerBound
            ?? doses.light?.upperBound
            ?? doses.strong?.lowerBound
            ?? doses.threshold
            ?? doses.heavy
        return reference.flatMap { ladder.quantity($0).value(in: unit) }
    }

    /// The ladder a dose in this form is judged against, or `nil` when no ladder
    /// describes it.
    ///
    /// The route's ladder is narrowed to the salt and isomer, and exists only
    /// for a base release form (``BaseReleaseForm``). An extended-release
    /// product spreads its dose over the day: 36 mg of Concerta is a morning
    /// dose, and the immediate-release ladder would call it "strong". The app
    /// holds no ladder for those forms and authors none, since a prescription
    /// product's therapeutic range reads as dosing advice. So such a dose has
    /// no tier, exactly like a dose of unknown amount.
    func tierLadder(
        for route: RouteOfAdministration, saltForm: String?, isomer: String?, releaseForm: String?,
    ) -> DoseLadder? {
        guard BaseReleaseForm.contains(releaseForm),
              let ladder = ladder(for: route, saltForm: saltForm, isomer: isomer),
              ladder.range.hasAnyValue else { return nil }
        return ladder
    }

    /// Where `dose` of this substance sits on its ``tierLadder(for:saltForm:isomer:releaseForm:)``.
    /// `nil` when no ladder describes the dose, or the dose's unit can't be
    /// expressed in the ladder's.
    func doseLevel(
        of dose: DoseQuantity,
        route: RouteOfAdministration, saltForm: String?, isomer: String?, releaseForm: String?,
    ) -> DoseLevel? {
        tierLadder(for: route, saltForm: saltForm, isomer: isomer, releaseForm: releaseForm)?.level(of: dose)
    }
}

extension DoseEntry {
    /// This dose's tier on `substance`'s ladder — `nil` for an unknown amount or
    /// a form no ladder describes. See ``Substance/tierLadder(for:saltForm:isomer:releaseForm:)``.
    @MainActor
    func doseLevel(on substance: Substance) -> DoseLevel? {
        guard let dose = substance.quantity(of: self) else { return nil }
        return substance.doseLevel(
            of: dose, route: route, saltForm: saltForm, isomer: isomer, releaseForm: releaseForm,
        )
    }
}
