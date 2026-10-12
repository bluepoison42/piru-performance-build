import Foundation
import Testing
@testable import Piru

/// A My Meds pill toggles: the first tap stages its meds, a tap on the staged
/// pill takes back exactly what that tap staged and nothing anyone else added.
@MainActor
@Suite("My Meds pill toggle")
struct MedPillToggleTests {
    private let pill = "morning"

    private func med(_ substance: String, amount: Double = 50, sortOrder: Int = 0) -> DailyMedSnapshot {
        DailyMedSnapshot(DailyDoseItem(substance: substance, amount: amount, unit: "mg", sortOrder: sortOrder, reminderTimesMinutes: [480]))
    }

    private var routine: [DailyMedSnapshot] {
        [med("Sertraline"), med("Melatonin", amount: 3, sortOrder: 1)]
    }

    private func units(_ tray: DoseTrayModel, _ substance: String) -> Int {
        tray.staged
            .filter { $0.substanceName == substance }
            .flatMap(\.components)
            .reduce(0) { $0 + $1.count }
    }

    @Test
    func `Stage then unstage leaves the tray empty`() {
        let tray = DoseTrayModel()
        tray.togglePill(pill, meds: routine, colorLookup: [:])
        #expect(tray.staged.count == 2)
        #expect(tray.isPillStaged(pill))

        tray.togglePill(pill, meds: routine, colorLookup: [:])
        #expect(tray.staged.isEmpty)
        #expect(tray.isEmpty)
        #expect(!tray.isPillStaged(pill))
    }

    @Test
    func `Unstaging keeps another substance staged after the pill`() {
        let tray = DoseTrayModel()
        tray.togglePill(pill, meds: routine, colorLookup: [:])
        tray.stage(substance: "Caffeine", route: .oral, amount: 100, unit: "mg", tint: nil, librarySubstance: nil)

        tray.togglePill(pill, meds: routine, colorLookup: [:])
        #expect(tray.staged.map(\.substanceName) == ["Caffeine"])
        #expect(units(tray, "Caffeine") == 1)
        #expect(!tray.isEmpty)
    }

    @Test
    func `Unstaging leaves an extra unit of a pill med in the tray`() {
        let tray = DoseTrayModel()
        tray.togglePill(pill, meds: routine, colorLookup: [:])
        // A second Sertraline from the chip — the same row, one more unit.
        tray.stage(dailyMed: routine[0], colorLookup: [:])
        #expect(units(tray, "Sertraline") == 2)
        // The pill's whole contribution is still there, so it still reads staged.
        #expect(tray.isPillStaged(pill))

        tray.togglePill(pill, meds: routine, colorLookup: [:])
        #expect(units(tray, "Sertraline") == 1)
        #expect(units(tray, "Melatonin") == 0)
        #expect(tray.staged.count == 1)
    }

    @Test
    func `A med removed by hand is never subtracted below zero`() throws {
        let tray = DoseTrayModel()
        tray.togglePill(pill, meds: routine, colorLookup: [:])
        let melatonin = try #require(tray.staged.first { $0.substanceName == "Melatonin" })
        tray.remove(melatonin)
        // Part of its contribution is gone: the pill reads unstaged.
        #expect(!tray.isPillStaged(pill))

        tray.unstagePill(pill)
        #expect(tray.staged.isEmpty)
        #expect(tray.isEmpty)
    }

    @Test
    func `A partly removed pill restages only what is missing, then unstages all of it`() throws {
        let tray = DoseTrayModel()
        tray.togglePill(pill, meds: routine, colorLookup: [:])
        let melatonin = try #require(tray.staged.first { $0.substanceName == "Melatonin" })
        tray.remove(melatonin)

        tray.togglePill(pill, meds: routine, colorLookup: [:])
        #expect(units(tray, "Sertraline") == 1)
        #expect(units(tray, "Melatonin") == 1)
        #expect(tray.isPillStaged(pill))

        tray.togglePill(pill, meds: routine, colorLookup: [:])
        #expect(tray.staged.isEmpty)
    }

    @Test
    func `A pill never stages a med another pill already put in the tray`() {
        let tray = DoseTrayModel()
        let shared = med("Sertraline")
        tray.togglePill("morning", meds: [shared, med("Melatonin", amount: 3)], colorLookup: [:])
        tray.togglePill("evening", meds: [shared, med("Magnesium", amount: 200)], colorLookup: [:])
        #expect(units(tray, "Sertraline") == 1)

        // Evening takes back only its own Magnesium; Morning's Sertraline stays.
        tray.togglePill("evening", meds: [shared, med("Magnesium", amount: 200)], colorLookup: [:])
        #expect(units(tray, "Magnesium") == 0)
        #expect(units(tray, "Sertraline") == 1)
        #expect(tray.isPillStaged("morning"))
    }
}
