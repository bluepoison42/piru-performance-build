import Foundation

/// One compound inside a combination product — co-codamol is 500 mg
/// paracetamol and 30 mg codeine per tablet, so it holds two of these.
///
/// Stored as JSON in ``CustomSubstanceRecord/componentsData`` and decoded in
/// the Piru target; the fields are primitive on purpose, since the record
/// compiles into the widget targets too. `substance` is the library's canonical
/// name (or the raw name of a custom substance), never a brand word.
nonisolated struct CombinationComponent: Codable, Hashable, Sendable {
    var substance: String
    /// How much of this compound one unit of the product carries, in `unit`.
    /// For a liquid (``isVolumeUnitWord(_:)``) the unit is one millilitre, so
    /// this is the concentration: 2 g of morphine per mL is `2` with `unit` "g".
    var amountPerUnit: Double
    var unit: String
    var route: RouteOfAdministration
    var productName: String? = nil
    var isomer: String? = nil
    var releaseForm: String? = nil
    var saltForm: String? = nil

    /// The most units one pick of a product can stage.
    static let maximumUnits = 1000

    /// How many units of a product an automation's amount means: at least one,
    /// at most ``maximumUnits``, and one when the number is not finite. The
    /// amount reaches here from a URL or a Shortcut, so it can be anything a
    /// `Double` holds, and `Int(1e300)` traps.
    static func units(for amount: Double?) -> Int {
        guard let amount, amount.isFinite else { return 1 }
        return Int(min(max(amount.rounded(), 1), Double(maximumUnits)))
    }

    // MARK: - Liquids

    /// The unit word a liquid product is saved under: its components are
    /// amounts per millilitre, and it is logged by a volume in mL rather than a
    /// count of units.
    static let volumeUnitWord = "mL"

    /// The largest volume one pick of a liquid product can stage, in mL.
    static let maximumVolumeML = 1000.0

    /// The volume a liquid product stages at when it is picked with none given.
    static let defaultVolumeML = 1.0

    /// Whether a product's unit word names a millilitre, which makes it a
    /// liquid logged by volume. Matched loosely because the word is free text:
    /// a product saved as "ml" reads as a liquid, and its amounts already mean
    /// per mL.
    static func isVolumeUnitWord(_ word: String) -> Bool {
        switch word.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres": true
        default: false
        }
    }

    /// The volume in mL an automation's amount means for a liquid product:
    /// fractional, at most ``maximumVolumeML``, and ``defaultVolumeML`` when the
    /// number is missing, not finite or not positive.
    static func volumeML(for amount: Double?) -> Double {
        guard let amount, amount.isFinite, amount > 0 else { return defaultVolumeML }
        return min(amount, maximumVolumeML)
    }

    /// This component's amount in `volumeML` of the product, in its own
    /// ``unit``: volume × amount per mL, the same arithmetic as a vial drawn by
    /// concentration. 0 for a non-positive or non-finite volume.
    func amount(inVolumeML volumeML: Double) -> Double {
        ByVolumeDosing.mass(volumeML: volumeML, concentrationPerML: amountPerUnit)
    }
}
