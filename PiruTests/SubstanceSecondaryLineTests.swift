import Foundation
import Testing
@testable import Piru

/// The line under a substance row's title, shared by every search picker and the
/// Library: curated aliases and the alias the query named, never the raw alias
/// list, and never a script the UI language cannot read.
@Suite("Substance secondary line")
@MainActor
struct SubstanceSecondaryLineTests {
    private func caffeine(popularAliases: [String] = []) -> Substance {
        Substance(
            name: "Caffeine",
            aliases: ["1,3,7-trimethylxanthine", "1,3,7-三甲基黄嘌呤", "咖啡因", "Theine"],
            category: .stimulant,
            defaultRoute: .oral,
            routes: [],
            effects: [],
            popularAliases: popularAliases,
        )
    }

    @Test
    func `An English search for caff shows no CJK under Caffeine`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let hit = try #require(SubstanceLibrary.searchMatches("caff", limit: 5).first { $0.substance.name == "Caffeine" })
        #expect(hit.substance.aliases.contains { $0.containsHan }, "the fixture this guards needs a Han alias in the catalog")
        #expect(hit.secondaryLine(language: .en)?.containsHan != true)
    }

    @Test
    func `The raw alias list never reaches the secondary line`() {
        let match = SubstanceMatch(substance: caffeine(), matchedAlias: nil)
        #expect(match.secondaryLine(language: .en) == nil)
        #expect(match.secondaryLine(language: .zhHans) == nil)
    }

    @Test
    func `A CJK alias the query named stays visible in an English UI`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let hit = try #require(SubstanceLibrary.searchMatches("咖啡因", limit: 5).first)
        #expect(hit.substance.name == "Caffeine")
        #expect(hit.matchedAlias == "咖啡因")
        #expect(hit.displayName == "咖啡因")
        #expect(hit.secondaryLine(language: .en) == "Caffeine")

        // Under a title that is not the alias, the matched alias still rides along.
        let line = caffeine().secondaryLine(under: "Caffeine", matchedAlias: "咖啡因", language: .en)
        #expect(line == "咖啡因")
    }

    @Test
    func `Curated CJK aliases show in Chinese UIs and nowhere else`() {
        let substance = caffeine(popularAliases: ["Coffee", "咖啡"])
        let match = SubstanceMatch(substance: substance, matchedAlias: nil)
        #expect(match.secondaryLine(language: .zhHans) == "Coffee, 咖啡")
        #expect(match.secondaryLine(language: .zhHant) == "Coffee, 咖啡")
        #expect(match.secondaryLine(language: .en) == "Coffee")
        #expect(match.secondaryLine(language: .es) == "Coffee")
    }

    @Test
    func `A brand row leads with the substance it names`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let hit = try #require(SubstanceLibrary.searchMatches("Concerta", limit: 5).first)
        #expect(hit.displayName == "Concerta")
        // Methylphenidate's curated aliases are Ritalin and Concerta; the title
        // already says Concerta, so it is not repeated.
        #expect(hit.secondaryLine(language: .en) == "Methylphenidate, Ritalin")
    }

    @Test
    func `Hand-picked flagship brands count as curated`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let hit = try #require(SubstanceLibrary.searchMatches("Lisdexamfetamine", limit: 5).first)
        #expect(hit.substance.curatedBrands == ["Vyvanse"])
        #expect(hit.secondaryLine(language: .en) == "Vyvanse")

        // A curated brand that is also a popular alias is listed once.
        let mph = try #require(SubstanceLibrary.searchMatches("Methylphenidate", limit: 5).first)
        #expect(mph.secondaryLine(language: .en) == "Ritalin, Concerta")

        // The full record carries them too.
        let full = try #require(SubstanceLibrary.resolveFull("Lisdexamfetamine"))
        #expect(full.curatedBrands == ["Vyvanse"])
    }

    @Test
    func `Search hits carry curated popular aliases from the batch projection`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let hit = try #require(SubstanceLibrary.searchMatches("MDMA", limit: 5).first)
        #expect(hit.substance.popularAliases == ["Ecstasy", "Molly", "E"])
        #expect(hit.secondaryLine(language: .en) == "Ecstasy, Molly, E")
    }

    @Test
    func `Script check reads Latin and chemical Greek everywhere, Han only in Chinese`() {
        #expect(ContentLanguage.en.writesScript(of: "β-keto-amphetamine"))
        #expect(ContentLanguage.en.writesScript(of: "Cafeína"))
        #expect(ContentLanguage.en.writesScript(of: "1,3,7-trimethylxanthine"))
        #expect(!ContentLanguage.en.writesScript(of: "1,3,7-三甲基黄嘌呤"))
        #expect(!ContentLanguage.es.writesScript(of: "咖啡因"))
        #expect(ContentLanguage.zhHans.writesScript(of: "1,3,7-三甲基黄嘌呤"))
        #expect(ContentLanguage.zhHant.writesScript(of: "咖啡鹼"))
        #expect(!ContentLanguage.zhHans.writesScript(of: "Кофеин"))
        #expect(!ContentLanguage.en.writesScript(of: "カフェイン"))
    }
}
