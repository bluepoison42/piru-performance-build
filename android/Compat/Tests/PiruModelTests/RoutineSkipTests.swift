import Foundation
import GRDB
import PortableData
import Testing

@MainActor
@Suite(.serialized)
struct RoutineSkipTests {
    private func med(_ name: String = "scheduled", times: [Int] = [480, 1380]) -> DailyDoseItem {
        let item = DailyDoseItem(substance: name, amount: 1, unit: "mg", route: .oral)
        item.startDate = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        item.reminderTimesMinutes = times
        return item
    }

    private func key(_ item: DailyDoseItem, _ time: Int?) -> String {
        RoutineOccurrenceService.slotKey(substance: item.substance, substanceUID: item.substanceUID,
            route: item.route, slotMinutes: time)
    }

    private func snapshots(_ item: DailyDoseItem) -> [AdherenceCalculator.DailyItemSnapshot] {
        [AdherenceCalculator.DailyItemSnapshot(substance: item.substance, identityKey: item.identityKey,
            route: item.route, expectedPerDay: max(1, item.reminderTimesMinutes.count),
            substanceUID: item.substanceUID, reminderTimesMinutes: item.reminderTimesMinutes,
            isAsNeeded: item.isAsNeeded, startDate: item.startDate, frequency: item.frequency,
            frequencyDays: item.frequencyDays)]
    }

    @Test func skipUnskipRoundTripPersistsAndRefreshesBothDirections() throws {
        let store = TestStore()
        let container = try store.container()
        let context = ModelContext(container)
        let item = med()
        context.insert(item)
        try context.save()
        let target = key(item, 1380)
        let revision = DoseLogService.shared.revision
        let syncs = DoseNotificationManager.reminderSyncs
        let widgets = WidgetCenter.shared.reloads
        #expect(RoutineOccurrenceService.skipToday(slotKeys: [target], in: context))
        let reopened = ModelContext(container)
        let rows = try reopened.fetch(FetchDescriptor<RoutineOccurrence>())
        #expect(rows.first { $0.slotMinutes == 1380 }?.state == .skipped)
        #expect(rows.first { $0.slotMinutes == 480 }?.state == .pending)
        #expect(RoutineOccurrenceService.satisfiedSlotKeys(in: reopened) == [target])
        #expect(DoseLogService.shared.revision == revision + 1)
        #expect(DoseNotificationManager.reminderSyncs == syncs + 1)
        #expect(WidgetCenter.shared.reloads == widgets + 1)
        #expect(!RoutineOccurrenceService.skipToday(slotKeys: [target], in: reopened))
        #expect(RoutineOccurrenceService.unskipToday(slotKeys: [target], in: reopened))
        #expect(!RoutineOccurrenceService.unskipToday(slotKeys: [target], in: reopened))
        let restored = try ModelContext(container).fetch(FetchDescriptor<RoutineOccurrence>())
        #expect(restored.allSatisfy { $0.state == .pending && $0.satisfyingEntryID == nil })
        #expect(RoutineOccurrenceService.satisfiedSlotKeys(in: reopened).isEmpty)
        #expect(DoseLogService.shared.revision == revision + 2)
        #expect(DoseNotificationManager.reminderSyncs == syncs + 2)
        #expect(WidgetCenter.shared.reloads == widgets + 2)
        #expect(try reopened.fetchCount(FetchDescriptor<DoseEntry>()) == 0)
    }

    @Test func sourceMappingKeepsUIDRouteGroupAnytimeAndPRN() {
        let item = med()
        item.substanceUID = "custom-uid"
        let snapshot = DailyMedSnapshot(item)
        #expect(snapshot.routineSlotKeys(in: .night) == [key(item, 1380)])
        #expect(snapshot.routineSlotKeys(in: .morning) == [key(item, 480)])
        #expect(snapshot.routineSlotKeys(in: .afternoon).isEmpty)
        item.reminderTimesMinutes = []
        #expect(DailyMedSnapshot(item).routineSlotKeys(in: .anytime) == [key(item, nil)])
        #expect(DailyMedSnapshot(item).routineSlotKeys(in: .night).isEmpty)
        item.substanceUID = nil
        #expect(DailyMedSnapshot(item).routineSlotKeys(in: nil) == [key(item, nil)])
        item.isAsNeeded = true
        #expect(DailyMedSnapshot(item).routineSlotKeys(in: nil).isEmpty)
    }

