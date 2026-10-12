import Foundation
import Testing
@testable import Piru

@Suite("DeepLink")
struct DeepLinkTests {
    @Test
    func `retired estimator route is unavailable`() {
        #expect(decode("piru://tool/effectSandbox") == nil)
    }

    // MARK: - Helpers

    private func decode(_ string: String) -> DeepLinkOutcome? {
        guard let url = URL(string: string) else {
            Issue.record("Invalid URL: \(string)")
            return nil
        }
        return DeepLink.decode(url)
    }

    // MARK: - Tab selection

    @Test(arguments: [
        ("piru://journal", AppTab.journal),
        ("piru://library", .library),
        ("piru://tools", .tools),
        ("piru://insights", .insights),
        ("piru://search", .search),
    ])
    func `Tab-only URLs select the right tab with no sheet`(url: String, expected: AppTab) {
        let outcome = decode(url)
        #expect(outcome?.tab == expected)
        #expect(outcome?.sheet == nil)
    }

    // MARK: - App-level sheets (preserve current tab)

    @Test
    func `piru://quicklog presents QuickLog without switching tab`() {
        let outcome = decode("piru://quicklog")
        #expect(outcome?.tab == nil) // preserves current
        #expect(outcome?.sheet == .quickLog(routine: nil))
    }

    @Test
    func `piru://quicklog?routine= carries the routine to pre-stage`() {
        let outcome = decode("piru://quicklog?routine=Pre-workout")
        #expect(outcome?.tab == nil)
        #expect(outcome?.sheet == .quickLog(routine: "Pre-workout"))
    }

    @Test
    func `a repeated query parameter keeps its first value`() {
        let outcome = decode("piru://quicklog?substance=MDMA&substance=Ketamine")
        #expect(outcome?.sheet == .quickLog(routine: nil, prefillSubstance: "MDMA"))
    }

    @Test
    func `a repeated tab override keeps its first value`() {
        let outcome = decode("piru://settings?tab=library&tab=tools")
        #expect(outcome?.tab == .library)
        #expect(outcome?.sheet == .settings)
    }

    @Test
    func `quickLog with a routine round-trips through encode`() {
        let snap = NavigatorSnapshot(selectedTab: .journal, sheetStack: [.quickLog(routine: "Night Meds")])
        let url = DeepLink.encode(snap)
        #expect(url != nil)
        let outcome = url.flatMap(DeepLink.decode)
        #expect(outcome?.sheet == .quickLog(routine: "Night Meds"))
    }

    @Test
    func `piru://quicklog?substance= carries the substance to prefill`() {
        let outcome = decode("piru://quicklog?substance=MDMA")
        #expect(outcome?.tab == nil)
        #expect(outcome?.sheet == .quickLog(routine: nil, prefillSubstance: "MDMA"))
    }

    @Test
    func `quickLog with a prefilled substance round-trips through encode`() {
        let snap = NavigatorSnapshot(
            selectedTab: .library,
            sheetStack: [.quickLog(routine: nil, prefillSubstance: "Psilocybin mushrooms")],
        )
        let url = DeepLink.encode(snap)
        #expect(url != nil)
        let outcome = url.flatMap(DeepLink.decode)
        #expect(outcome?.sheet == .quickLog(routine: nil, prefillSubstance: "Psilocybin mushrooms"))
    }

    @Test
    func `piru://settings preserves current tab`() {
        let outcome = decode("piru://settings")
        #expect(outcome?.tab == nil)
        #expect(outcome?.sheet == .settings)
    }

    @Test
    func `piru://skins opens the skins sheet`() {
        let outcome = decode("piru://skins")
        #expect(outcome?.tab == nil)
        #expect(outcome?.sheet == .skins)
    }

    @Test
    func `piru://help preserves current tab`() {
        let outcome = decode("piru://help")
        #expect(outcome?.tab == nil)
        #expect(outcome?.sheet == .help)
    }

    @Test
    func `?tab=library on an app-level sheet overrides preserve behaviour`() {
        let outcome = decode("piru://quicklog?tab=library")
        #expect(outcome?.tab == .library)
        #expect(outcome?.sheet == .quickLog(routine: nil))
    }

    // MARK: - Journal-flow sheets (default to journal tab)

    @Test
    func `piru://day lands on journal with session detail`() {
        let outcome = decode("piru://day")
        #expect(outcome?.tab == .journal)
        #expect(outcome?.sheet == .sessionDetail)
    }

