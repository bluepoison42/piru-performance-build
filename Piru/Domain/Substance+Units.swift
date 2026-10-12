import Foundation

extension Substance {
    /// Colloquial unit aliases for this substance. Keys are the canonical
    /// (lowercased) substance name or any alias; the lookup matches whichever
    /// is canonical at runtime.
    ///
    /// References:
    /// - **drink**: US standard drink = 14 g of pure ethanol per
    ///   [NIAAA](https://www.niaaa.nih.gov/alcohols-effects-health/overview-alcohol-consumption/what-standard-drink).
    private static let unitAliasTable: [String: [UnitAlias]] = [
        "alcohol": [
            UnitAlias(label: "drink", amountPerUnit: 14, unit: "g"),
        ],
        "ethanol": [
            UnitAlias(label: "drink", amountPerUnit: 14, unit: "g"),
        ],
    ]

    /// Unit aliases applicable to this substance — the user's own
    /// (``customUnitAliases``) ahead of the curated conventions, looked up by
    /// canonical name or any alias. Empty for substances with neither.
    var unitAliases: [UnitAlias] {
        let candidates = [name.lowercased()] + aliases.map { $0.lowercased() }
        let curated = candidates.lazy.compactMap { Self.unitAliasTable[$0] }.first ?? []
        return customUnitAliases + curated
    }

    /// By-volume dose-input capability (concentration × measured volume → canonical
    /// mass), looked up by canonical name or alias. Non-nil only for the curated
    /// adopters (alcohol in v1); the dose form renders the by-volume panel when set.
    var byVolumeDosing: ByVolumeDosing? {
        ByVolumeCatalog.capability(forAnyOf: [name] + aliases)
    }

    /// A written amount parsed against this substance's units, its colloquial
    /// aliases included ("2 drinks" of alcohol is 28 g of ethanol).
    func quantity(_ amount: Double, unit: String) -> DoseQuantity {
        DoseQuantity(amount, unit: unit, aliases: unitAliases)
    }

    /// A logged dose's amount parsed against this substance's units, or `nil`
    /// when the amount was not recorded.
    func quantity(of entry: DoseEntry) -> DoseQuantity? {
        entry.isUnknownDose ? nil : quantity(entry.amount, unit: entry.unit)
    }
}
