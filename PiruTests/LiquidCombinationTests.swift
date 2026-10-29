import Foundation
import Testing
@testable import Piru

/// A combination product defined per mL: each component's amount is per
/// millilitre, it is logged by a volume, and every component stages at
/// volume × its amount per mL in its own unit.
@MainActor
@Suite("Liquid combinations")
struct LiquidCombinationTests {
    /// Raw component names the library does not carry, so staging reads no
    /// catalog: 2 g/mL of one compound, 5 mg/mL of the other.
    private var solution: CustomSubstanceEntry {
        CustomSubstanceEntry(
            name: "Test solution", unit: "mL",
            components: [
                CombinationComponent(substance: "ZZLiquidAlpha", amountPerUnit: 2, unit: "g", route: .oral),
                CombinationComponent(substance: "ZZLiquidBeta", amountPerUnit: 5, unit: "mg", route: .oral),
            ],
        )
    }

    // MARK: Arithmetic

    @Test
    func `A component's amount is volume times its amount per mL, in its own unit`() {
        let morphine = CombinationComponent(substance: "Morphine", amountPerUnit: 2, unit: "g", route: .oral)
        #expect(morphine.amount(inVolumeML: 0.25) == 0.5)
        #expect(morphine.amount(inVolumeML: 1.5) == 3)
        #expect(morphine.amount(inVolumeML: 0) == 0)
        #expect(morphine.amount(inVolumeML: -1) == 0)
        #expect(morphine.amount(inVolumeML: .nan) == 0)
        #expect(morphine.amount(inVolumeML: .infinity) == 0)
    }

    /// An automation's amount for a liquid is millilitres: fractions kept,
    /// capped, and 1 mL for anything that is not a usable volume.
    @Test
    func `An automation's amount reads as a volume in mL`() {
        #expect(CombinationComponent.volumeML(for: 0.25) == 0.25)
        #expect(CombinationComponent.volumeML(for: 1.5) == 1.5)
        #expect(CombinationComponent.volumeML(for: nil) == 1)
        #expect(CombinationComponent.volumeML(for: 0) == 1)
        #expect(CombinationComponent.volumeML(for: -3) == 1)
        #expect(CombinationComponent.volumeML(for: .nan) == 1)
        #expect(CombinationComponent.volumeML(for: .infinity) == 1)
        #expect(CombinationComponent.volumeML(for: 1e300) == CombinationComponent.maximumVolumeML)
    }

    @Test
    func `A millilitre unit word makes a combination a liquid`() {
        #expect(solution.isLiquidCombination)
        for word in ["mL", "ml", " ML ", "millilitre", "milliliters"] {
            #expect(CombinationComponent.isVolumeUnitWord(word))
        }
        for word in ["tablet", "dose", "drop", "mg", ""] {
            #expect(!CombinationComponent.isVolumeUnitWord(word))
        }
        let tablet = CustomSubstanceEntry(
            name: "Co-codamol", unit: "tablet",
            components: [CombinationComponent(substance: "Paracetamol", amountPerUnit: 500, unit: "mg", route: .oral)],
        )
        #expect(!tablet.isLiquidCombination)
        // A single compound measured in mL is a compound, not a liquid product.
        #expect(!CustomSubstanceEntry(name: "ZZSyrup", unit: "mL").isLiquidCombination)
    }

    // MARK: Staging

    @Test
    func `Staging a volume stages each component at volume times its amount per mL`() {
        let tray = DoseTrayModel()
        tray.stage(combination: solution, volumeML: 0.25)

        #expect(tray.staged.count == 2)
        #expect(tray.staged.map(\.totalAmount) == [0.5, 1.25])
        #expect(tray.staged.map(\.unit) == ["g", "mg"])
        #expect(tray.staged.allSatisfy { $0.combinationName == "Test solution" })
        #expect(tray.staged.allSatisfy { $0.volumeML == 0.25 })
        #expect(tray.staged.map(\.abv) == [2, 5])
        let allLiquid = tray.staged.allSatisfy(\.isLiquidCombinationRow)
        #expect(allLiquid)
    }

    /// The default pick (no volume given) stages 1 mL, whatever quantity says.
    @Test
    func `Picking a liquid stages one millilitre`() {
        let tray = DoseTrayModel()
        tray.stage(combination: solution, quantity: 3)

        #expect(tray.staged.map(\.totalAmount) == [2, 5])
        #expect(tray.staged.allSatisfy { $0.volumeML == CombinationComponent.defaultVolumeML })
    }

