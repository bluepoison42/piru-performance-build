import Foundation
import Testing
@testable import Piru

@Suite("DoseQuantity")
struct DoseQuantityTests {
    /// `amount` written in `from`, read in `to`.
    private func convert(_ amount: Double, from: String, to: String) -> Double? {
        DoseQuantity(amount, unit: from).value(in: to)
    }

    // MARK: - Same unit

    @Test
    func `Same unit returns amount unchanged`() {
        #expect(convert(100, from: "mg", to: "mg") == 100)
        #expect(convert(50, from: "g", to: "g") == 50)
        #expect(convert(200, from: "µg", to: "µg") == 200)
    }

    // MARK: - mg conversions

    @Test
    func `mg to g`() {
        let result = convert(1_000, from: "mg", to: "g")
        #expect(result == 1.0)
    }

    @Test
    func `mg to µg`() {
        let result = convert(1, from: "mg", to: "µg")
        #expect(result == 1_000)
    }

    // MARK: - g conversions

    @Test
    func `g to mg`() {
        let result = convert(1, from: "g", to: "mg")
        #expect(result == 1_000)
    }

    @Test
    func `g to µg`() {
        let result = convert(1, from: "g", to: "µg")
        #expect(result == 1_000_000)
    }

    // MARK: - µg conversions

    @Test
    func `µg to mg`() {
        let result = convert(500, from: "µg", to: "mg")
        #expect(result == 0.5)
    }

    @Test
    func `µg to g`() {
        let result = convert(1_000_000, from: "µg", to: "g")
        #expect(result == 1.0)
    }

    // MARK: - Non-mass units

    @Test
    func `Non-mass from-unit returns nil`() {
        #expect(convert(10, from: "mL", to: "mg") == nil)
    }

    @Test
    func `Non-mass to-unit returns nil`() {
        #expect(convert(10, from: "mg", to: "IU") == nil)
    }

    @Test
    func `Both non-mass returns nil`() {
        #expect(convert(10, from: "mL", to: "IU") == nil)
    }

    // MARK: - Edge cases

    @Test
    func `Zero amount`() {
        #expect(convert(0, from: "mg", to: "g") == 0)
    }

    @Test
    func `Very small amount preserves precision`() {
        let result = convert(0.001, from: "mg", to: "µg")
        #expect(result == 1.0)
    }

    // MARK: - Spelling of the micro prefix

    @Test
    func `Greek mu converts exactly like the micro sign`() {
        // U+03BC GREEK SMALL LETTER MU vs U+00B5 MICRO SIGN. The catalog holds
        // both because upstreams type them differently, and matching only the
        // second meant LSD, all three fentanyl routes and sufentanil IV
        // converted to nothing at all.
        #expect(convert(1_000, from: "\u{03BC}g", to: "mg") == 1.0)
        #expect(convert(1, from: "mg", to: "\u{03BC}g") == 1_000)
        #expect(convert(50, from: "\u{03BC}g", to: "\u{00B5}g") == 50)
    }

    @Test
    func `Written-out and abbreviated mass units convert`() {
        for spelling in ["mcg", "ug", "micrograms", "MCG"] {
            #expect(convert(1_000, from: spelling, to: "mg") == 1.0, "\(spelling)")
        }
        #expect(convert(1, from: "grams", to: "mg") == 1_000)
        #expect(convert(5, from: "mgs", to: "mg") == 5)
    }

    @Test
    func `A qualified unit is not folded onto the bare one`() {
        // "mg (freebase)" states a basis. Treating it as plain mg would let a
        // freebase amount be compared against a salt amount as though the
        // qualifier were decoration.
        #expect(convert(10, from: "mg (freebase)", to: "mg") == nil)
        #expect(convert(10, from: "mg (salt)", to: "µg") == nil)
    }

    @Test
    func `A rate is not a mass`() {
        #expect(convert(25, from: "µg/hr", to: "µg") == nil)
        #expect(convert(25, from: "mcg/hr (patch)", to: "mg") == nil)
        #expect(convert(5, from: "mg/kg", to: "mg") == nil)
    }

    @Test
    func `Identity holds for units that are not masses at all`() {
        // The inventory replay converts a stock unit to itself; it must not
        // start failing just because mL is not convertible to a mass.
        #expect(convert(30, from: "mL", to: "mL") == 30)
        #expect(convert(2, from: "seeds", to: "seeds") == 2)
    }

