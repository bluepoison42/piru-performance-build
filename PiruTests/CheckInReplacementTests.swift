import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Piru

/// Replacing a session's pending check-ins: whatever order the system finishes
/// the adds in, and however the schedule changed, what is pending afterwards
/// is exactly the newest schedule.
@MainActor
@Suite("CheckInScheduler replaces a session's schedule")
struct CheckInReplacementTests {
    /// A notification center that records what is pending and can hold every
    /// add until released, the way a slow system add leaves a replacement
    /// suspended part-way through.
    @MainActor
    final class RecordingCenter: PendingNotificationCenter {
        var pending: [String: UNNotificationRequest] = [:]
        var holdsAdds = false
        private var held: [CheckedContinuation<Void, Never>] = []

        func removePendingRequests(withIdentifiers identifiers: [String]) {
            for identifier in identifiers {
                pending[identifier] = nil
            }
        }

        func add(_ request: UNNotificationRequest) async throws {
            if holdsAdds {
                await withCheckedContinuation { held.append($0) }
            }
            pending[request.identifier] = request
        }

        /// Lets every held add finish, and stops holding new ones.
        func release() {
            holdsAdds = false
            let waiting = held
            held = []
            for continuation in waiting {
                continuation.resume()
            }
        }

        /// The pending identifiers of one session's check-ins.
        func identifiers(of session: Session) -> Set<String> {
            Set(pending.keys.filter { $0.hasPrefix(NotificationType.checkIn.identifierPrefix + session.id.uuidString) })
        }

        /// Seconds from now until `identifier` fires, as its trigger says.
        func secondsUntil(_ identifier: String) -> TimeInterval? {
            (pending[identifier]?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
        }
    }

    private let defaults: UserDefaults

    init() {
        // Quiet hours and the app-wide switch are read from here, never from
        // the standard defaults another test may be changing.
        defaults = UserDefaults(suiteName: "CheckInReplacementTests.\(UUID().uuidString)")!
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema(PiruSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        )
        return ModelContext(container)
    }

    /// A session that began ten minutes ago, so every hourly prompt is ahead.
    private func session(in context: ModelContext) -> Session {
        let session = Session(startDate: .now.addingTimeInterval(-10 * 60))
        context.insert(session)
        return session
    }

    private func runHourly(_ session: Session) {
        session.checkInIntervalMinutes = CheckInScheduler.Cadence.everyHour.storedMinutes
    }

    private func runCustom(_ session: Session, _ minutes: [Int]) {
        session.checkInOffsetMinutes = minutes
        session.checkInIntervalMinutes = CheckInScheduler.Cadence.custom.storedMinutes
    }

    private func identifiers(_ session: Session, _ ordinals: Range<Int>) -> Set<String> {
        Set(ordinals.map { CheckInScheduler.identifier(sessionID: session.id, ordinal: $0) })
    }

    /// Seconds from now until `minutes` after the session's anchor.
    private func secondsUntil(_ minutes: Int, after session: Session) -> TimeInterval {
        CheckInScheduler.anchor(for: session).addingTimeInterval(Double(minutes) * 60).timeIntervalSinceNow
    }

    private func sync(_ session: Session, _ center: RecordingCenter) -> Task<Void, Never> {
        CheckInScheduler.sync(session: session, center: center, defaults: defaults)
    }

    // MARK: - Identifiers

    @Test
    func `Every identifier a session can use is in the check-in grammar, as many as the longest schedule`() {
        let id = UUID()
        let identifiers = CheckInScheduler.identifiers(sessionID: id)
        #expect(CheckInScheduler.maximumPending == CheckInOffsets.maximumCount)
        #expect(identifiers.count == CheckInScheduler.maximumPending)
        #expect(identifiers.first == "piru.notif.checkIn.\(id.uuidString).0")
        #expect(CheckInScheduler.maximumPending >= CheckInScheduler.Cadence.everyHour.fixedOffsetMinutes.count)
    }

    // MARK: - A replacement overtaking one still adding

    @Test
    func `A schedule replaced while its adds are in flight leaves only the new one`() async throws {
        let context = try makeContext()
        let session = session(in: context)
        let center = RecordingCenter()
        center.holdsAdds = true

        runHourly(session)
        let first = sync(session, center)
        runCustom(session, [30, 90])
        let second = sync(session, center)
        center.release()
        await first.value
        await second.value

        #expect(center.identifiers(of: session) == identifiers(session, 0 ..< 2))
        // Ordinal 0 is the new +30 m prompt, not the hourly one the first
        // replacement was adding when it was overtaken.
        let first0 = try #require(center.secondsUntil(CheckInScheduler.identifier(sessionID: session.id, ordinal: 0)))
        #expect(abs(first0 - secondsUntil(30, after: session)) < 5)
        let first1 = try #require(center.secondsUntil(CheckInScheduler.identifier(sessionID: session.id, ordinal: 1)))
        #expect(abs(first1 - secondsUntil(90, after: session)) < 5)
    }