    @Test
    func `Picking a liquid again adds its volume`() {
        let tray = DoseTrayModel()
        tray.stage(combination: solution, volumeML: 0.5)
        tray.stage(combination: solution, volumeML: 1)

        #expect(tray.staged.count == 2)
        #expect(tray.staged.map(\.totalAmount) == [3, 7.5])
        #expect(tray.staged.allSatisfy { $0.volumeML == 1.5 })
    }

    /// The editor's volume field moves every component of the product at once.
    @Test
    func `Setting the volume rescales every component`() {
        let tray = DoseTrayModel()
        tray.stage(combination: solution, volumeML: 1)
        tray.setVolume(1.5, ofCombination: "Test solution")

        #expect(tray.staged.map(\.totalAmount) == [3, 7.5])
        #expect(tray.staged.allSatisfy { $0.volumeML == 1.5 })
        #expect(tray.staged.allSatisfy { $0.components.count == 1 })

        tray.setVolume(0, ofCombination: "Test solution")
        #expect(tray.staged.map(\.totalAmount) == [3, 7.5])
    }

    /// A component whose substance is already staged on its own gets a row
    /// of its own: the lone dose keeps its mass, the product's row its volume.
    @Test
    func `A component never merges into a lone dose`() {
        let tray = DoseTrayModel()
        tray.stage(substance: "ZZLiquidBeta", route: .oral, amount: 10, unit: "mg", tint: nil, librarySubstance: nil)
        tray.stage(combination: solution, volumeML: 1)

        let betas = tray.staged.filter { $0.substanceName == "ZZLiquidBeta" }
        #expect(betas.count == 2)
        let lone = betas.first { $0.combinationName == nil }
        #expect(lone?.totalAmount == 10)
        #expect(lone?.volumeML == nil)
        let component = betas.first { $0.combinationName == "Test solution" }
        #expect(component?.totalAmount == 5)
        #expect(component?.volumeML == 1)
        #expect(component?.isLiquidCombinationRow == true)
    }

    // MARK: Two products sharing a component

    /// 400 mg + 20 mg per pill.
    private var compound: CustomSubstanceEntry {
        CustomSubstanceEntry(
            name: "ZZCompound", unit: "pill",
            components: [
                CombinationComponent(substance: "ZZSharedPara", amountPerUnit: 400, unit: "mg", route: .oral),
                CombinationComponent(substance: "ZZOxyOnly", amountPerUnit: 20, unit: "mg", route: .oral),
            ],
        )
    }

    /// 40 mg + 10 mg per mL.
    private var liquidCombo: CustomSubstanceEntry {
        CustomSubstanceEntry(
            name: "ZZLiquid Combo", unit: "mL",
            components: [
                CombinationComponent(substance: "ZZSharedPara", amountPerUnit: 40, unit: "mg", route: .oral),
                CombinationComponent(substance: "ZZMorphOnly", amountPerUnit: 10, unit: "mg", route: .oral),
            ],
        )
    }

    private func row(_ tray: DoseTrayModel, _ substance: String, of product: String) -> [StagedDose] {
        tray.staged.filter { $0.substanceName == substance && $0.combinationName == product }
    }

    /// Two products that share a substance each keep their own row of it,
    /// in whichever order they are picked.
    @Test(arguments: [true, false])
    func `A shared component stays in its own product`(liquidFirst: Bool) {
        let tray = DoseTrayModel()
        if liquidFirst {
            tray.stage(product: liquidCombo, amount: 1)
            tray.stage(product: compound, amount: 1)
        } else {
            tray.stage(product: compound, amount: 1)
            tray.stage(product: liquidCombo, amount: 1)
        }

        #expect(tray.staged.count == 4)
        let liquidPara = row(tray, "ZZSharedPara", of: "ZZLiquid Combo")
        let solidPara = row(tray, "ZZSharedPara", of: "ZZCompound")
        #expect(liquidPara.count == 1)
        #expect(solidPara.count == 1)
        #expect(liquidPara.first?.totalAmount == 40)
        #expect(liquidPara.first?.volumeML == 1)
        #expect(liquidPara.first?.abv == 40)
        #expect(solidPara.first?.totalAmount == 400)
        #expect(solidPara.first?.volumeML == nil)
        #expect(row(tray, "ZZMorphOnly", of: "ZZLiquid Combo").first?.totalAmount == 10)
        #expect(row(tray, "ZZOxyOnly", of: "ZZCompound").first?.totalAmount == 20)

        #expect(tray.stagedQuantity(of: liquidCombo) == 1)
        #expect(tray.stagedQuantity(of: compound) == 1)
        let leadsDiffer = tray.leadRowID(ofCombination: "ZZCompound") != tray.leadRowID(ofCombination: "ZZLiquid Combo")
        #expect(leadsDiffer)
    }

