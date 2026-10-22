import Foundation
import os
import SwiftData
import UserNotifications

/// Opt-in per-session "How is it going?" prompts. Each fires a local
/// notification whose tap (or its **Add Note** action) opens the note sheet on
/// the session, pre-tagged `.checkIn`. Off unless the session asks
/// (``Session/checkInIntervalMinutes``), or Settings turns them on for every
/// session (``everySessionKey``).
///
/// Requests use the `piru.notif.checkIn.<sessionID>.<n>` grammar and the same
/// 6-hour session thread as the ramp-down notifications, so they collapse into
/// the session's group in Notification Center.
enum CheckInScheduler {
    nonisolated static let categoryID = "checkIn"

    /// The schedule a session runs, stored as minutes on the session.
    ///
    /// Two: an hourly run, and the session's own times. A fixed ladder is
    /// someone else's guess at when a session matters, and ``CheckInLadder``
    /// answers that from the curve instead; `custom` is where its answer lands.
    nonisolated enum Cadence: Hashable, CaseIterable, Identifiable {
        case everyHour
        /// The times on the session (``Session/checkInOffsetMinutes``).
        case custom

        var id: Self {
            self
        }

        var storedMinutes: Double {
            switch self {
            case .everyHour: 60
            case .custom: -1
            }
        }

        init?(storedMinutes: Double?) {
            guard let storedMinutes else { return nil }
            switch storedMinutes {
            case -1: self = .custom
            case 60: self = .everyHour
            default: return nil
            }
        }

        /// Fixed offsets from the anchor dose, in minutes. The hourly run goes
        /// for eight hours — long enough for a whole psychedelic session, short
        /// enough that a forgotten toggle stops on its own. `custom` has none of
        /// its own: its times live on the session.
        var fixedOffsetMinutes: [Double] {
            switch self {
            case .custom: []
            case .everyHour: Array(stride(from: 60.0, through: 480, by: 60))
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .everyHour: "Every hour"
            case .custom: "Custom…"
            }
        }
    }

    /// The offsets a session actually runs, in minutes: the cadence's own, or
    /// the session's list when it chose them itself.
    nonisolated static func offsetMinutes(cadence: Cadence, custom: [Int]) -> [Double] {
        cadence == .custom ? CheckInOffsets.normalized(custom).map(Double.init) : cadence.fixedOffsetMinutes
    }

    /// Anchor time for a session's check-ins: its latest dose.
    nonisolated static func anchor(for session: Session) -> Date {
        session.lastDoseDate ?? session.startDate
    }

    /// The fire dates a schedule yields from `anchor`, dropping any already past
    /// `now`. Pure, for tests.
    nonisolated static func fireDates(
        cadence: Cadence,
        custom: [Int] = [],
        anchor: Date,
        now: Date = .now,
    ) -> [Date] {
        offsetMinutes(cadence: cadence, custom: custom)
            .map { anchor.addingTimeInterval($0 * 60) }
            .filter { $0 > now.addingTimeInterval(5) }
    }

    /// One prompt in a session's schedule, as the session screen shows it.
    nonisolated struct Planned: Identifiable, Hashable {
        /// Why a row reads the way it does. A schedule that listed every time
        /// as "coming" would be wrong twice over: a prompt whose hour has gone
        /// is not coming, and one inside quiet hours is never scheduled at all
        /// (``sync(session:)`` skips it).
        enum State: Hashable {
            case scheduled
            case quietHours
            case passed
        }

        let offsetMinutes: Int
        let date: Date
        let state: State

        var id: Int {
            offsetMinutes
        }
    }

    /// The whole schedule a session runs, past prompts included — what
    /// ``fireDates(cadence:custom:anchor:now:)`` computes, without dropping
    /// what has already gone. Pure, for tests.
    nonisolated static func plan(
        cadence: Cadence,
        custom: [Int] = [],
        anchor: Date,
        now: Date = .now,
    ) -> [Planned] {
        offsetMinutes(cadence: cadence, custom: custom).map { minutes in
            let date = anchor.addingTimeInterval(minutes * 60)
            let state: Planned.State = if date <= now {
                .passed
            } else if NotificationPreferencesStore.isInQuietHours(date) {
                .quietHours
            } else {
                .scheduled
            }
            return Planned(offsetMinutes: Int(minutes), date: date, state: state)
        }
    }

    /// The session's schedule, or nil when it runs none.
    static func plan(for session: Session, now: Date = .now) -> [Planned]? {
        guard let cadence = Cadence(storedMinutes: session.checkInIntervalMinutes) else { return nil }
        return plan(cadence: cadence, custom: session.checkInOffsetMinutes, anchor: anchor(for: session), now: now)
    }

