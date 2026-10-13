import Foundation
import Testing
@testable import Piru

/// `Substance.modelsBodyLoad` is the one gate behind every body-load surface:
/// the remaining-% badge, In Your System, Body Levels, the summary's
/// co-exposure pass and the timeline's body-load curves. A supplement with an
/// acute effect profile qualifies; one without stays out. The motivating case:
/// melatonin drew an effect curve on its entry page and nothing at all on the
/// body-load timeline.
@Suite("Body-load eligibility")
@MainActor
struct BodyLoadEligibilityTests {
    private func substance(_ name: String) async throws -> Substance {
        await SubstanceStore.shared.ensureAllLoaded()
        return try #require(SubstanceLibrary.lookup(name))
    }

    @Test
    func `A supplement with an acute profile has a body load`() async throws {
        let melatonin = try await substance("Melatonin")
        #expect(melatonin.category == .supplement)
        #expect(melatonin.timelineDuration(for: .sublingual) != nil)
        #expect(melatonin.modelsBodyLoad)
    }

    @Test
    func `A vitamin with no acute profile has none`() async throws {
        let vitamin = try await substance("Vitamin D3")
        #expect(vitamin.category == .supplement)
        #expect(!vitamin.modelsBodyLoad)
    }

    @Test
    func `A vitamin with an acute duration row still draws nothing`() async throws {
        let vitaminC = try await substance("Vitamin C")
        #expect(vitaminC.isVitaminOrMineral)
        #expect(vitaminC.timelineDuration(for: .oral) == nil)
        #expect(!vitaminC.modelsBodyLoad)
        #expect(try await !substance("Magnesium").modelsBodyLoad)
    }

    @Test
    func `Every other class qualifies whatever its data`() async throws {
        #expect(try await substance("Caffeine").modelsBodyLoad)
    }

    @Test
    func `The body-load timeline resolves rate constants for melatonin`() async throws {
        _ = try await substance("Melatonin")
        #expect(TimelineActivity.resolvePKConstants(key: "melatonin", name: "Melatonin") != nil)
        #expect(TimelineActivity.resolvePKConstants(key: "vitamin d3", name: "Vitamin D3") == nil)
    }
}
