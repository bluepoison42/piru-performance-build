import Foundation
import SwiftData
import Testing
@testable import Piru

@MainActor
@Suite(.serialized)
struct Port16ImportTests {
    @Test func liquidRoutineSkipsOneSlotAndRemovesItsWholeProduct() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Schema(PiruSchema.models), configurations: config)
        let context = container.mainContext
        let store = CustomSubstanceStore.shared
        store.configure(container: container)
        let product = CustomSubstanceEntry(name: "ZZPort16Liquid", unit: "mL", components: [
            CombinationComponent(substance: "ZZPort16A", amountPerUnit: 24, unit: "mg", route: .oral),
            CombinationComponent(substance: "ZZPort16B", amountPerUnit: 2, unit: "mg", route: .oral),
        ])
        store.add(product)
        defer { store.delete(product) }
        let med = DailyDoseItem(substance: product.name, amount: 0.5, unit: "mL", reminderTimesMinutes: [480, 1380])
        context.insert(med)
        try context.save()
        RoutineOccurrenceService.reconcile(in: context)
        let tray = DoseTrayModel()
        tray.stage(substance: "ZZLone", route: .oral, amount: 1, unit: "mg", tint: nil, librarySubstance: nil)
        tray.stage(dailyItem: med, colorLookup: [:])
        let lead = try #require(tray.staged.first { $0.combinationName == product.name })
        #expect(lead.totalAmount == 12 && lead.volumeML == 0.5)
        let rows = try context.fetch(FetchDescriptor<RoutineOccurrence>())
        let key = try #require(RoutineOccurrenceService.pendingTraySlotKey(
            slotKeys: lead.routineSlotKeys, stagedDay: lead.routineDay, occurrences: rows))
        #expect(tray.skipToday(lead, slotKey: key, in: context))
        #expect(tray.staged.count == 1 && tray.staged.first?.substanceName == "ZZLone")
        #expect(rows.filter { $0.state == .skipped }.count == 1)
        #expect(rows.filter { $0.state == .pending }.count == 1)
        #expect(RoutineOccurrenceService.unskipToday(slotKeys: [key], in: context))
        tray.stage(dailyItem: med, colorLookup: [:])
        tray.stage(product: product, amount: 0.5)
        #expect(tray.staged.filter { $0.combinationName == product.name }.allSatisfy { $0.routineSlotKeys.isEmpty && $0.routineDay == nil })
    }

    @Test func nativeImportKeepsUUIDsSitesAndIntervalSchedules() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Schema(PiruSchema.models), configurations: config)
        let context = container.mainContext
        let store = CustomSubstanceStore.forTesting(context: context)
        let id = UUID(), twin = UUID()
        let row: [String: Any] = ["substance": "port-med", "amount": 10, "unit": "mg", "route": "intramuscular",
            "timestamp": 1_790_000_000_000 as Int64, "tags": [], "isBackgroundMed": false, "injectionSite": "thigh.left"]
        var a = row, b = row
        a["id"] = id.uuidString; b["id"] = twin.uuidString
        let data = try JSONSerialization.data(withJSONObject: ["piruExportVersion": 4, "orphanDoses": [a, b],
            "dailyDoseItems": [["substance": "port-med", "amount": 10, "unit": "mg", "route": "intramuscular",
                "sortOrder": 0, "category": "", "frequencyRaw": "everyNDays", "frequencyDays": [],
                "frequencyIntervalDays": 5, "startDate": 1_790_000_000_000 as Int64, "isBackgroundMed": false]]])
        try DataExportImport.importJSON(data: data, context: context, customStore: store)
        let entries = try context.fetch(FetchDescriptor<DoseEntry>())
        #expect(Set(entries.map(\.id)) == [id, twin])
        #expect(entries.allSatisfy { $0.injectionSiteRaw == "thigh.left" })
        entries.first { $0.id == id }?.amount = 20
        try context.save()
        try DataExportImport.importJSON(data: data, context: context, customStore: store)
        let saved = try context.fetch(FetchDescriptor<DoseEntry>())
        #expect(saved.count == 2 && saved.first { $0.id == id }?.amount == 20)
        let med = try #require(try context.fetch(FetchDescriptor<DailyDoseItem>()).first)
        #expect(med.frequency == .everyNDays && med.frequencyIntervalDays == 5)
        let exported = try DataExportImport.exportJSON(context: context, customStore: store)
        let file = try JSONDecoder().decode(PiruFile.self, from: exported)
        #expect(file.dailyDoseItems.first?.frequencyIntervalDays == 5)
        #expect((file.orphanDoses + file.sessions.flatMap(\.doses)).allSatisfy { $0.injectionSite == "thigh.left" })
    }
}
