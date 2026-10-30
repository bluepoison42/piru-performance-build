import Foundation
import PortableData

nonisolated enum AppIdentity { static let appGroup = "piru.ci.medication-tests" }
// StageSources rewrites the App Group suite to this Android accessor (Foundation+Android.swift).
extension UserDefaults {
    nonisolated static var androidAppGroup: UserDefaults? { UserDefaults(suiteName: AppIdentity.appGroup) }
}
// Only OS/UI side effects are doubles. Reconcile, history matching, commit order and
// calendar logic above are the production members over the actual PortableData models.
@MainActor final class DoseLogService {
    static let shared = DoseLogService()
    var revision = 0
    func changed() { revision += 1 }
}
@MainActor final class WidgetCenter {
    static let shared = WidgetCenter()
    var reloads = 0
    func reloadAllTimelines() { reloads += 1 }
}
@MainActor enum DataExportImport {
static func commitImport(context: ModelContext) throws {
        try RoutineOccurrenceService.repairHistoricalDays(in: context)
        try context.save()
        DoseLogService.shared.changed()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
@MainActor enum DoseNotificationManager {
    static var reminderSyncs = 0
    private static func scheduleMedReminders(in context: ModelContext) { reminderSyncs += 1 }
static func medicationDayBoundaryChanged(in context: ModelContext) throws {
        UserDefaults.standard.removeObject(forKey: "piru.medicationHistoryBoundary.v2")
        try RoutineOccurrenceService.repairHistoricalDays(in: context)
        try context.save()
        DoseLogService.shared.changed()
        syncMedReminders(in: context)
        UserDefaults.standard.set(Calendar.sessionDayBoundaryHour, forKey: "piru.medicationHistoryBoundary.v2")
    }
static func syncMedReminders(in context: ModelContext) {
        RoutineOccurrenceService.reconcile(in: context)
        scheduleMedReminders(in: context)
    }
}
struct MedicationCardFixture {
    var recentOccurrences: [RoutineOccurrence]
var todayOccurrences: [RoutineOccurrence] {
        let today = Calendar.current.medicationDayLabel(for: .now)
        return recentOccurrences.filter { $0.dueDay == today }
    }
}
struct MedicationStreakKey: Equatable {
        let revision: Int
        let schedule: Int
        let day: Date
        let boundary: Int
    }
struct InsightsBucketsFixture {
    let calendar = Calendar.current
    func group(_ entries: [DoseEntry]) -> (usage: [Date: [DoseEntry]], adherence: [Date: [DoseEntry]]) {
        let cal = calendar
        var entriesByDay: [Date: [DoseEntry]] = [:]
        var adherenceEntriesByDay: [Date: [DoseEntry]] = [:]
        for entry in entries {
            entriesByDay[cal.startOfDay(for: entry.timestamp), default: []].append(entry)
            adherenceEntriesByDay[cal.medicationDayLabel(for: entry.timestamp), default: []].append(entry)
        }


        return (entriesByDay, adherenceEntriesByDay)
    }
}
struct DueSlotFixture {
    enum State { case pending, taken, skipped }
    let state: State
    let time: Int?
    // Controlled clock input to the unmodified production comparison.
    static var nowMinutes = 0
var isDueNow: Bool {
            guard state == .pending else { return false }
            guard let time else { return true }
            return Calendar.medicationClockMinutes(time) <= Calendar.medicationClockMinutes(Self.nowMinutes)
        }
}
