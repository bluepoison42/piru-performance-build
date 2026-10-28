import Foundation
import SwiftData
import Testing
@testable import Piru

@Suite("Injection site rotation")
struct InjectionSiteTests {
    @Test("The next site is the other side of the last area")
    func alternatesSides() {
        let left = InjectionSite(area: .thigh, side: .left)
        #expect(InjectionSite.suggestedNext(after: left, route: .intramuscular) == InjectionSite(area: .thigh, side: .right))
        let right = InjectionSite(area: .abdomen, side: .right)
        #expect(InjectionSite.suggestedNext(after: right, route: .subcutaneous) == InjectionSite(area: .abdomen, side: .left))
    }

    @Test("Nothing is suggested before a site has been logged")
    func noHistory() {
        #expect(InjectionSite.suggestedNext(after: nil, route: .intramuscular) == nil)
    }

    @Test("An area the route doesn't offer suggests nothing")
    func areaNotOffered() {
        let abdomen = InjectionSite(area: .abdomen, side: .left)
        #expect(InjectionSite.suggestedNext(after: abdomen, route: .intramuscular) == nil)
        let hip = InjectionSite(area: .ventrogluteal, side: .right)
        #expect(InjectionSite.suggestedNext(after: hip, route: .subcutaneous) == nil)
    }

    @Test("Only intramuscular and subcutaneous doses take a site")
    func appliesToRoutes() {
        #expect(InjectionSite.applies(to: .intramuscular))
        #expect(InjectionSite.applies(to: .subcutaneous))
        #expect(!InjectionSite.applies(to: .intravenous))
        #expect(!InjectionSite.applies(to: .oral))
    }

    @Test("The raw value round-trips and an unknown one reads as nil")
    func rawValue() {
        for area in InjectionSite.Area.allCases {
            for side in InjectionSite.Side.allCases {
                let site = InjectionSite(area: area, side: side)
                #expect(InjectionSite(rawValue: site.rawValue) == site)
            }
        }
        #expect(InjectionSite(rawValue: "thigh.left") == InjectionSite(area: .thigh, side: .left))
        #expect(InjectionSite(rawValue: "ankle.left") == nil)
        #expect(InjectionSite(rawValue: "thigh") == nil)
        let entry = DoseEntry(substance: "X", amount: 1, route: .intramuscular)
        entry.injectionSiteRaw = "elbow.middle"
        #expect(entry.injectionSite == nil)
    }

    @MainActor
    @Test("History suggests from the newest dose of the same substance that has a site")
    func historySuggestion() throws {
        let container = try ModelContainer(
            for: Schema(PiruSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        )
        let context = container.mainContext
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(DoseEntry(
            substance: "Testosterone", amount: 50, route: .intramuscular, timestamp: t0,
            injectionSite: InjectionSite(area: .glute, side: .right),
        ))
        context.insert(DoseEntry(
            substance: "Testosterone", amount: 50, route: .intramuscular, timestamp: t0.addingTimeInterval(86_400),
            injectionSite: InjectionSite(area: .thigh, side: .left),
        ))
        // Newer, but no site: skipped.
        context.insert(DoseEntry(
            substance: "Testosterone", amount: 50, route: .intramuscular, timestamp: t0.addingTimeInterval(2 * 86_400),
        ))
        // Another substance's site never leaks in.
        context.insert(DoseEntry(
            substance: "Semaglutide", amount: 0.25, route: .subcutaneous, timestamp: t0.addingTimeInterval(3 * 86_400),
            injectionSite: InjectionSite(area: .abdomen, side: .left),
        ))
        try context.save()

        #expect(InjectionSiteHistory.lastSite(substance: "Testosterone", in: context) == InjectionSite(area: .thigh, side: .left))
        #expect(
            InjectionSiteHistory.suggestedNext(substance: "Testosterone", route: .intramuscular, in: context)
                == InjectionSite(area: .thigh, side: .right),
        )
        #expect(InjectionSiteHistory.suggestedNext(substance: "Testosterone", route: .oral, in: context) == nil)
        #expect(InjectionSiteHistory.suggestedNext(substance: "Estradiol", route: .intramuscular, in: context) == nil)
    }
}
