import Foundation
import Testing
@testable import Piru

@Suite("AppSources")
struct AppSourcesTests {
    @Test
    func `All sources have name and description`() {
        for source in AppSources.all {
            #expect(!source.name.isEmpty, "\(source.name) should have a name")
            #expect(!String(localized: source.description).isEmpty, "\(source.name) should have a description")
            #expect(!String(localized: source.detail).isEmpty, "\(source.name) should have a detail")
        }
    }

    @Test
    func `Lookup by name returns correct source`() {
        let tripSit = AppSources.info(for: "TripSit")
        #expect(tripSit != nil)
        #expect(tripSit?.url == "https://tripsit.me")
    }

    @Test
    func `Lookup OpenFDA`() {
        let fda = AppSources.info(for: "OpenFDA")
        #expect(fda != nil)
        #expect(fda?.url == "https://open.fda.gov")
    }

    @Test
    func `Lookup unknown returns nil`() {
        #expect(AppSources.info(for: "NotASource") == nil)
    }

    @Test
    func `All expected sources are present`() {
        let names = Set(AppSources.all.map(\.name))
        #expect(names.contains("TripSit"))
        #expect(names.contains("OpenFDA"))
        #expect(names.contains("PsychonautWiki"))
        #expect(names.contains("PubMed"))
        #expect(names.contains("PubChem"))
        #expect(names.contains("Wikidata"))
    }

    @Test
    func `Only sources whose data ships are listed`() {
        // DrugBank is a build-time cross-check; none of its values reach the
        // bundled database, so a row for it would claim data Piru lacks.
        #expect(AppSources.info(for: "DrugBank") == nil)
    }

    @Test
    func `Source descriptions keep the house voice`() {
        for source in AppSources.all {
            let description = String(localized: source.description).lowercased()
            #expect(!description.contains("harm reduction"), "\(source.name)")
            #expect(!description.contains("harm-reduction"), "\(source.name)")
        }
    }

    @Test
    func `The EU drugs agency is listed under its current name`() {
        let euda = AppSources.info(for: "EUDA (formerly EMCDDA)")
        #expect(euda?.url == "https://www.euda.europa.eu")
        #expect(AppSources.info(for: "EMCDDA") == nil)
    }

    @Test
    func `Every source URL parses`() {
        for source in AppSources.all {
            #expect(URL(string: source.url) != nil, "\(source.name)")
        }
    }

    @Test
    func `Source names are unique`() {
        let names = AppSources.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test
    func `Every slug the DB attributes maps to a named source`() throws {
        // `license(forSlug:)` and the Sources list both go through this map, so
        // a bundled slug missing from it shows an unlicensed, unnamed row.
        for slug in ["dosewiki", "freeodwiki", "psychonautwiki", "tripsit"] {
            let name = try #require(AppSources.slugToName[slug], "\(slug) has no display name")
            #expect(AppSources.info(for: name) != nil, "\(slug) names no source")
        }
    }

    @Test
    func `dose.wiki declares the license it ships under`() {
        let dosewiki = AppSources.info(for: "dose.wiki")
        #expect(dosewiki?.url == "https://dose.wiki")
        #expect(dosewiki?.license == "CC0 1.0")
    }

    @Test
    func `A dose.wiki link needs the captured slug`() {
        // Never the site root: a row labelled with a substance that opens a
        // homepage reads as a working link and hides the missing slug.
        #expect(AppSources.dosewikiURL(slug: nil) == nil)
        #expect(AppSources.dosewikiURL(slug: "") == nil)
        #expect(
            AppSources.dosewikiURL(slug: "4-meo-butyrfentanyl")?.absoluteString
                == "https://dose.wiki/4-meo-butyrfentanyl?from=piru",
        )
    }

    @Test
    func `PsychonautWiki and TripSit links use each source's own page name`() {
        // Piru's name often differs from the source's ("3-Fluoromethcathinone"
        // is TripSit's "3-fmc"), so building from it lands on a missing page.
        #expect(
            AppSources.psychonautwikiURL(page: "Bromo-DragonFLY")?.absoluteString
                == "https://psychonautwiki.org/wiki/Bromo-DragonFLY",
        )
        #expect(
            AppSources.psychonautwikiURL(page: "Choline bitartrate")?.absoluteString
                == "https://psychonautwiki.org/wiki/Choline_bitartrate",
        )
        #expect(AppSources.tripsitURL(slug: "3-fmc")?.absoluteString == "https://tripsit.me/factsheets/3-fmc")
        #expect(AppSources.psychonautwikiURL(page: nil) == nil)
        #expect(AppSources.tripsitURL(slug: "") == nil)
    }

    @Test
    func `Search queries escape characters a server reads as query syntax`() throws {
        // A bare `+` in a query string arrives as a space.
        let url = try #require(AppSources.substanceURL(for: "PubMed", substance: "BPC-157 + TB-500"))
        #expect(url.absoluteString.contains("BPC-157%20%2B%20TB-500"))
        let erowid = try #require(AppSources.erowidSearchURL(substance: "A&B=C;D"))
        #expect(erowid.absoluteString.hasSuffix("q=A%26B%3DC%3BD"))
    }
}
