import Foundation
import SwiftData
import Testing
@testable import Piru

/// A combination product as one thing: counted in pills (or measured in mL),
/// staged under one product row whose quantity drives every component, made
/// in Add a Med, and checked off by one entry per pick.
@MainActor
@Suite("Combination products")
struct CombinationProductTests {
    /// Raw component names the library does not carry, so staging reads no catalog.
    private var tablet: CustomSubstanceEntry {
        CustomSubstanceEntry(
            name: "ZZCodamol", unit: "pill",
            components: [
                CombinationComponent(substance: "ZZParaAlpha", amountPerUnit: 500, unit: "mg", route: .oral),
                CombinationComponent(substance: "ZZCodeBeta", amountPerUnit: 30, unit: "mg", route: .oral),
            ],
        )
    }

    private var syrup: CustomSubstanceEntry {
        CustomSubstanceEntry(
            name: "ZZSyrup", unit: "mL",
            components: [CombinationComponent(substance: "ZZParaAlpha", amountPerUnit: 24, unit: "mg", route: .oral)],
        )
    }

    // MARK: Unit words

    @Test
    func `A count of a solid product reads in its unit word`() {
        #expect(ProductUnitWord.pill.quantityLabel(1) == "1 pill")
        #expect(ProductUnitWord.pill.quantityLabel(2) == "2 pills")
        #expect(tablet.quantityLabel(2) == "2 pills")
        #expect(ProductUnitWord(word: "Tablets") == .tablet)
        #expect(ProductUnitWord(word: " capsule ") == .capsule)
        #expect(ProductUnitWord(word: "dose") == nil)
        // A word typed freely into an older product is shown as typed.
        let legacy = CustomSubstanceEntry(name: "ZZOld", unit: "dose", components: tablet.components)
        #expect(legacy.quantityLabel(2) == "2 dose")
    }

    @Test
    func `A liquid product reads in mL and offers half and one millilitre`() {
        #expect(syrup.quantityLabel(0.5) == "0.5 mL")
        #expect(syrup.quantityChips == [0.5, 1])
        #expect(tablet.quantityChips == [1, 2])
    }

    // MARK: Tray

    @Test
    func `The product's first row leads and its quantity reads off it`() {
        let tray = DoseTrayModel()
        tray.stage(product: tablet, amount: 2)

        #expect(tray.staged.count == 2)
        #expect(tray.leadRowID(ofCombination: "ZZCodamol") == tray.staged.first?.id)
        #expect(tray.stagedQuantity(of: tablet) == 2)
        #expect(tray.stagedQuantity(of: syrup) == nil)
    }

    /// One control moves every component of a solid product together.
    @Test
    func `Setting the units rescales every component`() {
        let tray = DoseTrayModel()
        tray.stage(product: tablet, amount: 1)
        tray.setUnits(3, of: tablet)

        #expect(tray.staged.map(\.totalAmount) == [1500, 90])
        #expect(tray.stagedQuantity(of: tablet) == 3)

        tray.setUnits(0, of: tablet)
        #expect(tray.stagedQuantity(of: tablet) == 1)
    }

    /// A dose of a component staged on its own stays its own row, untouched
    /// when the product's count changes.
    @Test
    func `Setting the units leaves a lone dose of a component alone`() {
        let tray = DoseTrayModel()
        tray.stage(substance: "ZZParaAlpha", route: .oral, amount: 250, unit: "mg", tint: nil, librarySubstance: nil)
        tray.stage(product: tablet, amount: 1)
        tray.setUnits(2, of: tablet)

        let alphas = tray.staged.filter { $0.substanceName == "ZZParaAlpha" }
        #expect(alphas.first { $0.combinationName == nil }?.totalAmount == 250)
        #expect(alphas.first { $0.combinationName != nil }?.totalAmount == 1000)
    }

    @Test
    func `A liquid product's quantity is its volume`() {
        let tray = DoseTrayModel()
        tray.stage(product: syrup, amount: 2.5)

        #expect(tray.stagedQuantity(of: syrup) == 2.5)
        #expect(tray.staged.map(\.totalAmount) == [60])
    }

    @Test
    func `Removing a product takes out every one of its rows`() {
        let tray = DoseTrayModel()
        tray.stage(substance: "ZZOther", route: .oral, amount: 5, unit: "mg", tint: nil, librarySubstance: nil)
        tray.stage(product: tablet, amount: 1)
        if let lead = tray.leadRowID(ofCombination: "ZZCodamol") { tray.openForEditing(lead) }
        tray.removeCombination("ZZCodamol")

        #expect(tray.staged.map(\.substanceName) == ["ZZOther"])
        #expect(tray.expandedItemIDs.isEmpty)
    }

    @Test
    func `The liquid volume field steps by tenths under 2 mL`() {
        #expect(StagedProductVolumeModel.step(at: 0.5) == 0.1)
        #expect(StagedProductVolumeModel.step(at: 5) == 0.5)
        #expect(StagedProductVolumeModel.step(at: 20) == 1)

        let volume = StagedProductVolumeModel()
        volume.text = "2"
        volume.adjust(-1)
        #expect(volume.enteredML == 1.9)
        volume.text = "0.1"
        volume.adjust(-1)
        #expect(volume.enteredML == 0.1)
    }

