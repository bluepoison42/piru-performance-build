import Foundation
import Testing
@testable import Piru

/// The body-load trail resolves value snapshots of the dose log, fetched off the main
/// actor. Every answer a snapshot gives must be the one its `DoseEntry` gives, or the
/// warmed trail would differ from the one the graph computes from its `@Query`.
@Suite("BodyLoadEntry")
struct BodyLoadEntryTests {
    private let base = DurationProfile(
        onset: DurationRange(min: 20, max: 40),
        comeup: DurationRange(min: 30, max: 30),
        peak: DurationRange(min: 120, max: 180),
        offset: DurationRange(min: 60, max: 60),
        afterglow: nil,
        total: DurationRange(min: 240, max: 300),
    )

    private var entries: [DoseEntry] {
        [
            DoseEntry(substance: "MDMA", amount: 100, route: .oral, meal: .full),
            DoseEntry(substance: "MDMA", amount: 100, route: .insufflation, meal: .full),
            DoseEntry(substance: "Caffeine", amount: 0, isUnknownDose: true),
            DoseEntry(substance: "Alcohol", amount: 2, unit: "drinks"),
            DoseEntry(substance: "Methylphenidate", amount: 36, releaseForm: "XR", productName: "Concerta"),
            DoseEntry(substance: "Methylphenidate", amount: 20, releaseForm: "XR"),
            DoseEntry(substance: "Estradiol", amount: 5, route: .intramuscular, saltForm: "Valerate"),
            DoseEntry(substance: "Paliperidone", amount: 100, route: .intramuscular, releaseForm: "DEP"),
            DoseEntry(substance: "Something nobody catalogued", amount: 3, unit: "g"),
        ]
    }

    @Test
    func `A snapshot answers every plan question as its entry does`() async {
        await SubstanceStore.shared.ensureAllLoaded()
        for entry in entries {
            let snapshot = BodyLoadEntry(entry)
            let substance = SubstanceLibrary.lookup(entry.substance)
            let isDepot = PKResolver.isDepot(entry: entry)
            #expect(snapshot.quantity(using: substance) == (substance?.quantity(of: entry) ?? entry.quantity), "\(entry.substance)")
            #expect(snapshot.namesUnmodeledForm == entry.namesUnmodeledForm, "\(entry.substance)")
            #expect(snapshot.productDuration == entry.productDuration, "\(entry.substance)")
            #expect(snapshot.isDepot == isDepot, "\(entry.substance)")
            #expect(
                snapshot.halfLifeMinutes(substance: substance, isDepot: isDepot)
                    == PKResolver.halfLifeMinutes(for: entry, substance: substance),
                "\(entry.substance)",
            )
            #expect(snapshot.applyingMeal(to: base) == entry.applyingMeal(to: base), "\(entry.substance)")
        }
    }

    @Test
    func `The fixtures reach the depot, product, meal and unknown-dose branches`() async {
        await SubstanceStore.shared.ensureAllLoaded()
        let snapshots = entries.map(BodyLoadEntry.init)
        #expect(snapshots.contains { $0.isDepot })
        #expect(snapshots.contains { $0.productDuration != nil })
        #expect(snapshots.contains { $0.applyingMeal(to: base) != base })
        #expect(snapshots.contains { $0.quantity(using: nil) == nil })
        #expect(snapshots.contains { $0.namesUnmodeledForm && $0.productDuration == nil })
    }
}
