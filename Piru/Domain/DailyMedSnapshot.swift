import Foundation

/// The fields of one `DailyDoseItem` that a med surface renders, stages or
/// matches on, copied out of the model when that surface derives its state.
///
/// The quick-log My Meds pills cache their groups past any single `@Query`
/// result, and the Journal's My Meds card holds tapped slots across its
/// interaction-warning sheet. Neither may hold the `@Model` itself: a med
/// deleted meanwhile (Manage Meds, a restore, a store reset) traps in
/// SwiftData's `getValue` the next time one of its properties is read. A
/// surface that has to act on the live model (log a dose of it) re-resolves
/// it from its own `@Query` at that moment.
struct DailyMedSnapshot: Equatable {
    let substance: String
    let productName: String?
    let route: RouteOfAdministration
    let amount: Double
    let unit: String
    let isBackgroundMed: Bool
    let isQuiet: Bool
    let sortOrder: Int
    /// ``DailyDoseItem/identityKey`` at the time of the copy.
    let identityKey: String
    let substanceUID: String?
    let reminderTimesMinutes: [Int]
    let isAsNeeded: Bool

    init(_ item: DailyDoseItem) {
        substance = item.substance
        productName = item.productName
        route = item.route
        amount = item.amount
        unit = item.unit
        isBackgroundMed = item.isBackgroundMed
        isQuiet = item.isQuiet
        sortOrder = item.sortOrder
        identityKey = item.identityKey
        substanceUID = item.substanceUID
        reminderTimesMinutes = item.reminderTimesMinutes
        isAsNeeded = item.isAsNeeded
    }

    /// Preserve schedule identity, including custom meds without a library UID.
    func routineSlotKeys(in group: MedTimeGroup?) -> Set<String> {
        guard !isAsNeeded else { return [] }
        let slots: [Int?] = reminderTimesMinutes.isEmpty ? [nil] : reminderTimesMinutes.map { Optional($0) }
        return Set(slots.filter { time in
            guard let group else { return true }
            return time.map { MedTimeGroup.group(forMinutes: $0) == group } ?? (group == .anytime)
        }.map { time in
            RoutineOccurrenceService.slotKey(substance: substance, substanceUID: substanceUID,
                route: route, slotMinutes: time)
        })
    }

    /// The name a med row, pill or the dock label titles this med by.
    var displayName: String {
        productName ?? CustomSubstanceStore.shared.displayName(for: substance)
    }
}