    @Test func noSourceWrongDayWrongRouteAndSettledSlotsHaveNoTrayAction() {
        let now = Date.now
        let day = Calendar.current.medicationDayLabel(for: now)
        let row = RoutineOccurrence(substance: "scheduled", route: .oral, dueDay: day, slotMinutes: 480)
        let target = RoutineOccurrenceService.slotKey(for: row)
        #expect(RoutineOccurrenceService.pendingTraySlotKey(slotKeys: [], stagedDay: day, occurrences: [row]) == nil)
        #expect(RoutineOccurrenceService.pendingTraySlotKey(slotKeys: [target], stagedDay: nil, occurrences: [row]) == nil)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        #expect(RoutineOccurrenceService.pendingTraySlotKey(slotKeys: [target], stagedDay: yesterday, occurrences: [row]) == nil)
        let otherRoute = RoutineOccurrenceService.slotKey(substance: row.substance, substanceUID: nil, route: .sublingual, slotMinutes: 480)
        #expect(RoutineOccurrenceService.pendingTraySlotKey(slotKeys: [otherRoute], stagedDay: day, occurrences: [row]) == nil)
        row.state = .skipped
        #expect(RoutineOccurrenceService.pendingTraySlotKey(slotKeys: [target], stagedDay: day, occurrences: [row]) == nil)
        row.state = .logged
        #expect(RoutineOccurrenceService.pendingTraySlotKey(slotKeys: [target], stagedDay: day, occurrences: [row]) == nil)
    }

