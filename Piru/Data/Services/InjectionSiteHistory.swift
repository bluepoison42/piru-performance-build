import Foundation
import SwiftData

/// The injection-site record a rotation reads: the last site logged for a
/// substance, and the site that follows it.
enum InjectionSiteHistory {
    /// The site of the newest dose of `substance` that recorded one.
    static func lastSite(substance: String, in context: ModelContext) -> InjectionSite? {
        var descriptor = FetchDescriptor<DoseEntry>(
            predicate: #Predicate { $0.substance == substance && $0.injectionSiteRaw != nil },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)],
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.injectionSite
    }

    /// The site to offer for the next `route` dose of `substance`: the other
    /// side of the last area used. `nil` until a site has been logged once,
    /// so nobody who never records sites gets one filled in.
    static func suggestedNext(substance: String, route: RouteOfAdministration, in context: ModelContext) -> InjectionSite? {
        guard InjectionSite.applies(to: route) else { return nil }
        return InjectionSite.suggestedNext(after: lastSite(substance: substance, in: context), route: route)
    }
}
