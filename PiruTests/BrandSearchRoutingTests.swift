import Foundation
import Testing
@testable import Piru

/// A search for a brand ("Concerta") titles its row with the brand and opens the
/// molecule's page (Methylphenidate) with that brand preselected in Branded
/// formulations — through the route, so a deep link lands the same way.
@Suite("Brand search routing")
@MainActor
struct BrandSearchRoutingTests {
    @Test
    func `A brand hit carries the brand to the detail route`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let hit = try #require(SubstanceLibrary.searchMatches("Concerta", limit: 5).first)
        #expect(hit.substance.name == "Methylphenidate")
        #expect(hit.displayName == "Concerta")
        #expect(hit.matchedBrand == "Concerta")
    }

    @Test
    func `A matched alias that is not a brand carries none`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let hit = try #require(SubstanceLibrary.searchMatches("咖啡因", limit: 5).first)
        #expect(hit.matchedAlias == "咖啡因")
        #expect(hit.matchedBrand == nil)
        let plain = try #require(SubstanceLibrary.searchMatches("Methylphenidate", limit: 5).first)
        #expect(plain.matchedBrand == nil)
    }

    @Test
    func `The detail page preselects a brand that has a curve, in the catalog's spelling`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let uid = try #require(SubstanceLibrary.lookup("Methylphenidate")?.substanceUID)
        #expect(DoseDurationSection.preselectedBrand("Concerta", substanceUID: uid) == "Concerta")
        #expect(DoseDurationSection.preselectedBrand("concerta", substanceUID: uid) == "Concerta")
        // Ritalin is a brand with no authored duration, so no row to select.
        #expect(DoseDurationSection.preselectedBrand("Ritalin", substanceUID: uid) == nil)
        #expect(DoseDurationSection.preselectedBrand("Vyvanse", substanceUID: uid) == nil)
        #expect(DoseDurationSection.preselectedBrand(nil, substanceUID: uid) == nil)
    }

    @Test
    func `piru://substance/<name>?brand= decodes and round-trips`() throws {
        let url = try #require(URL(string: "piru://substance/Methylphenidate?brand=Concerta"))
        let outcome = DeepLink.decode(url)
        #expect(outcome?.tab == .library)
        #expect(outcome?.path == [.substance(name: "Methylphenidate", brand: "Concerta")])

        let snap = NavigatorSnapshot(
            selectedTab: .library,
            paths: [.library: [.substance(name: "Methylphenidate", brand: "Concerta")]],
        )
        let encoded = DeepLink.encode(snap)
        #expect(encoded?.absoluteString == "piru://substance/Methylphenidate?brand=Concerta")
        #expect(encoded.flatMap(DeepLink.decode)?.path == [.substance(name: "Methylphenidate", brand: "Concerta")])
    }

    @Test
    func `A persisted substance route without a brand still decodes`() throws {
        let legacy = Data(#"{"substance":{"name":"MDMA"}}"#.utf8)
        let route = try JSONDecoder().decode(PushRoute.self, from: legacy)
        #expect(route == .substance(name: "MDMA"))
        let roundTrip = try JSONDecoder().decode(PushRoute.self, from: JSONEncoder().encode(route))
        #expect(roundTrip == .substance(name: "MDMA", brand: nil))
    }
}
