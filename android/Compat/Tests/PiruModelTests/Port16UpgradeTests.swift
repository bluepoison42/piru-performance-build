import Foundation
import PortableData
import Testing

// Only the launch-cache consumer's value shape is needed by DatabaseActor.swift.
nonisolated enum LaunchCacheInputs {
    struct ColorPair: Sendable {
        let substance: String
        let tint: P3Color
    }
}

@MainActor
@Suite(.serialized)
struct Port16UpgradeTests {
    @Test func oldJournalOpensSavesAndReopensWithSchedulesAndSkips() throws {
        let store = TestStore()
        let seeded = try seedJournal(store)
        let today = Calendar.current.medicationDayLabel(for: .now)
        let past = Calendar.current.date(byAdding: .day, value: -2, to: today)!
        let context = try ModelContext(store.container())
        let med = DailyDoseItem(substance: "legacy-med", amount: 2.5, frequency: .everyOtherDay, startDate: past)
        med.reminderTimesMinutes = [480, 120]
        let skipped = RoutineOccurrence(substance: med.substance, route: .oral, dueDay: past, slotMinutes: 120)
        skipped.state = .skipped
        let logged = RoutineOccurrence(substance: "caffeine0", route: .oral,
            dueDay: Calendar.current.medicationDayLabel(for: origin))
        logged.state = .logged
        logged.satisfyingEntryID = seeded.doses[0]
        context.insert(med)
        context.insert(skipped)
        context.insert(logged)
        try context.save()

        // These are the only persisted model additions since 70011; the encoder,
        // table migrations, relationships and every remaining model field are unchanged.
        try store.rewrite("DoseEntry", "json_remove(CAST(data AS TEXT), '$.injectionSiteRaw')")
        try store.rewrite("DailyDoseItem", "json_remove(CAST(data AS TEXT), '$.frequencyIntervalDays')")
        let upgraded = try store.container()
        let opened = ModelContext(upgraded)
        let restored = try #require(try opened.fetch(FetchDescriptor<DailyDoseItem>()).first)
        #expect(restored.amount == 2.5 && restored.frequency == .everyOtherDay)
        #expect(restored.startDate == past && restored.reminderTimesMinutes == [480, 120])
        #expect(restored.frequencyIntervalDays == 3)
        #expect(try opened.doses().map(\.id) == seeded.doses)
        #expect(try opened.doses().allSatisfy { $0.injectionSite == nil && $0.session?.id == seeded.session })
        #expect(try opened.sessions().first?.notes?.first?.text == "calm")
        #expect(try opened.fetchCount(FetchDescriptor<NotificationPreferences>()) == 1)
        #expect(try opened.fetchCount(FetchDescriptor<ToleranceState>()) == 1)
        try RoutineOccurrenceService.repairHistoricalDays(in: opened)
        restored.amount = 3.5
        try opened.save()

        let reopened = try ModelContext(store.container())
        let rows = try reopened.fetch(FetchDescriptor<RoutineOccurrence>())
        #expect(rows.first { $0.persistentModelID == skipped.persistentModelID }?.state == .skipped)
        #expect(rows.first { $0.persistentModelID == logged.persistentModelID }?.satisfyingEntryID == seeded.doses[0])
        #expect(rows.first { $0.persistentModelID == logged.persistentModelID }?.state == .logged)
        #expect(try reopened.doses().map(\.id) == seeded.doses)
        #expect(try reopened.doses().first?.amount == 100)
        #expect(try reopened.doses().first?.timestamp == origin)
        #expect(try reopened.fetch(FetchDescriptor<DailyDoseItem>()).first?.amount == 3.5)
        #expect(upgraded.loadFailures.isEmpty)
    }

    @Test func intervalProductAtTwoAMReconcilesAndKeepsItsHistoricalCredit() throws {
        let defaults = try #require(UserDefaults.androidAppGroup)
        let oldBoundary = defaults.object(forKey: Calendar.dayBoundaryHourKey)
        let oldProducts = defaults.object(forKey: MedSchedule.productMedMapKey)
        defer {
            defaults.set(oldBoundary, forKey: Calendar.dayBoundaryHourKey)
            defaults.set(oldProducts, forKey: MedSchedule.productMedMapKey)
        }
        defaults.set(4, forKey: Calendar.dayBoundaryHourKey)
        let product = MedSchedule.ProductMed(name: "Test liquid", lead: "component-a")
        defaults.set(MedSchedule.encodeProductMeds(["test liquid": product]), forKey: MedSchedule.productMedMapKey)
        let calendar = Calendar.current
        let day = calendar.medicationDayLabel(for: .now)
        let when = calendar.medicationDayMoment(minutes: 120, onLabel: day)!
        let store = TestStore()
        let context = try ModelContext(store.container())
        let med = DailyDoseItem(substance: product.name, amount: 0.5, unit: "mL", frequency: .everyNDays,
            frequencyIntervalDays: 5, startDate: day, reminderTimesMinutes: [120, 1380])
        let lead = DoseEntry(substance: product.lead, amount: 12, timestamp: when,
            volumeML: 0.5, abv: 24, combinationName: product.name)
        context.insert(med)
        context.insert(lead)
        context.insert(DoseEntry(substance: "component-b", amount: 1, timestamp: when, combinationName: product.name))
        try context.save()
        RoutineOccurrenceService.reconcile(in: context, now: when)
        let rows = try context.fetch(FetchDescriptor<RoutineOccurrence>())
        #expect(rows.first { $0.slotMinutes == 120 }?.satisfyingEntryID == lead.id)
        #expect(rows.first { $0.slotMinutes == 1380 }?.state == .pending)
        let key = RoutineOccurrenceService.slotKey(substance: product.name, substanceUID: nil, route: .oral, slotMinutes: 1380)
        #expect(RoutineOccurrenceService.skipToday(slotKeys: [key], in: context, now: when))
        let skips = AdherenceCalculator.skippedSnapshots(try context.fetch(FetchDescriptor<RoutineOccurrence>()))
        let status = AdherenceCalculator.adherence(for: day, entries: try context.doses(), dailyItems: [med], skipped: skips)
        #expect(status.status == .complete && status.takenCount == 1 && status.totalCount == 1)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        #expect(!AdherenceCalculator.isDue(med, on: tomorrow))
        try RoutineOccurrenceService.repairHistoricalDays(in: context, now: calendar.date(byAdding: .day, value: 2, to: when)!)
        try context.save()
        let saved = try ModelContext(store.container()).fetch(FetchDescriptor<RoutineOccurrence>())
        #expect(saved.first { $0.slotMinutes == 120 }?.state == .logged)
        #expect(saved.first { $0.slotMinutes == 1380 }?.state == .skipped)
    }
}
