import Foundation
import Testing
@testable import Piru

/// The Shortcuts substance parameter: what a typed name becomes, and that it
/// comes back the same from the identifier Shortcuts stores.
@MainActor
@Suite("SubstanceEntity")
struct SubstanceEntityTests {
    @Test
    func `Concerta is Methylphenidate under its product name`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let hit = try #require(await SubstanceEntity.matches("Concerta", customs: []).first)
        #expect(hit.name == "Methylphenidate")
        #expect(hit.alias == "Concerta")
        #expect(hit.title == "Concerta")
        #expect(hit.subtitle?.contains("Methylphenidate") == true)
        #expect(hit.typedName == "Concerta")
        #expect(hit.id == "Methylphenidate|Concerta")

        // A saved shortcut resolves the stored identifier to the same entity.
        #expect(SubstanceEntity.resolve(id: hit.id, customs: []) == hit)

        // The name it logs by keeps the product.
        let named = try #require(await SubstanceLibrary.resolveNamed(hit.typedName))
        #expect(named.substance.name == "Methylphenidate")
        #expect(named.productName == "Concerta")
        #expect(named.saltForm == nil)
    }

    @Test
    func `The canonical name carries no product`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let hit = try #require(await SubstanceEntity.matches("MDMA", customs: []).first)
        #expect(hit.name == "MDMA")
        #expect(hit.alias == nil)
        #expect(hit.id == "MDMA")
        let named = try #require(await SubstanceLibrary.resolveNamed("mdma"))
        #expect(named.productName == nil)
    }

    @Test
    func `An ester alias rides on the salt form`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let named = try #require(await SubstanceLibrary.resolveNamed("Estradiol Valerate"))
        #expect(named.substance.name == "Estradiol")
        #expect(named.saltForm == "Valerate")
        #expect(named.productName == nil)
    }

    @Test
    func `A custom substance is an entity of its own`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let entry = CustomSubstanceEntry(name: "ZZ Kava Blend", displayName: "evening kava", unit: "cup")
        let hits = await SubstanceEntity.matches("kava blend", customs: [entry])
        let hit = try #require(hits.first { $0.id.hasPrefix("custom:") })
        #expect(hit.name == "ZZ Kava Blend")
        #expect(hit.title == "evening kava")
        #expect(hit.subtitle == "ZZ Kava Blend")
        #expect(hit.typedName == "ZZ Kava Blend")
        #expect(SubstanceEntity.resolve(id: hit.id, customs: [entry]) == hit)
        #expect(SubstanceEntity.resolve(id: hit.id, customs: []) == nil)
    }

    @Test
    func `A stored record names its substance under the product it kept`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let med = try #require(SubstanceEntity.named("Methylphenidate", productName: "Concerta", customs: []))
        #expect(med.id == "Methylphenidate|Concerta")
        let plain = try #require(SubstanceEntity.named("Methylphenidate", productName: "Methylphenidate", customs: []))
        #expect(plain.id == "Methylphenidate")
        #expect(SubstanceEntity.named("ZZGone", productName: nil, customs: []) == nil)
    }
}
