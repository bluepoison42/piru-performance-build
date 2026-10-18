import AppIntents
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
    func `A combination logs one entry per component, the amount counting units`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let context = container.mainContext
        let coCodamol = CustomSubstanceEntry(name: "Co-codamol", category: .opioid, unit: "tablet", components: [
            CombinationComponent(substance: "Paracetamol", amountPerUnit: 500, unit: "mg", route: .oral),
            CombinationComponent(substance: "Codeine", amountPerUnit: 30, unit: "mg", route: .oral),
        ])

        let entries = try await DoseIntentLogger.logAll(
            DoseIntentLogger.Request(name: "co-codamol", amount: 2, meal: .light, notes: "headache"),
            in: context,
            customs: [coCodamol],
        )

        #expect(entries.count == 2)
        #expect(entries.map(\.combinationName) == ["Co-codamol", "Co-codamol"])
        #expect(Set(entries.map(\.amount)) == [1000, 60])
        #expect(entries.allSatisfy { $0.route == .oral && $0.meal == .light && $0.notes == "headache" })
        #expect(entries.allSatisfy { $0.session != nil })
        let summary = DoseIntentLogger.summary(for: entries)
        #expect(summary.hasPrefix("Co-codamol: "))
        #expect(summary.contains("60 mg"))
    }

    @Test
    func `A unit count from outside is clamped, never trapped on`() {
        #expect(CombinationComponent.units(for: nil) == 1)
        #expect(CombinationComponent.units(for: 0) == 1)
        #expect(CombinationComponent.units(for: -4) == 1)
        #expect(CombinationComponent.units(for: 2.4) == 2)
        #expect(CombinationComponent.units(for: 1e300) == CombinationComponent.maximumUnits)
        #expect(CombinationComponent.units(for: .infinity) == 1)
        #expect(CombinationComponent.units(for: .nan) == 1)
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
    func `Both actions need an unlocked device`() {
        // A dose is health data: neither action may run from Siri on a locked phone.
        #expect(LogDoseIntent.authenticationPolicy == .requiresAuthentication)
        #expect(StartDoseLogIntent.authenticationPolicy == .requiresAuthentication)
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