    @Test
    func `Microgram-dosed substances get a critical precision warning`() {
        // The reason the spelling mattered: an unconvertible unit made
        // dosingPrecision fall through to .none, so the sub-milligram warning
        // was suppressed on exactly the drugs whose margin is thinnest.
        let lsd = DoseLadder(range: DoseRange(common: 60 ... 200), unit: "micrograms")
        #expect(lsd.dosingPrecision == .critical)
        let fentanyl = DoseLadder(range: DoseRange(common: 25 ... 50), unit: "\u{03BC}g")
        #expect(fentanyl.dosingPrecision == .critical)
    }

    // MARK: - Exactness

    @Test
    func `Gram and microgram doses land exactly on milligrams`() {
        // Foundation converts through kilograms and turns 0.08 g into
        // 80.00000000000001 mg, which drops a dose logged exactly on a tier
        // boundary into the tier below. µg, mg and g convert through mg.
        #expect(DoseQuantity(0.08, unit: "g").milligrams == 80)
        #expect(DoseQuantity(80_000, unit: "µg").milligrams == 80)
        #expect(DoseQuantity(0.3, unit: "g").value(in: "mg") == 300)
        let heavy = DoseLadder(range: DoseRange(strong: 140 ... 300, heavy: 300), unit: "mg")
        #expect(heavy.level(of: DoseQuantity(0.3, unit: "g")) == .heavy)
    }

    @Test
    func `Foundation's own equality holds across dose-mass units`() {
        // Measurement's == compares base-unit values exactly. With UnitMass the
        // base is the kilogram and 0.08 g != 80 mg; with a milligram base the
        // common cases compare equal and hash alike, with no fuzzy == overload.
        #expect(Measurement<UnitDoseMass>.g(0.08) == .mg(80))
        #expect(Measurement(value: 80_000, unit: UnitDoseMass.micrograms) == .mg(80))
        #expect(Set([Measurement<UnitDoseMass>.g(1), .mg(1_000)]).count == 1)
        #expect(Measurement(value: 0.08, unit: UnitMass.grams) != Measurement(value: 80, unit: UnitMass.milligrams))
    }

    // MARK: - Families

    @Test
    func `Volume units compare regardless of case`() {
        #expect(convert(5, from: "mL", to: "ml") == 5)
        #expect(convert(5, from: "cc", to: "mL") == 5)
        #expect(DoseQuantity(5, unit: "ml").family == DoseQuantity(2, unit: "mL").family)
    }

    @Test
    func `Quantities of different families neither divide nor add`() {
        let grams = DoseQuantity(2, unit: "g")
        let millilitres = DoseQuantity(5, unit: "mL")
        let units = DoseQuantity(5, unit: "IU")
        #expect(grams.ratio(to: millilitres) == nil)
        #expect(grams.adding(units) == nil)
        #expect(millilitres.adding(units) == nil)
        #expect(units.adding(DoseQuantity(3, unit: "iu"))?.value == 8)
    }

    @Test
    func `Mixed mass units sum in the first one's unit`() {
        let total = DoseQuantity(500, unit: "mg").adding(DoseQuantity(1, unit: "g"))
        #expect(total?.value == 1_500)
        #expect(total?.unitSymbol == "mg")
    }

    // MARK: - Aliases

    @Test
    func `An alias is a mass unit of its own`() {
        let drink = UnitAlias(label: "drink", amountPerUnit: 14, unit: "g")
        let twoDrinks = DoseQuantity(2, unit: "drink", aliases: [drink])
        #expect(twoDrinks.value(in: "g") == 28)
        #expect(twoDrinks.milligrams == 28_000)
        #expect(twoDrinks.unitSymbol == "drink")
        #expect(DoseQuantity(28, unit: "g").value(inUnitOf: twoDrinks) == 2)
    }

    @Test
    func `An alias denominated in a non-mass stays a count`() {
        let vial = UnitAlias(label: "vial", amountPerUnit: 2, unit: "mL")
        #expect(DoseQuantity(1, unit: "vial", aliases: [vial]).family == .count("vial"))
    }

    @Test
    func `Tabs with a strength convert exactly`() {
        #expect(InventoryMath.convert(72, from: "mg", to: "tabs", unitStrengthMG: 36) == 2)
        #expect(InventoryMath.convert(2, from: "tabs", to: "g", unitStrengthMG: 36) == 0.072)
        #expect(InventoryMath.convert(72, from: "mg", to: "tabs") == nil)
        #expect(InventoryMath.convert(3, from: "caps", to: "caps") == 3)
    }
}
