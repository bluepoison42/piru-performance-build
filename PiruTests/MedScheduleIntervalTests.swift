import Foundation
import Testing
@testable import Piru

@Suite("MedSchedule every-N-days")
struct MedScheduleIntervalTests {
    private var start: Date {
        Calendar.current.startOfDay(for: .now)
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: start)!
    }

    private func isDue(_ frequency: DoseFrequency, interval: Int, on offset: Int) -> Bool {
        MedSchedule.isDue(
            startDate: start, frequency: frequency, frequencyDays: [], intervalDays: interval, on: day(offset),
        )
    }

    @Test(arguments: [0, 5, 10, 35])
    func `Every 5 days is due on multiples of 5 from the start`(offset: Int) {
        #expect(isDue(.everyNDays, interval: 5, on: offset))
    }

    @Test(arguments: [1, 2, 3, 4, 6, 9, 11])
    func `Every 5 days is not due between doses`(offset: Int) {
        #expect(!isDue(.everyNDays, interval: 5, on: offset))
    }

    @Test
    func `Not due before the start date`() {
        #expect(!isDue(.everyNDays, interval: 5, on: -5))
    }

    @Test
    func `The interval clamps to the offered range`() {
        // 1 (or less) clamps to 2, never collapsing into a daily schedule.
        #expect(isDue(.everyNDays, interval: 1, on: 2))
        #expect(!isDue(.everyNDays, interval: 0, on: 1))
        // Past the ceiling clamps to 90.
        #expect(isDue(.everyNDays, interval: 500, on: 90))
        #expect(!isDue(.everyNDays, interval: 500, on: 100))
    }

    @Test
    func `The fixed cadences ignore the item's interval`() {
        #expect(isDue(.everyOtherDay, interval: 9, on: 2))
        #expect(!isDue(.everyOtherDay, interval: 9, on: 9))
        #expect(isDue(.weekly, interval: 3, on: 7))
        #expect(!isDue(.weekly, interval: 3, on: 3))
        #expect(isDue(.biweekly, interval: 5, on: 14))
        #expect(!isDue(.biweekly, interval: 5, on: 7))
        #expect(isDue(.daily, interval: 5, on: 1))
    }

    @Test
    func `A stored item carries its interval through the adherence entry point`() {
        let item = DailyDoseItem(
            substance: "Testosterone cypionate", amount: 50, unit: "mg", route: .intramuscular,
            frequency: .everyNDays, frequencyIntervalDays: 5, startDate: start,
        )
        #expect(AdherenceCalculator.isDue(item, on: day(5)))
        #expect(!AdherenceCalculator.isDue(item, on: day(4)))
        #expect(item.frequencyShortLabel == String(localized: "Every \(5) days"))
    }

    @Test
    func `An unknown stored cadence reads as daily`() {
        let item = DailyDoseItem(substance: "X", amount: 1)
        item.frequencyRaw = "everyFortnightOnTuesdays"
        #expect(item.frequency == .daily)
    }
}
