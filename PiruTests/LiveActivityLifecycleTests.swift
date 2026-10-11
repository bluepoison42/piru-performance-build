#if os(iOS)
    import Foundation
    import Testing
    @testable import Piru

    /// When a Live Activity comes off the Lock Screen, and when its card
    /// collapses to "Session complete" without the app running.
    ///
    /// An `Activity` can't be fabricated in a test process, so these cover the
    /// two pure halves: the decision table every wake applies to the activities
    /// ActivityKit lists, and the stale date that schedules the one repaint iOS
    /// performs on its own.
    @MainActor
    @Suite("LiveActivityManager — lifecycle")
    struct LiveActivityLifecycleTests {
        private typealias Manager = LiveActivityManager

        // MARK: - Disposition

        @Test
        func `A held running activity whose doses ran out, with no session in memory, ends`() {
            let disposition = Manager.disposition(
                lifecycle: .running, isHeld: true, contentHasRunOut: true,
                sessionIsEmpty: true, canReplace: false,
            )
            #expect(disposition == .end)
        }

        @Test
        func `A held running activity with live content waits for session recovery`() {
            let disposition = Manager.disposition(
                lifecycle: .running, isHeld: true, contentHasRunOut: false,
                sessionIsEmpty: true, canReplace: true,
            )
            #expect(disposition == .keep)
        }

        @Test
        func `A held running activity is kept while the session has doses`() {
            let disposition = Manager.disposition(
                lifecycle: .running, isHeld: true, contentHasRunOut: true,
                sessionIsEmpty: false, canReplace: true,
            )
            #expect(disposition == .keep)
        }

        @Test
        func `A running activity the manager doesn't hold is a leftover and ends`() {
            let disposition = Manager.disposition(
                lifecycle: .running, isHeld: false, contentHasRunOut: false,
                sessionIsEmpty: false, canReplace: true,
            )
            #expect(disposition == .end)
        }

        @Test
        func `An activity capped mid-session is replaced in the foreground, kept in the background`() {
            let foreground = Manager.disposition(
                lifecycle: .ended, isHeld: true, contentHasRunOut: false,
                sessionIsEmpty: false, canReplace: true,
            )
            let background = Manager.disposition(
                lifecycle: .ended, isHeld: true, contentHasRunOut: false,
                sessionIsEmpty: false, canReplace: false,
            )
            #expect(foreground == .replace)
            #expect(background == .keep)
        }

        @Test
        func `An ended activity with nothing left to show comes off the screen`() {
            for isHeld in [true, false] {
                let disposition = Manager.disposition(
                    lifecycle: .ended, isHeld: isHeld, contentHasRunOut: true,
                    sessionIsEmpty: false, canReplace: true,
                )
                #expect(disposition == .end)
            }
        }

        @Test
        func `An ended activity the manager doesn't hold is never replaced`() {
            let disposition = Manager.disposition(
                lifecycle: .ended, isHeld: false, contentHasRunOut: false,
                sessionIsEmpty: false, canReplace: true,
            )
            #expect(disposition == .end)
        }

        @Test
        func `A held activity the user dismissed is released, never ended or replaced`() {
            let held = Manager.disposition(
                lifecycle: .dismissed, isHeld: true, contentHasRunOut: false,
                sessionIsEmpty: false, canReplace: true,
            )
            let other = Manager.disposition(
                lifecycle: .dismissed, isHeld: false, contentHasRunOut: false,
                sessionIsEmpty: false, canReplace: true,
            )
            #expect(held == .release)
            #expect(other == .keep)
        }

        // MARK: - Stale date

        private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        /// One dose `minutesAgo` before ``now`` with boundaries at 10/40/120 min
        /// and its curve ending at `totalMinutes`.
        private func state(minutesAgo: Double, totalMinutes: Double = 240) -> PiruActivityAttributes.ContentState {
            let substance = ActiveSubstanceState(
                substanceName: "Caffeine",
                tint: P3Color(red: 0.5, green: 0.8, blue: 1),
                doseTimestamp: now.addingTimeInterval(-minutesAgo * 60),
                amount: 100,
                unit: "mg",
                route: "oral",
                onsetEndMinutes: 10,
                comeupEndMinutes: 40,
                peakEndMinutes: 120,
                offsetEndMinutes: totalMinutes,
                afterglowEndMinutes: nil,
                totalMinutes: totalMinutes,
            )
            return PiruActivityAttributes.ContentState(activeSubstances: [substance], lastUpdated: now)
        }

        @Test
        func `Stale lands just past the next phase boundary`() throws {
            // Dosed 20 min ago: the next boundary is come-up's end at +20 min.
            let stale = try #require(Manager.staleDate(for: state(minutesAgo: 20), now: now))
            #expect(stale == now.addingTimeInterval(20 * 60 + Manager.boundaryRepaintLag))
        }

        @Test
        func `In the last phase, stale lands just past the curve's end, where the card collapses`() throws {
            // Dosed 230 min ago with a 240 min curve: the end is 10 min out.
            let content = state(minutesAgo: 230)
            let stale = try #require(Manager.staleDate(for: content, now: now))
            let end = try #require(content.endDate)
            #expect(stale == end.addingTimeInterval(Manager.boundaryRepaintLag))
            #expect(content.hasRunOut(at: stale))
            #expect(!content.hasRunOut(at: now))
        }

        @Test
        func `The end is never pushed back by the minimum repaint interval`() throws {
            // The end is 20 s out, inside the 60 s floor; the collapse still lands there.
            let content = state(minutesAgo: 240 - 20.0 / 60)
            let stale = try #require(Manager.staleDate(for: content, now: now))
            #expect(stale < now.addingTimeInterval(Manager.minimumStale))
            #expect(content.hasRunOut(at: stale))
        }

        @Test
        func `A long quiet phase still goes stale within the ceiling`() throws {
            // Dosed 130 min ago with a 600 min curve: the next boundary is 470 min out.
            let stale = try #require(Manager.staleDate(for: state(minutesAgo: 130, totalMinutes: 600), now: now))
            #expect(stale == now.addingTimeInterval(Manager.maximumStale))
        }

        @Test
        func `An empty state has run out and sets no stale date`() {
            let empty = PiruActivityAttributes.ContentState(activeSubstances: [], lastUpdated: now)
            #expect(empty.hasRunOut(at: now))
            #expect(Manager.staleDate(for: empty, now: now) == nil)
        }
    }
#endif