    @Test
    func `piru://entry/<timestamp> lands on journal with entry detail (id-less fallback)`() {
        // Timestamp-only URLs — pre-V4 links and everything the Live Activity
        // emits — must keep decoding, with a nil id (resolved by the ±2 s
        // window downstream).
        let outcome = decode("piru://entry/1700000000")
        #expect(outcome?.tab == .journal)
        #expect(outcome?.sheet == .entryDetail(timestamp: Date(timeIntervalSince1970: 1_700_000_000), id: nil))
    }

    @Test
    func `piru://entry with an id query carries the stable id`() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000003"))
        let outcome = decode("piru://entry/1700000000?id=\(id.uuidString)")
        #expect(outcome?.sheet == .entryDetail(timestamp: Date(timeIntervalSince1970: 1_700_000_000), id: id))
    }

    @Test
    func `piru://entry with a malformed id decodes with nil id`() {
        let outcome = decode("piru://entry/1700000000?id=not-a-uuid")
        #expect(outcome?.sheet == .entryDetail(timestamp: Date(timeIntervalSince1970: 1_700_000_000), id: nil))
    }

    @Test
    func `piru://entry without a timestamp returns nil`() {
        #expect(decode("piru://entry") == nil)
    }

    @Test
    func `piru://entry with garbage returns nil`() {
        #expect(decode("piru://entry/not-a-number") == nil)
    }

    // MARK: - Medications

    @Test
    func `piru://meds/<category> presents the medication log`() {
        let outcome = decode("piru://meds/Antidepressants")
        #expect(outcome?.tab == .journal)
        #expect(outcome?.sheet == .dailyDoseLog(category: "Antidepressants"))
    }

    @Test
    func `piru://meds with no category returns nil`() {
        #expect(decode("piru://meds") == nil)
    }

    // MARK: - Tool push routes

    @Test(arguments: [
        ("piru://tool/ceiling", Tool.ceiling),
        ("piru://tool/recovery", .recovery),
        ("piru://tool/pharma", .pharma),
        ("piru://tool/calculator", .calculator),
        ("piru://tool/volumetric", .volumetric),
        ("piru://tool/interactions", .interactions),
        ("piru://tool/inventory", .inventory),
    ])
    func `piru://tool/<name> pushes the tool on the Tools tab`(url: String, expected: Tool) {
        let outcome = decode(url)
        #expect(outcome?.tab == .tools)
        #expect(outcome?.path == [.tool(expected)])
        #expect(outcome?.sheet == nil)
    }

    @Test
    func `piru://tool matches the raw value case-insensitively`() {
        // Hand-typed links shouldn't have to know the camelCase spelling.
        let outcome = decode("piru://tool/benzoequivalence")
        #expect(outcome?.path == [.tool(.benzoEquivalence)])
    }

    @Test
    func `piru://tool with an unknown name returns nil`() {
        #expect(decode("piru://tool/nonsense") == nil)
    }

    @Test
    func `piru://tool with no name returns nil`() {
        #expect(decode("piru://tool") == nil)
    }

    @Test
    func `A tool snapshot round-trips through encode → decode`() {
        let snap = NavigatorSnapshot(selectedTab: .tools, paths: [.tools: [.tool(.ceiling)]])
        let url = DeepLink.encode(snap)
        #expect(url?.absoluteString == "piru://tool/ceiling")
        let outcome = url.flatMap(DeepLink.decode)
        #expect(outcome?.path == [.tool(.ceiling)])
    }

    // MARK: - Insight push routes (Tolerance moved here from Tools, §7)

    @Test
    func `piru://insight/tolerance pushes the tolerance insight on the Insights tab`() {
        let outcome = decode("piru://insight/tolerance")
        #expect(outcome?.tab == .insights)
        #expect(outcome?.path == [.insight(.tolerance)])
    }

    @Test
    func `The old piru://tool/tolerance link still resolves to the tolerance insight (back-compat)`() {
        // Tolerance moved Tools → Insights; the legacy deep link (used for sim QA) must not break.
        let outcome = decode("piru://tool/tolerance")
        #expect(outcome?.tab == .insights)
        #expect(outcome?.path == [.insight(.tolerance)])
    }

    @Test
    func `An insight snapshot round-trips through encode → decode`() {
        let snap = NavigatorSnapshot(selectedTab: .insights, paths: [.insights: [.insight(.tolerance)]])
        let url = DeepLink.encode(snap)
        #expect(url?.absoluteString == "piru://insight/tolerance")
        let outcome = url.flatMap(DeepLink.decode)
        #expect(outcome?.path == [.insight(.tolerance)])
    }

    // MARK: - Session push routes

    @Test
    func `piru://session/<uuid> pushes session detail on the Journal tab`() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000005"))
        let outcome = decode("piru://session/\(id.uuidString)")
        #expect(outcome?.tab == .journal)
        #expect(outcome?.path == [.session(id: id)])
        #expect(outcome?.sheet == nil)
    }

    @Test
    func `piru://session with a malformed id returns nil`() {
        #expect(decode("piru://session/not-a-uuid") == nil)
    }

    @Test
    func `A session snapshot round-trips through encode → decode`() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000006"))
        let snap = NavigatorSnapshot(selectedTab: .journal, paths: [.journal: [.session(id: id)]])
        let url = DeepLink.encode(snap)
        #expect(url?.absoluteString == "piru://session/\(id.uuidString)")
        let outcome = url.flatMap(DeepLink.decode)
        #expect(outcome?.path == [.session(id: id)])
    }

    // MARK: - Quick log route

    @Test
    func `piru://quicklog?route= stages the substance on that route`() {
        let outcome = decode("piru://quicklog?substance=MDMA&route=insufflated")
        #expect(outcome?.sheet == .quickLog(routine: nil, prefillSubstance: "MDMA", prefillRoute: .insufflation))
    }

    @Test
    func `an unknown quick-log route falls back to the substance's default`() {
        let outcome = decode("piru://quicklog?substance=MDMA&route=ocular")
        #expect(outcome?.sheet == .quickLog(routine: nil, prefillSubstance: "MDMA"))
    }

    @Test
    func `piru://quicklog reads dotted route abbreviations`() {
        #expect(decode("piru://quicklog?substance=Testosterone&route=i.m.")?.sheet
            == .quickLog(routine: nil, prefillSubstance: "Testosterone", prefillRoute: .intramuscular))
    }

    @Test
    func `quickLog with a route round-trips through encode`() {
        let snap = NavigatorSnapshot(
            selectedTab: .journal,
            sheetStack: [.quickLog(routine: nil, prefillSubstance: "MDMA", prefillRoute: .oral)],
        )
        let url = DeepLink.encode(snap)
        #expect(url?.absoluteString == "piru://quicklog?substance=MDMA&route=oral")
        #expect(url.flatMap(DeepLink.decode)?.sheet == .quickLog(routine: nil, prefillSubstance: "MDMA", prefillRoute: .oral))
    }

    // MARK: - Web links (kagerou.glass, from dose.wiki)

    private func webLink(_ string: String) -> DosewikiLink? {
        guard let url = URL(string: string) else {
            Issue.record("Invalid URL: \(string)")
            return nil
        }
        return DeepLink.decodeWebLink(url)
    }

    @Test
    func `the log link carries the dose.wiki slug and route`() {
        let link = webLink("https://kagerou.glass/piru/log?substance=psilocybin-mushrooms&route=oral&from=dosewiki")
        #expect(link == DosewikiLink(action: .log, slug: "psilocybin-mushrooms", route: .oral))
    }

    @Test
    func `a resolved log link lands where the matching piru link does`() {
        let link = webLink("https://kagerou.glass/piru/log?substance=mdma&route=smoked")
        #expect(link?.outcome(substanceName: "MDMA") == decode("piru://quicklog?substance=MDMA&route=smoked"))
    }

    @Test
    func `a log link whose slug names nothing still opens Quick Log, empty`() {
        let empty = DeepLinkOutcome(sheet: .quickLog(routine: nil))
        #expect(webLink("https://kagerou.glass/piru/log?substance=not-a-substance&route=oral")?.outcome(substanceName: nil) == empty)
        #expect(webLink("https://kagerou.glass/piru/log")?.outcome(substanceName: nil) == empty)
    }

    @Test
    func `the open link lands where piru://substance does`() {
        let link = webLink("https://kagerou.glass/piru/open?substance=mdma")
        #expect(link == DosewikiLink(action: .open, slug: "mdma", route: nil))
        #expect(link?.outcome(substanceName: "MDMA") == decode("piru://substance/MDMA"))
        #expect(link?.outcome(substanceName: nil) == nil)
    }

    @Test
    func `the host and path match case-insensitively`() {
        let link = webLink("https://Kagerou.Glass/Piru/Log?substance=mdma")
        #expect(link == DosewikiLink(action: .log, slug: "mdma", route: nil))
    }

    @Test
    func `the log link reads dose.wiki's i.m. route tab`() {
        let link = webLink("https://kagerou.glass/piru/log?substance=testosterone-cypionate&route=i.m.")
        #expect(link == DosewikiLink(action: .log, slug: "testosterone-cypionate", route: .intramuscular))
    }

    /// dose.wiki route tabs that name no single route: the link stages the
    /// substance on its default route rather than as "Other".
    @Test(arguments: ["injection", "iv%2Fim", "oral%20%26%20intranasal", "medical", "non-medical", "nonmedical", "ocular"])
    func `a log link with a route Piru does not know stages no route`(route: String) {
        let link = webLink("https://kagerou.glass/piru/log?substance=mdma&route=\(route)")
        #expect(link == DosewikiLink(action: .log, slug: "mdma", route: nil))
        #expect(link?.outcome(substanceName: "MDMA")?.sheet == .quickLog(routine: nil, prefillSubstance: "MDMA"))
    }

    @Test
    func `a repeated substance parameter keeps its first value`() {
        let link = webLink("https://kagerou.glass/piru/log?substance=mdma&substance=ketamine&route=oral&route=smoked")
        #expect(link == DosewikiLink(action: .log, slug: "mdma", route: .oral))
    }

    @Test
    func `an empty substance parameter names no substance`() {
        #expect(webLink("https://kagerou.glass/piru/log?substance=&route=oral") == DosewikiLink(action: .log, slug: nil, route: .oral))
        #expect(webLink("https://kagerou.glass/piru/log?substance=%20") == DosewikiLink(action: .log, slug: nil, route: nil))
        #expect(webLink("https://kagerou.glass/piru/open?substance=") == nil)
    }

    @Test
    func `a trailing slash after the action is the same link`() {
        #expect(webLink("https://kagerou.glass/piru/log/?substance=mdma") == DosewikiLink(action: .log, slug: "mdma", route: nil))
        #expect(webLink("https://kagerou.glass/piru/open/?substance=mdma") == DosewikiLink(action: .open, slug: "mdma", route: nil))
    }

    @Test(arguments: [
        "https://kagerou.glass/piru/other?x=1",
        "https://kagerou.glass/piru/logs?substance=mdma",
        "https://kagerou.glass/piru/log/extra?substance=mdma",
        "https://kagerou.glass/piru/",
        "https://kagerou.glass/piru/open",
        "https://kagerou.glass/get/piru/android",
        "http://kagerou.glass/piru/log?substance=mdma",
        "https://dose.wiki/piru/log?substance=mdma",
        "https://example.kagerou.glass/piru/log?substance=mdma",
        "piru://quicklog?substance=MDMA",
    ])
    func `any other link is not a web link`(url: String) {
        #expect(webLink(url) == nil)
    }

    @Test
    func `a web link is not a piru link`() {
        #expect(decode("https://kagerou.glass/piru/log?substance=mdma") == nil)
    }

    // MARK: - Substance push routes

    @Test
    func `piru://substance/<name> pushes substance detail on the Library tab`() {
        let outcome = decode("piru://substance/Amphetamine")
        #expect(outcome?.tab == .library)
        #expect(outcome?.path == [.substance(name: "Amphetamine")])
    }

    @Test
    func `piru://substance decodes a percent-encoded multi-word name`() {
        let outcome = decode("piru://substance/Psilocybin%20mushrooms")
        #expect(outcome?.path == [.substance(name: "Psilocybin mushrooms")])
    }

    @Test
    func `A substance snapshot round-trips through encode → decode`() {
        let snap = NavigatorSnapshot(selectedTab: .library, paths: [.library: [.substance(name: "MDMA")]])
        let url = DeepLink.encode(snap)
        #expect(url?.absoluteString == "piru://substance/MDMA")
        #expect(url.flatMap(DeepLink.decode)?.path == [.substance(name: "MDMA")])
    }

    @Test(arguments: [
        ("piru://substance/MDMA/data/chemistry", "MDMA", DataSection.chemistry),
        ("piru://substance/MDMA/data/pharmacology", "MDMA", .pharmacology),
        ("piru://substance/MDMA/data/sources", "MDMA", .sources),
    ])
    func `piru://substance/<name>/data/<section> pushes the deep-data page`(
        url: String, name: String, section: DataSection,
    ) {
        let outcome = decode(url)
        #expect(outcome?.tab == .library)
        #expect(outcome?.path == [.substanceData(name: name, section: section)])
    }

    @Test
    func `A deep-data section resolves the name even when it is multi-word`() {
        let outcome = decode("piru://substance/Psilocybin%20mushrooms/data/chemistry")
        #expect(outcome?.path == [.substanceData(name: "Psilocybin mushrooms", section: .chemistry)])
    }

    @Test
    func `An unknown data section falls back to the plain substance detail`() {
        // A bogus section shouldn't 404 the whole link — it opens the detail,
        // and never folds "data/<typo>" into the substance name.
        let outcome = decode("piru://substance/MDMA/data/nonsense")
        #expect(outcome?.path == [.substance(name: "MDMA")])
    }

    @Test
    func `A deep-data snapshot round-trips through encode → decode`() {
        let snap = NavigatorSnapshot(
            selectedTab: .library,
            paths: [.library: [.substanceData(name: "MDMA", section: .pharmacology)]],
        )
        let url = DeepLink.encode(snap)
        #expect(url?.absoluteString == "piru://substance/MDMA/data/pharmacology")
        #expect(
            url.flatMap(DeepLink.decode)?.path == [.substanceData(name: "MDMA", section: .pharmacology)],
        )
    }

    @MainActor
    @Test
    func `Applying a tool outcome replaces the Tools push stack`() {
        let nav = AppNavigator(selectedTab: .journal, storage: makeIsolatedDefaults(), layout: TabLayoutStore(defaults: makeIsolatedDefaults()))
        nav.apply(DeepLinkOutcome(tab: .tools, path: [.tool(.ceiling)]))
        #expect(nav.selectedTab == .tools)
        #expect(nav.path(for: .tools) == [.tool(.ceiling)])
    }

    // MARK: - Unsupported URLs

    @Test
    func `Unknown scheme returns nil`() {
        #expect(decode("https://example.com/foo") == nil)
    }

    @Test
    func `Unknown host returns nil`() {
        #expect(decode("piru://nonsense") == nil)
    }

    @Test
    func `URL with no host returns nil`() {
        #expect(decode("piru://") == nil)
    }

    // MARK: - Applying outcomes preserves unrelated state

    @MainActor
    @Test
    func `Applying a sheet-only outcome does not change the selected tab`() {
        let nav = AppNavigator(selectedTab: .library, storage: makeIsolatedDefaults(), layout: TabLayoutStore(defaults: makeIsolatedDefaults()))
        nav.apply(DeepLinkOutcome(tab: nil, sheet: .quickLog(routine: nil)))
        #expect(nav.selectedTab == .library)
        #expect(nav.sheetStack == [.quickLog(routine: nil)])
    }

    @MainActor
    @Test
    func `Applying a tab-only outcome does not present a sheet`() {
        let nav = AppNavigator(selectedTab: .journal, storage: makeIsolatedDefaults(), layout: TabLayoutStore(defaults: makeIsolatedDefaults()))
        nav.apply(DeepLinkOutcome(tab: .insights, sheet: nil))
        #expect(nav.selectedTab == .insights)
        #expect(nav.sheetStack.isEmpty)
    }

    @MainActor
    @Test
    func `Applying a tab+sheet outcome sets both`() {
        let nav = AppNavigator(selectedTab: .library, storage: makeIsolatedDefaults(), layout: TabLayoutStore(defaults: makeIsolatedDefaults()))
        nav.apply(DeepLinkOutcome(tab: .journal, sheet: .sessionDetail))
        #expect(nav.selectedTab == .journal)
        #expect(nav.sheetStack == [.sessionDetail])
    }

    // MARK: - Encoding (snapshot → URL)

    @Test
    func `Encoding a tab-only snapshot produces piru://<tab>`() {
        let snap = NavigatorSnapshot(selectedTab: .library)
        let url = DeepLink.encode(snap)
        #expect(url?.absoluteString == "piru://library")
    }

    @Test
    func `Encoding a quicklog sheet snapshot`() {
        let snap = NavigatorSnapshot(selectedTab: .journal, sheetStack: [.quickLog(routine: nil)])
        #expect(DeepLink.encode(snap)?.absoluteString == "piru://quicklog")
    }

    @Test
    func `Encoding an id-less entry detail snapshot`() {
        let ts = Date(timeIntervalSince1970: 1_700_000_500)
        let snap = NavigatorSnapshot(selectedTab: .journal, sheetStack: [.entryDetail(timestamp: ts, id: nil)])
        let url = DeepLink.encode(snap)
        #expect(url?.absoluteString == "piru://entry/1700000500.0")
    }

    @Test
    func `Encoding an entry detail snapshot carries the id and round-trips`() throws {
        let ts = Date(timeIntervalSince1970: 1_700_000_500)
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000004"))
        let snap = NavigatorSnapshot(selectedTab: .journal, sheetStack: [.entryDetail(timestamp: ts, id: id)])
        let url = try #require(DeepLink.encode(snap))
        #expect(url.absoluteString == "piru://entry/1700000500.0?id=\(id.uuidString)")
        let outcome = DeepLink.decode(url)
        #expect(outcome?.sheet == .entryDetail(timestamp: ts, id: id))
    }

    @Test
    func `Encoding a non-default tab adds a tab query param`() {
        let snap = NavigatorSnapshot(selectedTab: .library, sheetStack: [.quickLog(routine: nil)])
        let url = DeepLink.encode(snap)
        #expect(url?.absoluteString.contains("tab=library") == true)
    }

    @Test
    func `Encoding an unrepresentable sheet returns nil`() {
        let snap = NavigatorSnapshot(
            selectedTab: .journal,
            sheetStack: [.timeAdjust(entryTimestamp: Date(timeIntervalSince1970: 300))],
        )
        #expect(DeepLink.encode(snap) == nil)
    }

    // MARK: - Round-trip (encode → decode produces matching outcome)

    @Test
    func `Encode → decode produces an outcome that reflects the snapshot`() {
        let snap = NavigatorSnapshot(selectedTab: .insights)
        guard let url = DeepLink.encode(snap), let outcome = DeepLink.decode(url) else {
            Issue.record("Expected encode+decode to succeed")
            return
        }
        #expect(outcome.tab == .insights)
        #expect(outcome.sheet == nil)
    }

    @Test
    func `Round trip through a journal-flow sheet preserves the sheet and tab`() {
        let snap = NavigatorSnapshot(selectedTab: .journal, sheetStack: [.sessionDetail])
        guard let url = DeepLink.encode(snap), let outcome = DeepLink.decode(url) else {
            Issue.record("Expected encode+decode to succeed")
            return
        }
        #expect(outcome.tab == .journal)
        #expect(outcome.sheet == .sessionDetail)
    }

    @Test
    func `Round trip through an app-level sheet preserves the sheet (and honors tab override)`() {
        let snap = NavigatorSnapshot(selectedTab: .library, sheetStack: [.quickLog(routine: nil)])
        guard let url = DeepLink.encode(snap), let outcome = DeepLink.decode(url) else {
            Issue.record("Expected encode+decode to succeed")
            return
        }
        #expect(outcome.tab == .library)
        #expect(outcome.sheet == .quickLog(routine: nil))
    }

    // MARK: - Inventory deep links (restock action)

    @Test
    func `piru://inventory/<uuid> opens the inventory item form on the Tools tab`() {
        let id = UUID()
        let outcome = decode("piru://inventory/\(id.uuidString)")
        #expect(outcome?.tab == .tools)
        #expect(outcome?.sheet == .inventoryItemForm(id: id))
    }

    @Test
    func `piru://inventory with no id opens a new inventory item form`() {
        let outcome = decode("piru://inventory")
        #expect(outcome?.tab == .tools)
        #expect(outcome?.sheet == .inventoryItemForm(id: nil))
    }

    @Test
    func `piru://inventory with a malformed UUID returns nil`() {
        #expect(decode("piru://inventory/not-a-uuid") == nil)
    }

    @Test
    func `Inventory item form round-trips through encode → decode`() {
        let id = UUID()
        let snap = NavigatorSnapshot(
            selectedTab: .tools,
            sheetStack: [.inventoryItemForm(id: id)],
        )
        guard let url = DeepLink.encode(snap), let outcome = DeepLink.decode(url) else {
            Issue.record("Expected encode+decode to succeed")
            return
        }
        #expect(outcome.tab == .tools)
        #expect(outcome.sheet == .inventoryItemForm(id: id))
    }

    @Test
    func `Inventory item form with prefill encodes to nil`() {
        let snap = NavigatorSnapshot(
            selectedTab: .tools,
            sheetStack: [.inventoryItemForm(id: nil, prefillSubstance: "Adderall")],
        )
        #expect(DeepLink.encode(snap) == nil)
    }
}

// MARK: - Helpers

@MainActor
private func makeIsolatedDefaults() -> UserDefaults {
    let suite = "DeepLinkTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}
