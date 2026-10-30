import Foundation
import SwiftData
import Testing
@testable import Piru

@MainActor
@Suite(.serialized)
struct Port16ImportTests {
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
