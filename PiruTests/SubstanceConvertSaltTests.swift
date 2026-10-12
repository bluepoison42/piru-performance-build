import Foundation
import Testing
@testable import Piru

/// Salt-aware ladder units: `ladder(for:saltForm:)` carries the chosen salt's
/// `unit`, while a ladder with no salt carries the route's default-salt unit.
/// For a substance whose salts share a unit the two agree; they diverge only
/// when a selected salt is denominated differently from the route default.
@Suite("Substance ladder salt-awareness")
struct SubstanceConvertSaltTests {
    /// A multi-salt route where the default salt and another salt use DIFFERENT
    /// units: the route default (mirroring the first variant) is `mg`, while the
    /// "Threonate" form is dosed in `g` and a hypothetical "Hormone" form in `IU`.
    private var mixedUnitSubstance: Substance {
        let oral = SubstanceRoute(
            route: .oral,
            unit: "mg", // mirrors the default variant ("Citrate")
            doses: DoseRange(common: 400 ... 600),
            saltForms: [
                DoseVariant(saltForm: "Citrate", unit: "mg", doses: DoseRange(common: 400 ... 600)),
                DoseVariant(saltForm: "Threonate", unit: "g", doses: DoseRange(common: 1.5 ... 2)),
                DoseVariant(saltForm: "Hormone", unit: "IU", doses: DoseRange(common: 4 ... 8)),
            ],
        )
        return Substance(
            name: "MixedSalt",
            aliases: [],
            category: .supplement,
            defaultRoute: .oral,
            routes: [oral],
            effects: [],
        )
    }

    /// A normal single-form substance — no salt dimension.
    private var caffeine: Substance {
        Substance(
            name: "Caffeine",
            aliases: [],
            category: .stimulant,
            defaultRoute: .oral,
            routes: [SubstanceRoute(route: .oral, unit: "mg", doses: DoseRange(common: 50 ... 100))],
            effects: [],
        )
    }

    // MARK: - Salt overload uses the salt's unit; route-only uses the default

    @Test
    func `salt overload converts against the salt's own unit`() {
        // Threonate is dosed in grams: 1 g entered as "g" stays 1 g.
        #expect(mixedUnitSubstance.inLadderUnit(1, from: "g", route: .oral, saltForm: "Threonate") == 1)
        // Default-salt unit is mg, so the route-only path scales 1 g → 1000 mg.
        #expect(mixedUnitSubstance.inLadderUnit(1, from: "g", route: .oral) == 1_000)
    }

    @Test
    func `salt overload targets a non-mass salt unit the route default cannot`() {
        // The "Hormone" salt is denominated in IU. Converting an IU amount into
        // its own (IU) unit is an identity; the route-only path targets mg and,
        // unable to bridge IU↔mg, returns nil. This is the mis-conversion the
        // salt overload closes.
        #expect(mixedUnitSubstance.inLadderUnit(5, from: "IU", route: .oral, saltForm: "Hormone") == 5)
        #expect(mixedUnitSubstance.inLadderUnit(5, from: "IU", route: .oral) == nil)
    }

    @Test
    func `nil and unknown salt fall back to the default-salt unit`() {
        // nil salt and an unknown label both resolve the default (mg) unit, so
        // they match the route-only overload exactly.
        #expect(
            mixedUnitSubstance.inLadderUnit(1, from: "g", route: .oral, saltForm: nil)
                == mixedUnitSubstance.inLadderUnit(1, from: "g", route: .oral),
        )
        #expect(
            mixedUnitSubstance.inLadderUnit(1, from: "g", route: .oral, saltForm: "Sulfate")
                == mixedUnitSubstance.inLadderUnit(1, from: "g", route: .oral),
        )
    }

    @Test
    func `default salt agrees with the route-only overload`() {
        // The default salt ("Citrate") uses the same unit the route mirrors, so
        // naming it explicitly matches the route-only conversion.
        #expect(
            mixedUnitSubstance.inLadderUnit(1, from: "g", route: .oral, saltForm: "Citrate")
                == mixedUnitSubstance.inLadderUnit(1, from: "g", route: .oral),
        )
    }

    // MARK: - Single-form substances: both overloads behave identically

    @Test
    func `single-form substance converts identically with or without a salt`() {
        // No salt dimension → the salt overload (any label) and the route-only
        // overload resolve the same unit and produce identical results.
        #expect(
            caffeine.inLadderUnit(1, from: "g", route: .oral)
                == caffeine.inLadderUnit(1, from: "g", route: .oral, saltForm: nil),
        )
        #expect(
            caffeine.inLadderUnit(1, from: "g", route: .oral, saltForm: "Anhydrous")
                == caffeine.inLadderUnit(1, from: "g", route: .oral),
        )
        // And the value itself is correct: 1 g → 1000 mg.
        #expect(caffeine.inLadderUnit(1, from: "g", route: .oral) == 1_000)
    }
}

extension Substance {
    /// `amount` written in `unit`, read in the unit of the route's ladder for
    /// `saltForm` — the number tiering and the cumulative alert compare.
    func inLadderUnit(_ amount: Double, from unit: String, route: RouteOfAdministration, saltForm: String? = nil) -> Double? {
        ladder(for: route, saltForm: saltForm).flatMap { quantity(amount, unit: unit).value(in: $0.unit) }
    }
}
