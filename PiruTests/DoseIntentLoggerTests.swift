import Foundation
import SwiftData
import Testing
@testable import Piru

/// The headless save behind the Log Dose action: the same entry the quick-log
/// tray would commit from a search hit, written through the batch pipeline.
@MainActor
@Suite("DoseIntentLogger")
struct DoseIntentLoggerTests {
    /// Held for the test's lifetime: a `ModelContext` does not retain its container.
    private let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: Schema(PiruSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        )
    }

    @Test
    func `Concerta logs as Methylphenidate under its product, with every field`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let context = container.mainContext
        let time = Date(timeIntervalSince1970: 1_760_779_800)

        let entry = try await DoseIntentLogger.log(
            DoseIntentLogger.Request(
                name: "Concerta", amount: 27, unit: "mg", route: .oral, time: time,
                meal: .empty, notes: "after breakfast", tags: ["work", " morning "],
            ),
            in: context,
        )

        #expect(entry.substance == "Methylphenidate")
        #expect(entry.productName == "Concerta")
        #expect(entry.releaseForm == "XR")
        #expect(entry.substanceUID != nil)
        #expect(entry.amount == 27)
        #expect(entry.unit == "mg")
        #expect(entry.route == .oral)
        #expect(entry.timestamp == time)
        #expect(entry.meal == .empty)
        #expect(entry.notes == "after breakfast")
        #expect(entry.tags == ["work", "morning"])
        #expect(!entry.isUnknownDose)

        let saved = try context.fetch(FetchDescriptor<DoseEntry>())
        #expect(saved.count == 1)
        #expect(saved.first?.session != nil)
        // The chip the tray would have minted for a tapped dose.
        let chips = try context.fetch(FetchDescriptor<QuickLogDose>())
        #expect(chips.map(\.productName) == ["Concerta"])
    }

    @Test
    func `Meal stays off a dose that was not swallowed`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let entry = try await DoseIntentLogger.log(
            DoseIntentLogger.Request(name: "Ketamine", amount: 30, route: .insufflation, meal: .full),
            in: container.mainContext,
        )
        #expect(entry.route == .insufflation)
        #expect(entry.meal == nil)
    }

    @Test
    func `Route and unit default from the catalog`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let caffeine = try #require(SubstanceLibrary.lookup("Caffeine"))
        let entry = try await DoseIntentLogger.log(
            DoseIntentLogger.Request(name: "caffeine", amount: 100),
            in: container.mainContext,
        )
        #expect(entry.substance == "Caffeine")
        #expect(entry.productName == nil)
        #expect(entry.route == caffeine.defaultRoute)
        #expect(entry.unit == caffeine.unit(for: caffeine.defaultRoute))
        #expect(entry.timestamp.timeIntervalSinceNow > -60)
    }

    @Test
    func `No amount logs an unknown dose and mints no chip`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let context = container.mainContext
        let entry = try await DoseIntentLogger.log(DoseIntentLogger.Request(name: "MDMA"), in: context)
        #expect(entry.isUnknownDose)
        #expect(entry.amount == 0)
        #expect(try context.fetch(FetchDescriptor<QuickLogDose>()).isEmpty)
        #expect(DoseIntentLogger.summary(for: entry).hasPrefix("MDMA ("))
    }

    @Test
    func `An ester alias rides on the salt form and its injection route`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let entry = try await DoseIntentLogger.log(
            DoseIntentLogger.Request(name: "Estradiol Valerate", amount: 4),
            in: container.mainContext,
        )
        #expect(entry.substance == "Estradiol")
        #expect(entry.saltForm == "Valerate")
        #expect(entry.productName == nil)
        #expect(entry.route == .intramuscular || entry.route == .subcutaneous)
    }

    @Test
    func `A name nobody knows is refused`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        await #expect(throws: DoseIntentLogger.Failure.self) {
            _ = try await DoseIntentLogger.log(DoseIntentLogger.Request(name: "ZZNoSuchSubstance", amount: 1), in: container.mainContext)
        }
    }

    @Test
    func `The summary reads amount, title, route and time`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let entry = try await DoseIntentLogger.log(
            DoseIntentLogger.Request(name: "Concerta", amount: 27, unit: "mg", route: .oral),
            in: container.mainContext,
        )
        let summary = DoseIntentLogger.summary(for: entry)
        #expect(summary.hasPrefix("27 mg Concerta, Oral, "))
    }
}
