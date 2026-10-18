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
    var amountPerUnit: Double
    var unit: String
    var route: RouteOfAdministration
}