    /// `true` when check-in notifications are off app-wide, so a session's
    /// schedule exists but nothing it lists will arrive.
    nonisolated static var isMutedByPreferences: Bool {
        !NotificationPreferencesStore.allows(.checkIn)
    }

    /// Apply the session's stored cadence: cancel what is pending and schedule
    /// afresh from the latest dose. Call after the cadence changes; a dose added
    /// to the session reaches it through ``dosesLogged(in:)`` (the anchor moved).
    static func sync(session: Session) {
        cancel(sessionID: session.id)
        guard let cadence = Cadence(storedMinutes: session.checkInIntervalMinutes) else { return }
        guard NotificationPreferencesStore.allows(.checkIn) else { return }
        let dates = fireDates(
            cadence: cadence,
            custom: session.checkInOffsetMinutes,
            anchor: anchor(for: session),
        )
        let center = UNUserNotificationCenter.current()
        let thread = SessionNotificationScheduler.sessionIdentifier(for: session.startDate)
        // A session that only carries medication is asked the medication
        // question, in the words its own control uses.
        let form = CheckInForm.build(for: session)
        let isMedication = form.asksWorked && !form.asksIntensity
        let title = isMedication
            ? String(localized: "Is it working?")
            : String(localized: "How is it going?")
        let body = isMedication
            ? String(localized: "One tap records how this dose is going: less than usual, about right, or more.")
            : String(localized: "Add a note to your session: what you notice, at this moment.")
        for (index, date) in dates.enumerated() {
            if NotificationPreferencesStore.isInQuietHours(date) { continue }
            let content = UNMutableNotificationContent(
                title: title,
                body: body,
                category: categoryID,
                threadIdentifier: thread,
            )
            content.userInfo = [
                DoseNotificationManager.deepLinkUserInfoKey: "\(DeepLink.scheme)://session/\(session.id.uuidString)?note=checkIn",
            ]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSinceNow, repeats: false)
            let request = UNNotificationRequest(
                identifier: NotificationType.checkIn.identifier(anchor: session.id.uuidString, ordinal: String(index)),
                content: content,
                trigger: trigger,
            )
            center.add(request) { error in
                if let error {
                    Logger.checkIn.error("Check-in schedule failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        Logger.checkIn.debug("Scheduled \(dates.count) check-ins for session \(session.id.uuidString, privacy: .public)")
    }

    static func cancel(sessionID: UUID) {
        let prefix = NotificationType.checkIn.identifierPrefix + sessionID.uuidString
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }

    /// Classes where a timed prompt has something to learn: a psychoactive dose
    /// with a course someone can report on. A supplement or an antibiotic is
    /// logged, not experienced, so asking about it hourly would be noise.
    nonisolated static let offerableCategories: Set<SubstanceCategory> = [
        .psychedelic, .dissociative, .dysdelic, .deliriant, .empathogen,
        .stimulant, .eugeroic, .cannabinoid, .opioid, .benzodiazepine,
        .depressant, .gabapentinoid,
    ]

    /// How many times the offer may be turned down before it stops appearing.
    ///
    /// The offer is per-session, and someone who takes a medication daily starts
    /// a session a day — without this, declining once would mean declining every
    /// morning forever. Two says it clearly enough.
    nonisolated static let maximumDeclines = 2
    private nonisolated static let declineKey = "checkInOfferDeclines"

    private nonisolated static var defaults: UserDefaults {
        UserDefaults(suiteName: AppIdentity.appGroup) ?? .standard
    }

    /// Record that the banner was dismissed rather than accepted.
    nonisolated static func recordOfferDeclined() {
        defaults.set(defaults.integer(forKey: declineKey) + 1, forKey: declineKey)
    }

    nonisolated static var isOfferMuted: Bool {
        defaults.integer(forKey: declineKey) >= maximumDeclines
    }

    /// Whether a session should be *offered* check-ins: once per session, while
    /// a dose of an ``offerableCategories`` class is still in its effect window,
    /// and only until the offer has been turned down ``maximumDeclines`` times.
    /// With check-ins on for every session there is nothing to offer: the
    /// session starts them itself when the dose lands (``follow(newDoseIn:everySession:now:)``).
    static func shouldOffer(session: Session, hasOngoingDose: Bool) -> Bool {
        guard hasOngoingDose, !session.checkInOffered, session.checkInIntervalMinutes == nil else { return false }
        guard !isOfferMuted, !checksInEverySession else { return false }
        return hasOfferableDose(session)
    }

    /// Whether any dose in the session is of an ``offerableCategories`` class.
    static func hasOfferableDose(_ session: Session) -> Bool {
        (session.doses ?? []).contains { dose in
            guard let category = SubstanceLibrary.lookup(dose.substance)?.category else { return false }
            return offerableCategories.contains(category)
        }
    }

    // MARK: - Following the doses

    /// Settings › Notifications › Check In on Every Session, in the app-group
    /// defaults. Off by default: check-ins stay something a session asks for.
    nonisolated static let everySessionKey = "checkInEverySession"

    nonisolated static var checksInEverySession: Bool {
        defaults.bool(forKey: everySessionKey)
    }

    /// Bring a session's check-ins up to date with a dose that just landed in
    /// it. Returns whether the session runs check-ins afterwards, so the caller
    /// knows to ``sync(session:)``: the anchor moved even when the times did not.
    ///
    /// - A session with none starts them when `everySession` is on, it holds an
    ///   offerable dose, nobody has turned them down for it, and at least one
    ///   prompt is still ahead. A dose logged after the fact has nothing left
    ///   to ask about, so it leaves the session as it was.
    /// - A session whose times are the app's pick (``Session/checkInFollowsDoses``)
    ///   gets the ladder recomputed from every dose it now holds: a new
    ///   substance adds its moments and a redose moves them later.
    /// - Times the person chose are left exactly as they are.
    ///
    /// The ladder is read in absolute time, so a moment that already fired
    /// either stays in the past (where ``fireDates(cadence:custom:anchor:now:)``
    /// drops it) or falls before the new anchor and out of the list; neither
    /// is scheduled again. Needs the substance catalog loaded.
    @discardableResult
    static func follow(newDoseIn session: Session, everySession: Bool, now: Date = .now) -> Bool {
        let cadence = Cadence(storedMinutes: session.checkInIntervalMinutes)
        guard let cadence else {
            guard everySession, !session.checkInOffered, hasOfferableDose(session) else { return false }
            let suggested = CheckInLadder.suggestedOffsets(for: session)
            // The banner's own fallback: nothing in the session models a curve
            // to read times off, so the hourly run.
            let start: Cadence = suggested.isEmpty ? .everyHour : .custom
            let ahead = fireDates(cadence: start, custom: suggested, anchor: anchor(for: session), now: now)
            guard !ahead.isEmpty else { return false }
            session.checkInOffered = true
            session.checkInOffsetMinutes = suggested
            session.checkInIntervalMinutes = start.storedMinutes
            session.checkInFollowsDoses = true
            return true
        }
        if session.checkInFollowsDoses {
            let suggested = CheckInLadder.suggestedOffsets(for: session)
            if !suggested.isEmpty {
                session.checkInOffsetMinutes = suggested
                session.checkInIntervalMinutes = Cadence.custom.storedMinutes
            } else if cadence == .custom {
                // Nothing models a curve any more (the dose that did was moved
                // or deleted): an empty custom list would claim check-ins are
                // on while scheduling none.
                session.checkInIntervalMinutes = Cadence.everyHour.storedMinutes
            }
        }
        return true
    }

    /// The post-commit step every dose-logging path runs (``DoseLogService``):
    /// follow the doses in each session that just gained one, then reschedule
    /// it. Runs for every session with check-ins, whether the setting or the
    /// banner started them.
    ///
    /// A session with no check-ins is left untouched unless the setting could
    /// start them. The rest are held by identifier across the awaits and looked
    /// up again in the logging context after each one: that context may have
    /// been reset in the meantime, and a model it destroyed traps on any read.
    static func dosesLogged(in sessions: [Session]) {
        let everySession = checksInEverySession
        var seen = Set<UUID>()
        let candidates = sessions.filter {
            seen.insert($0.id).inserted && (everySession || $0.checkInIntervalMinutes != nil)
        }
        guard let context = candidates.first?.modelContext else { return }
        let ids = candidates.map(\.persistentModelID)
        func live(_ ids: [PersistentIdentifier]) -> [Session] {
            ids.compactMap { context.registeredModel(for: $0) as Session? }.filter { !$0.isDeleted }
        }
        Task {
            await SubstanceStore.shared.ensureAllLoaded()
            var running: [PersistentIdentifier] = []
            var started = false
            for session in live(ids) {
                let wasOff = session.checkInIntervalMinutes == nil
                guard follow(newDoseIn: session, everySession: everySession) else { continue }
                started = started || wasOff
                running.append(session.persistentModelID)
            }
            guard !running.isEmpty else { return }
            try? context.save()
            if started { _ = await DoseNotificationManager.requestAuthorization() }
            for session in live(running) {
                sync(session: session)
            }
        }
    }
}