    @Test func nearestPendingSlotUsesTheMedicationDayAcrossMidnight() {
        let defaults = UserDefaults.androidAppGroup!
        let original = defaults.object(forKey: Calendar.dayBoundaryHourKey)
        defer {
            if let original { defaults.set(original, forKey: Calendar.dayBoundaryHourKey) }
            else { defaults.removeObject(forKey: Calendar.dayBoundaryHourKey) }
        }
        defaults.set(4, forKey: Calendar.dayBoundaryHourKey)
        let calendar = Calendar.current
        let day = calendar.medicationDayLabel(for: .now)
        let now = calendar.medicationDayMoment(minutes: 60, onLabel: day)!
        let evening = RoutineOccurrence(substance: "scheduled", route: .oral, dueDay: day, slotMinutes: 1380)
        let overnight = RoutineOccurrence(substance: "scheduled", route: .oral, dueDay: day, slotMinutes: 120)
        let keys = Set([evening, overnight].map { RoutineOccurrenceService.slotKey(for: $0) })
        #expect(RoutineOccurrenceService.pendingTraySlotKey(slotKeys: keys, stagedDay: day,
            occurrences: [evening, overnight], now: now) == RoutineOccurrenceService.slotKey(for: overnight))
        overnight.state = .skipped
        #expect(RoutineOccurrenceService.pendingTraySlotKey(slotKeys: keys, stagedDay: day,
            occurrences: [evening, overnight], now: now) == RoutineOccurrenceService.slotKey(for: evening))
    }

    @Test func skippedStaysNonMissedAfterRolloverAndHistoricalRepair() throws {
        let store = TestStore()
        let container = try store.container()
        let context = ModelContext(container)
        let item = med()
        context.insert(item)
        try context.save()
        let today = Calendar.current.medicationDayLabel(for: .now)
        #expect(RoutineOccurrenceService.skipToday(slotKeys: [key(item, 1380)], in: context))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let next = Calendar.current.medicationDayMoment(minutes: 720, onLabel: tomorrow)!
        RoutineOccurrenceService.reconcile(in: context, now: next)
        _ = try RoutineOccurrenceService.repairHistoricalDays(in: context, now: next)
        try context.save()
        let rows = try ModelContext(container).fetch(FetchDescriptor<RoutineOccurrence>())
        let past = rows.filter { $0.dueDay == today }
        #expect(past.first { $0.slotMinutes == 1380 }?.state == .skipped)
        #expect(past.first { $0.slotMinutes == 480 }?.state == .missed)
        #expect(rows.filter { $0.dueDay == tomorrow }.allSatisfy { $0.state == .pending })
        #expect(!RoutineOccurrenceService.unskipToday(slotKeys: [key(item, 1380)], in: context, now: next))
    }

    @Test func calendarAndStreakExcludeSkipsAndUndoRestoresExpectation() throws {
        let store = TestStore()
        let context = try ModelContext(store.container())
        let item = med(times: [])
        context.insert(item)
        try context.save()
        let day = Calendar.current.medicationDayLabel(for: .now)
        #expect(RoutineOccurrenceService.skipToday(slotKeys: [key(item, nil)], in: context))
        let skipped = AdherenceCalculator.skippedSnapshots(try context.fetch(FetchDescriptor<RoutineOccurrence>()))
        let summary = AdherenceCalculator.adherence(for: day, entries: [], dailyItems: [item], skipped: skipped)
        #expect(summary.status == .noData && summary.totalCount == 0 && summary.takenCount == 0)
        #expect(AdherenceCalculator.dayStatus(for: day, entries: [], items: snapshots(item), skipped: skipped) == .noData)
        #expect(RoutineOccurrenceService.unskipToday(slotKeys: [key(item, nil)], in: context))
        let undone = AdherenceCalculator.skippedSnapshots(try context.fetch(FetchDescriptor<RoutineOccurrence>()))
        #expect(undone.isEmpty)
        #expect(AdherenceCalculator.adherence(for: day, entries: [], dailyItems: [item], skipped: undone).status == .missed)
        #expect(AdherenceCalculator.dayStatus(for: day, entries: [], items: snapshots(item), skipped: undone) == .missed)
    }

    @Test func mixedLoggedAndSkippedCountsOnlyRealDosesAndPendingStillMisses() throws {
        let store = TestStore()
        let context = try ModelContext(store.container())
        let item = med()
        context.insert(item)
        let day = Calendar.current.medicationDayLabel(for: .now)
        let dose = DoseEntry(substance: item.substance, amount: 1, unit: "mg", route: .oral,
            timestamp: Calendar.current.medicationDayMoment(minutes: 480, onLabel: day)!)
        context.insert(dose)
        try context.save()
        #expect(RoutineOccurrenceService.skipToday(slotKeys: [key(item, 1380)], in: context))
        let skipped = AdherenceCalculator.skippedSnapshots(try context.fetch(FetchDescriptor<RoutineOccurrence>()))
        let result = AdherenceCalculator.adherence(for: day, entries: [dose], dailyItems: [item], skipped: skipped)
        #expect(result.status == .complete && result.takenCount == 1 && result.totalCount == 1)
        #expect(AdherenceCalculator.adherence(for: day, entries: [], dailyItems: [item], skipped: skipped).status == .missed)
        let entries = [AdherenceCalculator.EntrySnapshot(substance: dose.substance, identityKey: dose.identityKey,
            route: dose.route, timestamp: dose.timestamp)]
        #expect(AdherenceCalculator.dayStatus(for: day, entries: entries, items: snapshots(item), skipped: skipped) == .complete)
        #expect(AdherenceCalculator.dayStatus(for: day, entries: [], items: snapshots(item), skipped: skipped) == .missed)
    }

    @Test func repeatedAndLoggedActionsAreNoOpsAndKeepDoseLinks() throws {
        let store = TestStore()
        let context = try ModelContext(store.container())
        let item = med(times: [])
        context.insert(item)
        let dose = DoseEntry(substance: item.substance, amount: 1, unit: "mg", route: .oral, timestamp: .now)
        context.insert(dose)
        try context.save()
        RoutineOccurrenceService.reconcile(in: context)
        let revision = DoseLogService.shared.revision
        let syncs = DoseNotificationManager.reminderSyncs
        let reloads = WidgetCenter.shared.reloads
        #expect(!RoutineOccurrenceService.skipToday(slotKeys: [key(item, nil)], in: context))
        #expect(!RoutineOccurrenceService.unskipToday(slotKeys: [key(item, nil)], in: context))
        let row = try #require(try context.fetch(FetchDescriptor<RoutineOccurrence>()).first)
        #expect(row.state == .logged && row.satisfyingEntryID == dose.id)
        #expect(DoseLogService.shared.revision == revision)
        #expect(DoseNotificationManager.reminderSyncs == syncs && WidgetCenter.shared.reloads == reloads)
    }

    @Test func skippedDayDoesNotBreakTheProductionStreakWalk() {
        let calendar = Calendar.current
        let today = calendar.medicationDayLabel(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let first = calendar.date(byAdding: .day, value: -2, to: today)!
        let item = med(times: [])
        item.startDate = first
        let entries = [first, today].map {
            AdherenceCalculator.EntrySnapshot(substance: item.substance, identityKey: item.identityKey,
                route: item.route, timestamp: calendar.medicationDayMoment(minutes: 720, onLabel: $0)!)
        }
        let skipped = [AdherenceCalculator.SkippedSlotSnapshot(substance: item.substance,
            substanceUID: nil, route: item.route, dueDay: yesterday, slotMinutes: nil)]
        #expect(AdherenceCalculator.currentStreak(spanningDays: 2, endingAt: .now,
            entries: entries, items: snapshots(item), skipped: skipped) == 2)
        #expect(AdherenceCalculator.currentStreak(spanningDays: 2, endingAt: .now,
            entries: entries, items: snapshots(item)) == 1)
    }

    @Test func skippedCountsRespectDayRouteAndSlotWithoutDoubleCounting() {
        let calendar = Calendar.current
        let day = calendar.medicationDayLabel(for: .now)
        let item = med(times: [480, 600, 1380])
        let skip = AdherenceCalculator.SkippedSlotSnapshot(substance: item.substance,
            substanceUID: nil, route: .oral, dueDay: day, slotMinutes: 480)
        let wrongRoute = AdherenceCalculator.SkippedSlotSnapshot(substance: item.substance,
            substanceUID: nil, route: .sublingual, dueDay: day, slotMinutes: 600)
        let wrongDay = AdherenceCalculator.SkippedSlotSnapshot(substance: item.substance,
            substanceUID: nil, route: .oral, dueDay: calendar.date(byAdding: .day, value: -1, to: day)!, slotMinutes: 1380)
        let skipped = [skip, skip, wrongRoute, wrongDay]
        let entries = [600, 1380].map {
            DoseEntry(substance: item.substance, amount: 1, unit: "mg", route: .oral,
                timestamp: calendar.medicationDayMoment(minutes: $0, onLabel: day)!)
        }
        let result = AdherenceCalculator.adherence(for: day, entries: entries, dailyItems: [item], skipped: skipped)
        #expect(result.status == .complete && result.takenCount == 2 && result.totalCount == 2)
        #expect(result.halves?.morningTotal == 1 && result.halves?.eveningTotal == 1)
    }
}