    /// Changing one product's quantity moves only that product's rows.
    @Test
    func `Rescaling one product leaves the other alone`() {
        let tray = DoseTrayModel()
        tray.stage(product: liquidCombo, amount: 1)
        tray.stage(product: compound, amount: 1)

        tray.setVolume(2.5, ofCombination: "ZZLiquid Combo")
        #expect(row(tray, "ZZSharedPara", of: "ZZLiquid Combo").first?.totalAmount == 100)
        #expect(row(tray, "ZZMorphOnly", of: "ZZLiquid Combo").first?.totalAmount == 25)
        #expect(row(tray, "ZZSharedPara", of: "ZZCompound").first?.totalAmount == 400)
        #expect(row(tray, "ZZOxyOnly", of: "ZZCompound").first?.totalAmount == 20)

        tray.setUnits(3, of: compound)
        #expect(row(tray, "ZZSharedPara", of: "ZZCompound").first?.totalAmount == 1200)
        #expect(row(tray, "ZZOxyOnly", of: "ZZCompound").first?.totalAmount == 60)
        #expect(row(tray, "ZZSharedPara", of: "ZZLiquid Combo").first?.totalAmount == 100)
        #expect(tray.stagedQuantity(of: liquidCombo) == 2.5)
        #expect(tray.stagedQuantity(of: compound) == 3)
    }

    /// Amounts a power of ten apart are different chips: 400 mg staged onto
    /// a 40 mg row is a second component, never a second 40.
    @Test
    func `Amounts a power of ten apart never count as one chip`() {
        let tray = DoseTrayModel()
        for amount in [4.0, 40, 400] {
            tray.stage(substance: "ZZTenfold", route: .oral, amount: amount, unit: "mg", tint: nil, librarySubstance: nil)
        }

        #expect(tray.staged.count == 1)
        #expect(tray.staged[0].components.count == 3)
        #expect(tray.staged[0].totalAmount == 444)
        #expect(tray.quantity(substance: "ZZTenfold", route: .oral, amount: 40, unit: "mg") == 1)
    }

    /// A per-unit product stages exactly as it always has, with no volume.
    @Test
    func `A per-unit combination records no volume`() {
        let tray = DoseTrayModel()
        let tablet = CustomSubstanceEntry(
            name: "ZZTablet", unit: "tablet",
            components: [CombinationComponent(substance: "ZZLiquidAlpha", amountPerUnit: 500, unit: "mg", route: .oral)],
        )
        tray.stage(combination: tablet, quantity: 2)

        #expect(tray.staged.map(\.totalAmount) == [1000])
        #expect(tray.staged.allSatisfy { $0.volumeML == nil && $0.abv == nil })
        #expect(!tray.staged[0].isLiquidCombinationRow)
    }

    // MARK: Stored data

    /// Combinations saved before liquids existed decode unchanged: the
    /// component JSON has no new field, and a per-unit word stays per unit.
    @Test
    func `Old component JSON decodes and stays per unit`() throws {
        let json = Data("""
        [{"substance":"Paracetamol","amountPerUnit":500,"unit":"mg","route":"oral"},
         {"substance":"Codeine","amountPerUnit":30,"unit":"mg","route":"oral"}]
        """.utf8)
        let components = try JSONDecoder().decode([CombinationComponent].self, from: json)
        #expect(components.map(\.amountPerUnit) == [500, 30])
        #expect(components.map(\.unit) == ["mg", "mg"])

        let entry = CustomSubstanceEntry(name: "Co-codamol", unit: "tablet", components: components)
        #expect(entry.isCombination)
        #expect(!entry.isLiquidCombination)
    }

    /// An entry stored before liquids existed, with its unit word typed as
    /// "ml", reads as a liquid: its amounts were already per mL.
    @Test
    func `An old entry with an ml unit word decodes as a liquid`() throws {
        let json = Data("""
        {"id":"6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D","name":"Old syrup","category":"Other",
         "defaultRoute":"oral","unit":"ml","notes":"","createdAt":0,
         "components":[{"substance":"ZZLiquidAlpha","amountPerUnit":2,"unit":"g","route":"oral"}]}
        """.utf8)
        let entry = try JSONDecoder().decode(CustomSubstanceEntry.self, from: json)
        #expect(entry.isLiquidCombination)
        #expect(entry.components?.first?.amount(inVolumeML: 0.25) == 0.5)
    }
}
