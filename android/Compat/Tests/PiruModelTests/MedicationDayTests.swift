import Foundation
import PortableData
import Testing

@MainActor
@Suite(.serialized)
struct MedicationDayTests {
    private func withBoundary(_ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults(suiteName: AppIdentity.appGroup)!
        let key = Calendar.dayBoundaryHourKey
        let original = defaults.object(forKey: key)
        let historyKey = "piru.medicationHistoryBoundary.v2"
        let originalHistory = UserDefaults.standard.object(forKey: historyKey)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            if let originalHistory { UserDefaults.standard.set(originalHistory, forKey: historyKey) }
            else { UserDefaults.standard.removeObject(forKey: historyKey) }
        }
        defaults.set(4, forKey: key)
        try body(defaults)
    }

    @Test func historyRegroupsExistingRowsAndPreservesEveryDose() throws {
        try withBoundary { defaults in
            let calendar = Calendar.current
            let today = calendar.medicationDayLabel(for: .now)
            let first = calendar.date(byAdding: .day, value: -3, to: today)!
            let second = calendar.date(byAdding: .day, value: 1, to: first)!
            let early = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: second)!
            let store = TestStore()
            let context = try ModelContext(store.container())
            let dose = DoseEntry(substance: "test-med", amount: 1.25, unit: "mg", route: .oral, timestamp: early)
            let a = RoutineOccurrence(substance: "test-med", route: .oral, dueDay: first)
            let b = RoutineOccurrence(substance: "test-med", route: .oral, dueDay: second)
            let skipped = RoutineOccurrence(substance: "user-skip", route: .oral, dueDay: first)
            let future = RoutineOccurrence(substance: "test-med", route: .oral,
                dueDay: calendar.date(byAdding: .day, value: 1, to: today)!)
            a.state = .missed; b.state = .missed; skipped.state = .skipped
            context.insert(dose)
            for row in [a, b, skipped, future] { context.insert(row) }
            try context.save()
            let occurrenceIDs = Set(try context.fetch(FetchDescriptor<RoutineOccurrence>()).map(\.persistentModelID))
            #expect(try RoutineOccurrenceService.repairHistoricalDays(in: context) == 1)
            #expect(a.state == .logged && a.satisfyingEntryID == dose.id)
            #expect(b.state == .missed)
            #expect(try RoutineOccurrenceService.repairHistoricalDays(in: context) == 0)
            defaults.set(0, forKey: Calendar.dayBoundaryHourKey)
            #expect(try RoutineOccurrenceService.repairHistoricalDays(in: context) == 2)
            #expect(a.state == .missed && a.satisfyingEntryID == nil)
            #expect(b.state == .logged && b.satisfyingEntryID == dose.id)
            #expect(skipped.state == .skipped && future.state == .pending)
            try context.save()
            #expect(try context.doses().first?.amount == 1.25)
            #expect(try context.doses().first?.timestamp == early)
            #expect(Set(try context.fetch(FetchDescriptor<RoutineOccurrence>()).map(\.persistentModelID)) == occurrenceIDs)
        }
    }

    @Test func commonImportCommitRepairsHistoryWithoutSettings() throws {
        try withBoundary { _ in
            let calendar = Calendar.current
            let today = calendar.medicationDayLabel(for: .now)
            let day = calendar.date(byAdding: .day, value: -2, to: today)!
            let store = TestStore()
            let container = try store.container()
            let context = ModelContext(container)
            let missed = RoutineOccurrence(substance: "imported-med", route: .oral, dueDay: day)
            missed.state = .missed
            context.insert(missed)
            try context.save()
            let dose = DoseEntry(substance: "imported-med", amount: 2, unit: "mg", route: .oral,
                timestamp: calendar.medicationDayMoment(minutes: 120, onLabel: day)!)
            context.insert(dose)
            let revision = DoseLogService.shared.revision
            try DataExportImport.commitImport(context: context)
            #expect(DoseLogService.shared.revision == revision + 1)
            let reopened = ModelContext(container)
            let stored = try #require(try reopened.fetch(FetchDescriptor<RoutineOccurrence>()).first)
            #expect(stored.state == .logged && stored.satisfyingEntryID == dose.id)
            #expect(try reopened.fetchCount(FetchDescriptor<DoseEntry>()) == 1)
            #expect(try RoutineOccurrenceService.repairHistoricalDays(in: context) == 0)
        }
    }

    @Test func boundaryChangeReconcilesTodaySignalsAndReschedulesEvenWithoutHistory() throws {
        try withBoundary { defaults in
            let store = TestStore()
            let context = try ModelContext(store.container())
            let item = DailyDoseItem(substance: "today-med", amount: 1, unit: "mg", route: .oral)
            item.startDate = Calendar.current.date(byAdding: .day, value: -2, to: .now)!
            context.insert(item)
            try context.save()
            let revision = DoseLogService.shared.revision
            let syncs = DoseNotificationManager.reminderSyncs
            defaults.set(0, forKey: Calendar.dayBoundaryHourKey)
            try DoseNotificationManager.medicationDayBoundaryChanged(in: context)
            #expect(DoseLogService.shared.revision == revision + 1)
            #expect(DoseNotificationManager.reminderSyncs == syncs + 1)
            let rows = try context.fetch(FetchDescriptor<RoutineOccurrence>())
            #expect(rows.count == 1)
            #expect(rows.first?.dueDay == Calendar.current.medicationDayLabel(for: .now))
            #expect(try context.fetchCount(FetchDescriptor<DoseEntry>()) == 0)
            let day = Calendar.current.startOfDay(for: .now)
            #expect(MedicationStreakKey(revision: 1, schedule: 1, day: day, boundary: 4)
                != MedicationStreakKey(revision: 1, schedule: 1, day: day, boundary: 0))
        }
    }

    @Test func todayOccurrencesExcludeBothAdjacentDays() throws {
        try withBoundary { _ in
            let calendar = Calendar.current
            let today = calendar.medicationDayLabel(for: .now)
            let yesterday = RoutineOccurrence(substance: "same-med", route: .oral,
                dueDay: calendar.date(byAdding: .day, value: -1, to: today)!)
            let current = RoutineOccurrence(substance: "same-med", route: .oral, dueDay: today)
            current.state = .logged
            let tomorrow = RoutineOccurrence(substance: "same-med", route: .oral,
                dueDay: calendar.date(byAdding: .day, value: 1, to: today)!)
            let rows = MedicationCardFixture(recentOccurrences: [yesterday, current, tomorrow]).todayOccurrences
            #expect(rows.count == 1 && rows.first === current)
        }
    }

    @Test func insightsKeepsNaturalUsageAndMedicationAdherenceBucketsSeparate() throws {
        try withBoundary { _ in
            let calendar = Calendar.current
            let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 21))!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let evening = DoseEntry(substance: "test", amount: 1,
                timestamp: calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)!)
            let overnight = DoseEntry(substance: "test", amount: 1,
                timestamp: calendar.date(bySettingHour: 2, minute: 0, second: 0, of: next)!)
            let buckets = InsightsBucketsFixture().group([evening, overnight])
            #expect(buckets.usage[day]?.count == 1 && buckets.usage[next]?.count == 1)
            #expect(buckets.adherence[day]?.count == 2 && buckets.adherence[next] == nil)
        }
    }

    @Test func myMedsDueOrderWrapsAtBoundaryWithoutChangingDisplayedMinutes() throws {
        try withBoundary { _ in
            let overnight = DueSlotFixture(state: .pending, time: 120)
            let evening = DueSlotFixture(state: .pending, time: 1380)
            DueSlotFixture.nowMinutes = 1380
            #expect(!overnight.isDueNow && evening.isDueNow)
            DueSlotFixture.nowMinutes = 60
            #expect(!overnight.isDueNow && evening.isDueNow)
            DueSlotFixture.nowMinutes = 120
            #expect(overnight.isDueNow)
            #expect(overnight.time == 120 && evening.time == 1380)
            #expect(DueSlotFixture(state: .pending, time: nil).isDueNow)
            #expect(!DueSlotFixture(state: .taken, time: 120).isDueNow)
        }
    }
}
