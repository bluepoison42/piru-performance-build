import Foundation
import SwiftData
import Testing
@testable import Piru

/// A session's check-ins following its doses: starting on their own when
/// Settings asks for every session, recomputing from every dose when a new one
/// lands, and leaving alone both the times someone chose and the prompts that
/// have already gone.
@MainActor
@Suite("CheckInScheduler follows the doses")
struct CheckInFollowTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema(PiruSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        )
        return ModelContext(container)
    }

    private func lsd(at date: Date) -> DoseEntry {
        DoseEntry(substance: "LSD", amount: 100, unit: "µg", route: .sublingual, timestamp: date)
    }

    private func methylphenidate(at date: Date) -> DoseEntry {
        DoseEntry(substance: "Methylphenidate", amount: 20, unit: "mg", route: .oral, timestamp: date)
    }

    /// A session holding `doses`, bounds refreshed the way `assignSession` leaves them.
    private func session(_ doses: [DoseEntry], in context: ModelContext) throws -> Session {
        let session = Session(startDate: doses.map(\.timestamp).min() ?? t0)
        context.insert(session)
        for dose in doses {
            add(dose, to: session, in: context)
        }
        try context.save()
        return session
    }

    private func add(_ dose: DoseEntry, to session: Session, in context: ModelContext) {
        context.insert(dose)
        dose.session = session
        session.refreshDoseBounds()
    }

    /// The session's prompts as wall-clock times, which is what a person
    /// actually receives; offsets alone move whenever the anchor does.
    private func times(of session: Session) -> [Date] {
        let anchor = CheckInScheduler.anchor(for: session)
        return session.checkInOffsetMinutes.map { anchor.addingTimeInterval(Double($0) * 60) }
    }

    private func requireFixtures() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let lsd = try #require(SubstanceLibrary.lookup("LSD"))
        #expect(CheckInScheduler.offerableCategories.contains(lsd.category))
        let mph = try #require(SubstanceLibrary.lookup("Methylphenidate"))
        #expect(CheckInScheduler.offerableCategories.contains(mph.category))
    }

    // MARK: - Starting on their own

    @Test
    func `With the setting off, a new session gets no check-ins`() async throws {
        try await requireFixtures()
        let context = try makeContext()
        let session = try session([lsd(at: t0)], in: context)

        let running = CheckInScheduler.follow(newDoseIn: session, everySession: false, now: t0)

        #expect(!running)
        #expect(session.checkInIntervalMinutes == nil)
        #expect(!session.checkInOffered)
        #expect(session.checkInOffsetMinutes.isEmpty)
    }

    @Test
    func `With the setting on, the first offerable dose starts the suggested times`() async throws {
        try await requireFixtures()
        let context = try makeContext()
        let session = try session([lsd(at: t0)], in: context)
        let suggested = CheckInLadder.suggestedOffsets(for: session)
        #expect(!suggested.isEmpty)

        let running = CheckInScheduler.follow(newDoseIn: session, everySession: true, now: t0)

        #expect(running)
        #expect(CheckInScheduler.Cadence(storedMinutes: session.checkInIntervalMinutes) == .custom)
        #expect(session.checkInOffsetMinutes == suggested)
        #expect(session.checkInFollowsDoses)
        // Offered is how the banner knows to stay away.
        #expect(session.checkInOffered)
        #expect(!CheckInScheduler.shouldOffer(session: session, hasOngoingDose: true))
    }

    @Test
    func `A session that turned check-ins down is not started again`() async throws {
        try await requireFixtures()
        let context = try makeContext()
        let session = try session([lsd(at: t0)], in: context)
        session.checkInOffered = true

        #expect(!CheckInScheduler.follow(newDoseIn: session, everySession: true, now: t0))
        #expect(session.checkInIntervalMinutes == nil)
    }

    @Test
    func `A dose logged long after the fact starts nothing`() async throws {
        try await requireFixtures()
        let context = try makeContext()
        let session = try session([lsd(at: t0)], in: context)
        let twoDaysLater = t0.addingTimeInterval(2 * 24 * 3_600)

        #expect(!CheckInScheduler.follow(newDoseIn: session, everySession: true, now: twoDaysLater))
        #expect(session.checkInIntervalMinutes == nil)
        #expect(!session.checkInOffered)
    }

    // MARK: - Recomputing from every dose

    @Test
    func `A new substance adds its own moments`() async throws {
        try await requireFixtures()
        let context = try makeContext()
        let session = try session([lsd(at: t0)], in: context)
        CheckInScheduler.follow(newDoseIn: session, everySession: true, now: t0)
        let before = Set(times(of: session))

        let later = t0.addingTimeInterval(60 * 60)
        add(methylphenidate(at: later), to: session, in: context)
        #expect(CheckInScheduler.follow(newDoseIn: session, everySession: true, now: later))

        let after = Set(times(of: session))
        #expect(session.checkInOffsetMinutes == CheckInLadder.suggestedOffsets(for: session))
        // Moments that were not there before: the methylphenidate's own.
        #expect(!after.subtracting(before).isEmpty)
        // The first dose's moments that are still ahead keep their place.
        let anchor = CheckInScheduler.anchor(for: session)
        let stillAhead = before.filter { $0 >= anchor.addingTimeInterval(Double(CheckInOffsets.minimumMinutes) * 60) }
        #expect(stillAhead.isSubset(of: after))
    }

    @Test
    func `A redose pushes the last moments later`() async throws {
        try await requireFixtures()
        let context = try makeContext()
        let session = try session([lsd(at: t0)], in: context)
        CheckInScheduler.follow(newDoseIn: session, everySession: false, now: t0)
        // Started from the banner rather than the setting: the redose still follows.
        session.checkInOffered = true
        session.checkInOffsetMinutes = CheckInLadder.suggestedOffsets(for: session)
        session.checkInIntervalMinutes = CheckInScheduler.Cadence.custom.storedMinutes
        session.checkInFollowsDoses = true
        let lastBefore = try #require(times(of: session).max())

        let redose = t0.addingTimeInterval(2 * 3_600)
        add(lsd(at: redose), to: session, in: context)
        #expect(CheckInScheduler.follow(newDoseIn: session, everySession: false, now: redose))

        let lastAfter = try #require(times(of: session).max())
        #expect(lastAfter > lastBefore)
        #expect(session.checkInOffsetMinutes == CheckInLadder.suggestedOffsets(for: session))
    }

    // MARK: - What a new dose leaves alone

    @Test
    func `Times someone chose survive a new dose`() async throws {
        try await requireFixtures()
        let context = try makeContext()
        let session = try session([lsd(at: t0)], in: context)
        session.checkInOffered = true
        session.checkInOffsetMinutes = [30, 90, 400]
        session.checkInIntervalMinutes = CheckInScheduler.Cadence.custom.storedMinutes
        session.checkInFollowsDoses = false

        let later = t0.addingTimeInterval(60 * 60)
        add(methylphenidate(at: later), to: session, in: context)
        // Still running, so the caller reschedules from the new anchor.
        #expect(CheckInScheduler.follow(newDoseIn: session, everySession: true, now: later))

        #expect(session.checkInOffsetMinutes == [30, 90, 400])
        #expect(CheckInScheduler.Cadence(storedMinutes: session.checkInIntervalMinutes) == .custom)
        #expect(!session.checkInFollowsDoses)
    }

    @Test
    func `A row from before the flag keeps its times`() {
        // The store default is the safe reading for a list it cannot place.
        #expect(!Session(startDate: t0).checkInFollowsDoses)
    }

    @Test
    func `Prompts that have gone are neither lost nor fired again`() async throws {
        try await requireFixtures()
        let context = try makeContext()
        let session = try session([lsd(at: t0)], in: context)
        CheckInScheduler.follow(newDoseIn: session, everySession: true, now: t0)

        let now = t0.addingTimeInterval(4 * 3_600)
        let firedBefore = Set(times(of: session).filter { $0 <= now })
        #expect(!firedBefore.isEmpty)
        // One of them was answered.
        let answered = try #require(firedBefore.min())
        _ = SessionNoteService.add(to: session, timestamp: answered, text: "colors", kind: .checkIn)

        // A redose logged a little back in time, so part of the old run sits
        // between it and now.
        let redose = now.addingTimeInterval(-90 * 60)
        add(lsd(at: redose), to: session, in: context)
        #expect(CheckInScheduler.follow(newDoseIn: session, everySession: true, now: now))

        // The answered check-in is still on the session.
        #expect(session.orderedNotes.contains { $0.kind == .checkIn && $0.timestamp == answered })
        // Nothing scheduled from here on is at or before now.
        let pending = CheckInScheduler.fireDates(
            cadence: .custom, custom: session.checkInOffsetMinutes,
            anchor: CheckInScheduler.anchor(for: session), now: now,
        )
        #expect(!pending.isEmpty)
        #expect(pending.allSatisfy { $0 > now })
        // The ladder is read in absolute time, so no prompt that already went
        // drifts forward into the future to be asked a second time.
        #expect(Set(pending).isDisjoint(with: firedBefore))
        let gone = Set(times(of: session).filter { $0 <= now })
        #expect(gone.allSatisfy { !pending.contains($0) })
    }
}
