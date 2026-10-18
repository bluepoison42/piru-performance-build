import AppIntents
import Foundation
import SwiftData
#if canImport(UIKit)
    import UIKit
#endif

/// A substance as a Shortcuts parameter: a catalog substance, named either
/// canonically or by a brand or synonym, or one of the user's custom
/// substances.
///
/// The name the person chose travels with the entity (`alias`) because it is
/// what the dose records: picking "Concerta" logs Methylphenidate *as
/// Concerta*, exactly as typing it into the quick-log search does.
nonisolated struct SubstanceEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Substance"
    static let defaultQuery = SubstanceEntityQuery()

    /// Stable across runs, since Shortcuts stores the identifier and resolves
    /// it again each time: `<canonical name>` for a catalog substance named
    /// canonically, `<canonical name>|<alias>` when named by a brand or synonym
    /// (the alias is what the dose records as its product, so it has to
    /// survive the round trip), `custom:<uuid>` for a custom substance.
    let id: String
    /// The canonical name — the lookup key every resolve depends on.
    let name: String
    /// The brand, synonym or ester name the person named it by, or `nil` when
    /// they named the canonical substance.
    let alias: String?
    let title: String
    let subtitle: String?

    /// The name to resolve a dose by: the alias when there is one, so the
    /// resolver recovers the product or ester it names.
    var typedName: String {
        alias ?? name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" })
    }

    private static let customPrefix = "custom:"
    private static let aliasSeparator: Character = "|"

    // MARK: - Construction

    /// A search hit, titled the way the search row titles it.
    @MainActor
    static func catalog(from match: SubstanceMatch) -> SubstanceEntity {
        let alias = match.matchedAlias
        return SubstanceEntity(
            id: alias.map { "\(match.substance.name)\(aliasSeparator)\($0)" } ?? match.substance.name,
            name: match.substance.name,
            alias: alias,
            title: match.displayName,
            subtitle: match.secondaryLine(),
        )
    }

    @MainActor
    static func custom(_ entry: CustomSubstanceEntry) -> SubstanceEntity {
        SubstanceEntity(
            id: customPrefix + entry.id.uuidString,
            name: entry.name,
            alias: nil,
            title: entry.displayName ?? entry.name,
            subtitle: entry.displayName == nil ? String(localized: "Custom substance") : entry.name,
        )
    }

    /// A substance a stored record names (a med, a favorite, a recent chip):
    /// its catalog substance under the product the record kept, else the custom
    /// substance of that name. `nil` when neither knows it any more.
    @MainActor
    static func named(_ name: String, productName: String?, customs: [CustomSubstanceEntry]) -> SubstanceEntity? {
        if let entry = customs.first(where: { CustomSubstanceStore.canonicalKey($0.name) == CustomSubstanceStore.canonicalKey(name) }),
           SubstanceStore.shared.lookupByNameOrAlias(name) == nil {
            return custom(entry)
        }
        guard let substance = SubstanceLibrary.lookup(name) else { return nil }
        let alias = productName.flatMap { $0.caseInsensitiveCompare(substance.name) == .orderedSame ? nil : $0 }
        return catalog(from: SubstanceMatch(substance: substance, matchedAlias: alias))
    }

    // MARK: - Resolution

    /// The entity an identifier names, or `nil` when the catalog or the custom
    /// list no longer has it.
    @MainActor
    static func resolve(id: String, customs: [CustomSubstanceEntry]) -> SubstanceEntity? {
        if id.hasPrefix(customPrefix) {
            let uuid = String(id.dropFirst(customPrefix.count))
            return customs.first { $0.id.uuidString == uuid }.map(custom)
        }
        let parts = id.split(separator: aliasSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard let canonical = parts.first.map(String.init), let substance = SubstanceLibrary.lookup(canonical) else { return nil }
        let alias = parts.count == 2 ? String(parts[1]) : nil
        return catalog(from: SubstanceMatch(substance: substance, matchedAlias: alias))
    }

    /// The entities a typed query names: the ranked catalog search (brands
    /// included, each hit under the alias it matched), then the custom
    /// substances whose name or label contains the query and that the catalog
    /// did not already answer with.
    @MainActor
    static func matches(_ query: String, customs: [CustomSubstanceEntry], limit: Int = 10) async -> [SubstanceEntity] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let hits = await SubstanceLibrary.searchMatchesAsync(query, limit: limit)
        var entities = hits.map(catalog(from:))
        let answered = Set(entities.map { CustomSubstanceStore.canonicalKey($0.name) })
        for entry in customs
            where !answered.contains(CustomSubstanceStore.canonicalKey(entry.name))
            && (entry.name.localizedCaseInsensitiveContains(query)
                || entry.displayName?.localizedCaseInsensitiveContains(query) == true) {
            entities.append(custom(entry))
        }
        return Array(entities.prefix(limit))
    }
}

// MARK: - Query

/// Resolves ``SubstanceEntity`` for Shortcuts: by identifier when a saved
/// shortcut runs, by typed text when a person picks one, and by what they log
/// most when the picker opens empty.
nonisolated struct SubstanceEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SubstanceEntity] {
        await SubstanceStore.shared.ensureAllLoaded()
        let customs = CustomSubstanceStore.shared.all
        return identifiers.compactMap { SubstanceEntity.resolve(id: $0, customs: customs) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SubstanceEntity] {
        await SubstanceStore.shared.ensureAllLoaded()
        return await SubstanceEntity.matches(string, customs: CustomSubstanceStore.shared.all)
    }

    /// My Meds and favorites first, then the recent quick-log chips, each
    /// substance once.
    @MainActor
    func suggestedEntities() async throws -> [SubstanceEntity] {
        // Nothing while the device is locked: the medication list is health
        // data and Siri shows suggestions on the lock screen.
        #if canImport(UIKit)
            guard UIApplication.shared.isProtectedDataAvailable else { return [] }
        #endif
        guard let container = DoseIntentLogger.modelContainer else { return [] }
        await SubstanceStore.shared.ensureAllLoaded()
        let context = container.mainContext
        let customs = CustomSubstanceStore.shared.all
        var seen: Set<String> = []
        var entities: [SubstanceEntity] = []
        func add(_ entity: SubstanceEntity?) {
            guard let entity, seen.insert(entity.id).inserted else { return }
            entities.append(entity)
        }

        let meds = (try? context.fetch(FetchDescriptor<DailyDoseItem>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        for med in meds {
            add(SubstanceEntity.named(med.substance, productName: med.productName, customs: customs))
        }
        let favorites = (try? context.fetch(FetchDescriptor<FavoriteSubstance>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt, order: .reverse)],
        ))) ?? []
        for favorite in favorites {
            add(SubstanceEntity.named(favorite.substance, productName: favorite.productName, customs: customs))
        }
        var recents = FetchDescriptor<QuickLogDose>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        recents.fetchLimit = 30
        for chip in (try? context.fetch(recents)) ?? [] {
            add(SubstanceEntity.named(chip.substance, productName: chip.productName, customs: customs))
        }
        return entities
    }
}