    @Test
    func `Turning check-ins off while the schedule is still being added leaves nothing`() async throws {
        let context = try makeContext()
        let session = session(in: context)
        let center = RecordingCenter()
        center.holdsAdds = true

        runHourly(session)
        let first = sync(session, center)
        session.checkInIntervalMinutes = nil
        let second = sync(session, center)
        center.release()
        await first.value
        await second.value

        #expect(center.identifiers(of: session).isEmpty)
    }

    @Test
    func `Muting check-ins app-wide while the schedule is still being added leaves nothing`() async throws {
        let context = try makeContext()
        let session = session(in: context)
        let center = RecordingCenter()
        center.holdsAdds = true

        runHourly(session)
        let first = sync(session, center)
        defaults.set(false, forKey: "notificationTypeEnabled_\(NotificationType.checkIn.rawValue)")
        #expect(!NotificationPreferencesStore.allows(.checkIn, defaults: defaults))
        let second = sync(session, center)
        center.release()
        await first.value
        await second.value

        #expect(center.identifiers(of: session).isEmpty)
    }

    // MARK: - Replacing a finished schedule

    @Test
    func `A shorter schedule removes the previous one's extra prompts`() async throws {
        let context = try makeContext()
        let session = session(in: context)
        let center = RecordingCenter()

        runHourly(session)
        await sync(session, center).value
        #expect(center.identifiers(of: session) == identifiers(session, 0 ..< 8))

        runCustom(session, [45])
        await sync(session, center).value

        #expect(center.identifiers(of: session) == identifiers(session, 0 ..< 1))
        let only = try #require(center.secondsUntil(CheckInScheduler.identifier(sessionID: session.id, ordinal: 0)))
        #expect(abs(only - secondsUntil(45, after: session)) < 5)
    }

    @Test
    func `Prompts a previous launch left pending are removed before anything is added`() async throws {
        let context = try makeContext()
        let session = session(in: context)
        let center = RecordingCenter()
        let stale = CheckInScheduler.identifiers(sessionID: session.id)
        for identifier in stale {
            let content = UNMutableNotificationContent()
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
            center.pending[identifier] = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        }
        center.holdsAdds = true

        runCustom(session, [30])
        let replacement = sync(session, center)

        // Nothing was ahead of it, so the removal happened before sync returned.
        #expect(center.identifiers(of: session).isEmpty)
        center.release()
        await replacement.value
        #expect(center.identifiers(of: session) == identifiers(session, 0 ..< 1))
    }

    @Test
    func `Back-to-back replacements end on the last schedule asked for`() async throws {
        let context = try makeContext()
        let session = session(in: context)
        let center = RecordingCenter()

        runHourly(session)
        let first = sync(session, center)
        runCustom(session, [20, 40, 60, 80])
        let second = sync(session, center)
        runCustom(session, [100, 200, 300])
        let third = sync(session, center)
        await first.value
        await second.value
        await third.value

        #expect(center.identifiers(of: session) == identifiers(session, 0 ..< 3))
        for (ordinal, minutes) in [100, 200, 300].enumerated() {
            let seconds = try #require(center.secondsUntil(CheckInScheduler.identifier(sessionID: session.id, ordinal: ordinal)))
            #expect(abs(seconds - secondsUntil(minutes, after: session)) < 5)
        }
    }

    // MARK: - Independent sessions

    @Test
    func `Replacing one session's schedule leaves another session's alone`() async throws {
        let context = try makeContext()
        let one = session(in: context)
        let other = session(in: context)
        let center = RecordingCenter()
        center.holdsAdds = true

        runHourly(one)
        let first = sync(one, center)
        runCustom(other, [30, 90])
        let second = sync(other, center)
        runCustom(one, [15])
        let third = sync(one, center)
        center.release()
        await first.value
        await second.value
        await third.value

        #expect(center.identifiers(of: one) == identifiers(one, 0 ..< 1))
        #expect(center.identifiers(of: other) == identifiers(other, 0 ..< 2))
    }
}
