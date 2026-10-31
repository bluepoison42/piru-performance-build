import Foundation
import GRDB
import SwiftData
import SwiftUI
import Testing
@testable import Piru

@MainActor
@Suite("Audit completion", .serialized)
struct AuditCompletionTests {
    private func makeContainer(at url: URL? = nil, allowsSave: Bool = true) throws -> ModelContainer {
        let configuration = url.map { ModelConfiguration(url: $0, allowsSave: allowsSave, cloudKitDatabase: .none) }
            ?? ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Schema(PiruSchema.models), configurations: configuration)
    }

    @Test
    func `Combination brand and form survive save export and staging`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let container = try makeContainer()
        let context = container.mainContext
        let store = CustomSubstanceStore.forTesting(context: context)
        let methylphenidate = try #require(SubstanceLibrary.lookup("Methylphenidate"))
        let ketamine = try #require(SubstanceLibrary.lookup("Ketamine"))
        let draft = MedProductDraft()
        draft.name = "ZZAudit combination"
        var branded = ProductComponentDraft(substance: methylphenidate, displayName: "Concerta")
        branded.amount = 18
        var isomer = ProductComponentDraft(substance: ketamine, displayName: "Esketamine")
        isomer.amount = 2
        draft.components = [branded, isomer]
        store.add(draft.makeEntry())
        let bytes = try DataExportImport.exportJSON(context: context, customStore: store)
        let file = try JSONDecoder().decode(PiruFile.self, from: bytes)
        let restored = try #require(file.customSubstances.first { $0.name == draft.name }).asEntry
        let reopened = MedProductDraft(product: restored)
        #expect(reopened.components.map(\.displayName) == ["Concerta", "Esketamine"])
        let tray = DoseTrayModel()
        tray.stage(combination: reopened.makeEntry())
        #expect(tray.staged[0].productName == "Concerta")
        #expect(tray.staged[0].releaseForm == "XR")
        #expect(tray.staged[1].productName == "Esketamine")
        #expect(tray.staged[1].isomer == "S")
    }

    @Test
    func `Branded and generic forms inside one combination count as one medication dose`() throws {
        let container = try makeContainer()
        let store = CustomSubstanceStore.forTesting(context: container.mainContext)
        let product = CustomSubstanceEntry(name: "ZZBranded pair", unit: "caps", components: [
            CombinationComponent(substance: "Methylphenidate", amountPerUnit: 10, unit: "mg", route: .oral),
            CombinationComponent(substance: "Methylphenidate", amountPerUnit: 18, unit: "mg", route: .oral, productName: "Concerta", releaseForm: "XR"),
        ])
        store.add(product)
        let item = DailyDoseItem(substance: product.name, amount: 1, unit: "caps")
        let lead = DoseEntry(substance: "Methylphenidate", amount: 18, productName: "Concerta", combinationName: product.name)
        let other = DoseEntry(substance: "Methylphenidate", amount: 10, combinationName: product.name)
        #expect(AdherenceCalculator.entryMatches(entry: lead, item: item, products: store.productMeds))
        #expect(!AdherenceCalculator.entryMatches(entry: other, item: item, products: store.productMeds))
    }

    @Test
    func `Late logging and skip undo agree between Quick Log and the dock`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let today = calendar.medicationDayLabel(for: .now)
        let evening = try #require(calendar.date(bySettingHour: 19, minute: 0, second: 0, of: today))
        let item = DailyDoseItem(substance: "ZZAudit routine", amount: 10, reminderTimesMinutes: [480, 1080])
        context.insert(item)
        let dose = DoseEntry(substance: item.substance, amount: 10, timestamp: evening.addingTimeInterval(-3600))
        context.insert(dose)
        try context.save()
        RoutineOccurrenceService.reconcile(in: context, now: evening)
        var occurrences = try context.fetch(FetchDescriptor<RoutineOccurrence>())
        #expect(DueNowSlot.derive(items: [item], todayEntries: [dose], occurrences: occurrences, now: evening).map(\.slotMinutes) == [480])
        let key = RoutineOccurrenceService.slotKey(substance: item.substance, substanceUID: item.substanceUID, route: item.route, slotMinutes: 480)
        RoutineOccurrenceService.skipToday(slotKeys: [key], in: context, now: evening)
        occurrences = try context.fetch(FetchDescriptor<RoutineOccurrence>())
        let content = QuickLogContentModel()
        content.rebuildEntryDerived(allEntries: [dose], dailyDoseItems: [item], routines: [], occurrences: occurrences)
        #expect(content.makeDailyGroups(dailyDoseItems: [item], routines: [], now: evening).allSatisfy { $0.remaining.isEmpty && !$0.isDue })
        #expect(DockLabelContext.derive(items: [item], in: context, now: evening).dueMedNames.isEmpty)
        RoutineOccurrenceService.unskipToday(slotKeys: [key], in: context, now: evening)
        #expect(DockLabelContext.derive(items: [item], in: context, now: evening).dueMedNames.count == 1)
    }

    @Test
    func `A failed save keeps the legacy source and stops automatic backup`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.store")
        try autoreleasepool {
            let initial = try makeContainer(at: url)
            try initial.mainContext.save()
        }
        let reader = try makeContainer(at: url, allowsSave: false)
        let context = ModelContext(reader)
        context.autosaveEnabled = false
        let suite = "piru.audit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "piru.customSubstances.v1"
        let source = try JSONEncoder().encode([CustomSubstanceEntry(name: "ZZLegacy")])
        defaults.set(source, forKey: key)
        _ = CustomSubstanceStore.forTesting(context: context, mirrorDefaults: defaults)
        #expect(defaults.data(forKey: key) == source)
        #expect(throws: (any Error).self) { try DataExportImport.prepareAutomaticBackup(context: context) }
        #expect(context.hasChanges)
    }

    @Test
    func `Temporary recovery mode preserves the legacy source and blocks automatic backup`() throws {
        let container = try makeContainer()
        let suite = "piru.audit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "piru.customSubstances.v1"
        let source = try JSONEncoder().encode([CustomSubstanceEntry(name: "ZZLegacy")])
        defaults.set(source, forKey: key)
        let previous = StoreLaunchState.shared.storeUnavailable
        StoreLaunchState.shared.storeUnavailable = true
        defer { StoreLaunchState.shared.storeUnavailable = previous }
        _ = CustomSubstanceStore.forTesting(context: container.mainContext, mirrorDefaults: defaults)
        #expect(defaults.data(forKey: key) == source)
        #expect(try container.mainContext.fetch(FetchDescriptor<CustomSubstanceRecord>()).isEmpty)
        #expect(throws: (any Error).self) { try DataExportImport.prepareAutomaticBackup(context: container.mainContext) }
    }

    @Test
    func `Store copy includes committed WAL data and replaces an existing snapshot`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.store")
        let destination = directory.appendingPathComponent("snapshot.store")
        let writer = try DatabaseQueue(path: source.path)
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE sample(value INTEGER); INSERT INTO sample VALUES (100); PRAGMA wal_checkpoint(TRUNCATE); UPDATE sample SET value=200")
        }
        try StoreRecovery.copyStore(from: source, to: destination)
        try writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE); UPDATE sample SET value=300") }
        let first = try DatabaseQueue(path: destination.path)
        #expect(try first.read { try Int.fetchOne($0, sql: "SELECT value FROM sample") } == 200)
        try first.close()
        try StoreRecovery.copyStore(from: source, to: destination)
        let second = try DatabaseQueue(path: destination.path)
        #expect(try second.read { try Int.fetchOne($0, sql: "SELECT value FROM sample") } == 300)
    }

    @Test
    func `Changing only a color rebuilds the real timeline card`() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dose = DoseEntry(substance: "Caffeine", amount: 10, timestamp: Date.now.addingTimeInterval(-3600))
        let red = P3Color(red: 1, green: 0, blue: 0)
        let blue = P3Color(red: 0, green: 0, blue: 1)
        let color = SubstanceColor(substance: dose.substance, tint: red, usesDefault: false)
        context.insert(dose)
        context.insert(color)
        try context.save()
        let model = UnifiedTimelineModel()
        await model.rebuild(entries: [dose], colors: [color], colorMap: [color].colorMap, revision: 42,
                            zoom: 1, compressGaps: true, pkCurves: false, curveScale: .doseStrength,
                            showsAxis: true, bubbleStyle: .full, showsVitals: false, cacheable: false)
        #expect(model.days.flatMap(\.cardGroups).flatMap(\.items).first?.color == red.color)
        color.set(blue, usesDefault: false)
        try context.save()
        await model.rebuild(entries: [dose], colors: [color], colorMap: [color].colorMap, revision: 42,
                            zoom: 1, compressGaps: true, pkCurves: false, curveScale: .doseStrength,
                            showsAxis: true, bubbleStyle: .full, showsVitals: false, cacheable: false)
        #expect(model.days.flatMap(\.cardGroups).flatMap(\.items).first?.color == blue.color)
    }

    @Test
    func `Historical repair preserves a logged association from another time zone`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let timestamp = Date.now.addingTimeInterval(-2 * 86400)
        var oldCalendar = Calendar.current
        oldCalendar.timeZone = try #require(TimeZone(secondsFromGMT: TimeZone.current.secondsFromGMT(for: timestamp) + 3600))
        let dose = DoseEntry(substance: "ZZHistory", amount: 10, timestamp: timestamp)
        context.insert(dose)
        let occurrence = RoutineOccurrence(substance: dose.substance, route: .oral, dueDay: oldCalendar.medicationDayLabel(for: timestamp), slotMinutes: 480)
        occurrence.state = .logged
        occurrence.satisfyingEntryID = dose.id
        context.insert(occurrence)
        try context.save()
        try RoutineOccurrenceService.repairHistoricalDays(in: context)
        try context.save()
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<RoutineOccurrence>()).first)
        #expect(stored.state == .logged)
        #expect(stored.satisfyingEntryID == dose.id)
    }
}
