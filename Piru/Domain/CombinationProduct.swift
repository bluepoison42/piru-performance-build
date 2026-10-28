import Foundation

/// What one unit of a solid combination product is called. Saved as the raw
/// value on ``CustomSubstanceEntry/unit``, so "per pill" reads in every row
/// that lists a product's components; a count of them reads through
/// ``quantityLabel(_:)``.
enum ProductUnitWord: String, CaseIterable, Identifiable {
    case pill
    case tablet
    case capsule

    var id: String {
        rawValue
    }

    /// The word a new solid product is saved under.
    static let standard: ProductUnitWord = .pill

    /// The known word `text` names, singular or plural, in any case: a product
    /// saved as "Tablets" reads as `.tablet`. `nil` for a word typed freely
    /// into an older product ("dose", "sachet").
    init?(word text: String) {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        let singular = lowered.hasSuffix("s") ? String(lowered.dropLast()) : lowered
        guard let match = Self(rawValue: singular) else { return nil }
        self = match
    }

    /// The word on its own, for the form's picker.
    var pickerLabel: LocalizedStringResource {
        switch self {
        case .pill: "Pills"
        case .tablet: "Tablets"
        case .capsule: "Capsules"
        }
    }

    /// "1 pill", "2 pills".
    func quantityLabel(_ count: Int) -> String {
        switch self {
        case .pill: count == 1 ? String(localized: "\(count) pill") : String(localized: "\(count) pills")
        case .tablet: count == 1 ? String(localized: "\(count) tablet") : String(localized: "\(count) tablets")
        case .capsule: count == 1 ? String(localized: "\(count) capsule") : String(localized: "\(count) capsules")
        }
    }
}

extension CustomSubstanceEntry {
    /// `amount` of this product as the user counts it: "2 pills" for a solid,
    /// "0.5 mL" for a liquid. A word typed freely into an older product is
    /// shown as it was typed ("2 dose").
    func quantityLabel(_ amount: Double) -> String {
        Self.quantityLabel(amount, unitWord: unit, isLiquid: isLiquidCombination)
    }

    /// ``quantityLabel(_:)`` for a product not saved yet: its unit word and
    /// whether it is a liquid.
    static func quantityLabel(_ amount: Double, unitWord: String, isLiquid: Bool) -> String {
        if isLiquid {
            return "\(amount.doseFormatted) \(CombinationComponent.volumeUnitWord)"
        }
        let count = CombinationComponent.units(for: amount)
        if let word = ProductUnitWord(word: unitWord) {
            return word.quantityLabel(count)
        }
        return "\(count) \(unitWord)"
    }

    /// The amounts a product's quick-log card offers as chips: one and two
    /// units of a solid, half and one millilitre of a liquid.
    var quantityChips: [Double] {
        isLiquidCombination ? [0.5, 1] : [1, 2]
    }
}

extension DailyDoseItem {
    /// One dose of this med as the user counts it: "2 pills" or "5 mL" for a
    /// med saved as a combination product, "20 mg" for anything else.
    @MainActor var doseLabel: String {
        if let product = CustomSubstanceStore.shared.combination(named: substance) {
            return product.quantityLabel(amount)
        }
        return "\(amount.doseFormatted) \(unit)"
    }
}
