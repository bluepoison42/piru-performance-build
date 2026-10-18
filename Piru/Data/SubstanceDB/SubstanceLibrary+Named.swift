import Foundation

/// A substance resolved from the name a person or an automation typed, with
/// the facets that name carried: "Concerta" is Methylphenidate *as that
/// product*, "Estradiol Valerate" is Estradiol *in that ester*.
///
/// The one rule for what a typed name becomes on a staged dose, shared by the
/// quick-log prefill (`piru://quicklog?substance=`) and the Shortcuts actions,
/// and the same split the search row makes: an ester alias rides on
/// `saltForm` (a form facet), any other alias on `productName` (the brand or
/// synonym the person named).
struct NamedSubstance {
    let substance: Substance
    /// The alias the name matched when it is not the canonical name, in the
    /// catalog's casing ("Concerta"). `nil` when the canonical name was typed,
    /// or when the alias names an ester instead.
    let productName: String?
    /// The ester the name itself names ("Valerate"), or `nil`.
    let saltForm: String?

    /// The injection route a named ester stages on — its declared `ester_pk`
    /// route (IM/SC), since logging a depot ester by mouth is meaningless.
    /// `nil` when the name named no ester or the ester declares no route.
    var esterRoute: RouteOfAdministration? {
        guard let saltForm, let uid = substance.substanceUID else { return nil }
        let route = SubstanceStore.shared.esters(forParentUID: uid)
            .first { $0.label == saltForm }?.routes.first
        switch route {
        case "SC": return .subcutaneous
        case "IM": return .intramuscular
        default: return nil
        }
    }
}

extension SubstanceLibrary {
    /// Resolve a typed name — canonical, alias, brand, or a custom substance's
    /// own name or label — keeping what the name said about the dose. `nil`
    /// when the catalog and the user's custom substances know no such name.
    ///
    /// Strict, where search is forgiving: the name must resolve through
    /// ``lookup(_:)``, so a misspelling stages nothing rather than the closest
    /// fuzzy hit. The ranked search is consulted only to recover the alias's
    /// display casing, the way the search row shows it.
    static func resolveNamed(_ name: String) async -> NamedSubstance? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let substance = lookup(name) else { return nil }
        if substance.name.caseInsensitiveCompare(name) == .orderedSame
            || substance.displayName?.caseInsensitiveCompare(name) == .orderedSame {
            return NamedSubstance(substance: substance, productName: nil, saltForm: nil)
        }
        let alias = await searchMatchesAsync(name, limit: 5)
            .first { $0.substance.name == substance.name }?
            .matchedAlias
        if let alias, let ester = saltForm(for: alias) {
            return NamedSubstance(substance: substance, productName: nil, saltForm: ester)
        }
        return NamedSubstance(substance: substance, productName: alias, saltForm: nil)
    }
}