    // MARK: Adherence

    /// One pick logs an entry per component; only the lead one checks the
    /// med off, so a pick counts once. An entry under the product's own name
    /// (the widget's Take button) counts too.
    @Test
    func `Only the lead component's entry checks a product med off`() {
        let product = MedSchedule.ProductMed(name: "ZZCodamol", lead: "ZZParaAlpha")
        #expect(MedSchedule.productMatches(entryName: "ZZParaAlpha", entryCombination: "ZZCodamol", product: product))
        #expect(!MedSchedule.productMatches(entryName: "ZZCodeBeta", entryCombination: "ZZCodamol", product: product))
        #expect(!MedSchedule.productMatches(entryName: "ZZParaAlpha", entryCombination: nil, product: product))
        #expect(!MedSchedule.productMatches(entryName: "ZZParaAlpha", entryCombination: "Other", product: product))
        #expect(MedSchedule.productMatches(entryName: "zzcodamol", entryCombination: nil, product: product))
    }

    /// The streak scan runs off snapshots; a product med's day is complete
    /// once its lead entry is in, by any route.
    @Test
    func `The streak scan credits a product med by its lead entry`() {
        let day = Calendar.current.startOfDay(for: .now).addingTimeInterval(9 * 3600)
        let item = AdherenceCalculator.DailyItemSnapshot(
            substance: "ZZCodamol", identityKey: "zzcodamol", route: .oral, expectedPerDay: 1, isAsNeeded: false,
            startDate: .distantPast, frequency: .daily, frequencyDays: [],
            product: MedSchedule.ProductMed(name: "ZZCodamol", lead: "ZZParaAlpha"),
        )
        let entries = ["ZZParaAlpha", "ZZCodeBeta"].map {
            AdherenceCalculator.EntrySnapshot(
                substance: $0, identityKey: $0.lowercased(), route: .oral, timestamp: day, combinationName: "ZZCodamol",
            )
        }
        #expect(AdherenceCalculator.dayStatus(for: day, entries: entries, items: [item]) == .complete)
        #expect(AdherenceCalculator.dayStatus(for: day, entries: [entries[1]], items: [item]) == .missed)
    }

    // MARK: Add a Med

    @Test
    func `A liquid product draft saves per mL with no pharmacology of its own`() {
        let draft = MedProductDraft()
        draft.name = " ZZDrops "
        draft.isLiquid = true
        #expect(!draft.canSave)

        var component = ProductComponentDraft(rawName: "ZZParaAlpha")
        draft.components = [component]
        #expect(!draft.canSave)
        component.amount = 2
        draft.components = [component]
        #expect(draft.canSave)

        let entry = draft.makeEntry()
        #expect(entry.name == "ZZDrops")
        #expect(entry.isLiquidCombination)
        #expect(entry.components?.first?.amountPerUnit == 2)
        #expect(entry.doses == nil && entry.duration == nil && entry.halfLifeMinutes == nil)
    }

    @Test
    func `A solid product draft saves under pills by default`() {
        let draft = MedProductDraft()
        draft.name = "ZZTabs"
        var component = ProductComponentDraft(rawName: "ZZParaAlpha")
        component.amount = 500
        draft.components = [component]

        let entry = draft.makeEntry()
        #expect(entry.unit == "pill")
        #expect(!entry.isLiquidCombination)
        #expect(entry.quantityLabel(1) == "1 pill")
    }

    /// Editing a saved product keeps its identity and its unit word.
    @Test
    func `A product draft edits the saved entry in place`() {
        let draft = MedProductDraft(product: tablet)
        #expect(draft.unitWord == "pill")
        #expect(draft.components.map(\.amount) == [500, 30])
        draft.name = "ZZCodamol Forte"
        let entry = draft.makeEntry()
        #expect(entry.id == draft.existing?.id)
        #expect(entry.name == "ZZCodamol Forte")
    }

    @Test
    func `A product name can't take another custom entry's`() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Schema(PiruSchema.models), configurations: config)
        let store = CustomSubstanceStore.forTesting(context: container.mainContext)
        store.add(CustomSubstanceEntry(name: "ZZTaken"))

        let draft = MedProductDraft()
        draft.name = "zztaken"
        #expect(draft.nameIsTaken(in: store))
        draft.name = "ZZFree"
        #expect(!draft.nameIsTaken(in: store))
    }

    // MARK: Any substance by volume

    @Test
    func `A solution's mass is volume times concentration in its own unit`() {
        let solution = ByVolumeDosing.solution(in: "mg")
        #expect(solution.isMassPerVolume)
        #expect(solution.canonicalUnit == "mg")
        #expect(solution.drinkPresets.isEmpty)
        #expect(solution.canonicalAmount(volumeML: 0.5, strength: 20) == 10)
        #expect(solution.volumeML(forAmount: 10, strength: 20) == 0.5)
        #expect(ByVolumeDosing.solutionUnits.contains("µg"))
        #expect(!ByVolumeDosing.solutionUnits.contains("mL"))
    }
}
