import Foundation
import SwiftData
import Testing
@testable import Piru

@MainActor
@Suite("Audit follow-up", .serialized)
struct AuditFollowupTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(PiruSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        )
    }

    @Test
    func `Volume editing keeps small amounts and reopening keeps the volume`() {
        let tray = DoseTrayModel()
        tray.stage(substance: "ZZSolution", route: .oral, amount: 1, unit: "g", tint: nil, librarySubstance: nil)
        let editor = StagedDoseEditorModel()
        editor.volumeUnit = .milliliters
        editor.volumeText = "0.25"
        editor.abvText = "1"
        let capability = ByVolumeDosing.solution(in: "g")
        editor.syncCustomDrink(item: &tray.staged[0], capability: capability, byDrinkPreferred: true)
        #expect(tray.staged[0].totalAmount == 0.25)

        let reopened = StagedDoseEditorModel()
        reopened.volumeUnit = .milliliters
        reopened.seedByDrinkFieldsIfNeeded(from: tray.staged[0], capability: capability)
        #expect(reopened.enteredVolumeML == 0.25)
        reopened.volumeText = "0.04"
        reopened.syncCustomDrink(item: &tray.staged[0], capability: capability, byDrinkPreferred: true)
        #expect(tray.staged[0].totalAmount == 0.04)
        #expect(tray.isCommittable)

        reopened.abvText = ""
        reopened.syncCustomDrink(item: &tray.staged[0], capability: capability, byDrinkPreferred: true)
        #expect(!tray.isCommittable)
    }

    @Test
    func `Changing the volume updates alcohol as well as the other component`() async {
        await SubstanceStore.shared.ensureAllLoaded()
        let product = CustomSubstanceEntry(name: "ZZMixed solution", unit: "mL", components: [
            CombinationComponent(substance: "Alcohol", amountPerUnit: 0.1, unit: "g", route: .oral),
            CombinationComponent(substance: "ZZAlpha", amountPerUnit: 1, unit: "mg", route: .oral),
        ])
        let tray = DoseTrayModel()
        tray.stage(combination: product, volumeML: 1)
        tray.setVolume(5, of: product)
        #expect(tray.staged.map(\.totalAmount) == [0.5, 5])
        #expect(tray.stagedQuantity(of: product) == 5)
        #expect(tray.staged[0].abv == nil)
    }

    @Test
    func `Undoing the morning slot keeps the evening and extra doses`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let day = calendar.medicationDayLabel(for: .now)
        let item = DailyDoseItem(substance: "ZZSchedule", amount: 10, unit: "mg", reminderTimesMinutes: [480, 1080])
        item.startDate = .distantPast
        context.insert(item)
        let morning = DoseEntry(substance: item.substance, amount: 10, unit: "mg", timestamp: try #require(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)))
        let evening = DoseEntry(substance: item.substance, amount: 10, unit: "mg", timestamp: try #require(calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day)))
        let extra = DoseEntry(substance: item.substance, amount: 10, unit: "mg", timestamp: try #require(calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)))
        for entry in [morning, evening, extra] { context.insert(entry) }
        try context.save()
        RoutineOccurrenceService.reconcile(in: context)
        let occurrences = try context.fetch(FetchDescriptor<RoutineOccurrence>())
        let slot = try #require(MyMedsModel.slots(items: [item], occurrences: occurrences).first { $0.time == 480 })
        let morningID = morning.id
        let retainedIDs: Set<UUID> = [evening.id, extra.id]
        #expect(slot.satisfyingEntryID == morningID)
        MyMedsModel.unlog(slot, entries: [morning, evening, extra], colors: [], in: context)
        try context.save()
        let stored = try context.fetch(FetchDescriptor<DoseEntry>())
        #expect(Set(stored.map(\.id)) == retainedIDs)
    }

    @Test
    func `Changing one reminder time refreshes a streak containing a skipped day`() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let today = calendar.medicationDayLabel(for: .now)
        let previous = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let item = DailyDoseItem(substance: "ZZStreak", amount: 10, unit: "mg", reminderTimesMinutes: [480])
        item.startDate = previous
        context.insert(item)
        context.insert(DoseEntry(substance: item.substance, amount: 10, unit: "mg", timestamp: previous.addingTimeInterval(12 * 3600)))
        let skipped = RoutineOccurrence(substance: item.substance, route: .oral, dueDay: yesterday, slotMinutes: 480)
        skipped.state = .skipped
        context.insert(skipped)
        try context.save()
        let first = await AdherenceStreakStore.shared.currentStreak(items: [item], container: container)
        #expect(first == 1)
        item.reminderTimesMinutes = [540]
        try context.save()
        let changed = await AdherenceStreakStore.shared.currentStreak(items: [item], container: container)
        #expect(changed == 0)
    }
}
