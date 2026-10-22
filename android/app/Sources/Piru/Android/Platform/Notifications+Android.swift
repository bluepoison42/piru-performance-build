// What UserNotifications gives the iOS build beyond SkipFuseUI's bridge: the interruption level
// and relevance (Android sets these per notification channel rather than per notification);
// actionable categories, which register nothing, since an Android notification action needs a
// Kotlin broadcast receiver this build does not ship; and the completion-handler calls, which
// SkipFuseUI has only in async form, applied in the order they were made.

import SwiftUI
import Synchronization

nonisolated enum UNNotificationInterruptionLevel: Int {
    case passive
    case active
    case timeSensitive
    case critical
}

nonisolated extension UNMutableNotificationContent {
    var interruptionLevel: UNNotificationInterruptionLevel {
        get { .active }
        set {}
    }

    var relevanceScore: Double {
        get { 0 }
        set {}
    }
}

struct UNNotificationActionOptions: OptionSet {
    let rawValue: Int
    static let authenticationRequired = UNNotificationActionOptions(rawValue: 1)
    static let destructive = UNNotificationActionOptions(rawValue: 2)
    static let foreground = UNNotificationActionOptions(rawValue: 4)
}

struct UNNotificationCategoryOptions: OptionSet {
    let rawValue: Int
    static let customDismissAction = UNNotificationCategoryOptions(rawValue: 1)
    static let hiddenPreviewsShowTitle = UNNotificationCategoryOptions(rawValue: 2)
}

final nonisolated class UNNotificationAction: Hashable {
    let identifier: String
    let title: String

    init(identifier: String, title: String, options _: UNNotificationActionOptions = [], icon _: Any? = nil) {
        self.identifier = identifier
        self.title = title
    }

    static func == (lhs: UNNotificationAction, rhs: UNNotificationAction) -> Bool { lhs.identifier == rhs.identifier }
    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
}

final nonisolated class UNNotificationCategory: Hashable {
    let identifier: String

    init(identifier: String, actions _: [UNNotificationAction], intentIdentifiers _: [String], options _: UNNotificationCategoryOptions = []) {
        self.identifier = identifier
    }

    static func == (lhs: UNNotificationCategory, rhs: UNNotificationCategory) -> Bool { lhs.identifier == rhs.identifier }
    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
}

nonisolated extension UNUserNotificationCenter {
    func setNotificationCategories(_: Set<UNNotificationCategory>) {}

    func add(_ request: UNNotificationRequest, withCompletionHandler completion: (@Sendable (Error?) -> Void)? = nil) {
        AndroidNotificationQueue.shared.add(request, to: self, completion: completion)
    }

    func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) {
        AndroidNotificationQueue.shared.pendingRequests(of: self, completion: completionHandler)
    }

    /// The removal every upstream call reaches through substitutions.txt: it removes at once, as
    /// Skip's does, and also cancels the completion-handler adds of these identifiers that were
    /// asked for before it.
    func androidRemovePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        AndroidNotificationQueue.shared.remove(identifiers, from: self)
    }
}

/// Applies the completion-handler notification calls in the order they were made, as iOS's
/// center does. SkipFuseUI's center is async only, so each call runs in a task here; the tasks
/// form one chain, so an `add` or `getPendingNotificationRequests` starts once every earlier one
/// has finished, and a later add of an identifier replaces an earlier one.
///
/// A removal stays immediate, because code that awaits Skip's async `add` relies on it, and it
/// is ordered against the chain by its sequence number: a queued add asked for before it is
/// dropped, and one already inside Skip's `add` is removed again once that returns.
final nonisolated class AndroidNotificationQueue: Sendable {
    static let shared = AndroidNotificationQueue()

    private struct State {
        /// The last operation in the chain.
        var tail: Task<Void, Never>?
        /// Numbers each operation and removal in the order it was asked for.
        var sequence = 0
        /// Operations asked for and not yet finished.
        var unfinished = 0
        /// The sequence number of the latest removal of each identifier, kept while the chain has
        /// operations an earlier removal could overtake.
        var removedAt: [String: Int] = [:]
    }

    private let state = Mutex(State())

    func add(
        _ request: UNNotificationRequest,
        to center: UNUserNotificationCenter,
        completion: (@Sendable (Error?) -> Void)?,
    ) {
        // The center is the process-wide singleton, so handing it to the chain shares nothing new.
        nonisolated(unsafe) let skipCenter = center
        enqueue { sequence in
            let identifier = request.identifier
            guard !self.isRemoved(identifier, after: sequence) else {
                completion?(nil)
                return
            }
            do {
                try await skipCenter.add(request)
            } catch {
                completion?(error)
                return
            }
            if self.isRemoved(identifier, after: sequence) {
                Self.removeNow([identifier], from: skipCenter)
            }
            completion?(nil)
        }
    }

    func pendingRequests(
        of center: UNUserNotificationCenter,
        completion: @escaping @Sendable ([UNNotificationRequest]) -> Void,
    ) {
        nonisolated(unsafe) let skipCenter = center
        enqueue { _ in
            await completion(skipCenter.pendingNotificationRequests())
        }
    }

    func remove(_ identifiers: [String], from center: UNUserNotificationCenter) {
        state.withLock { state in
            guard state.unfinished > 0 else { return }
            state.sequence += 1
            for identifier in identifiers {
                state.removedAt[identifier] = state.sequence
            }
        }
        Self.removeNow(identifiers, from: center)
    }

    /// Skip's own removal. substitutions.txt leaves a call on `skipCenter` as written, so this
    /// one reaches Skip rather than the twin that calls it.
    private static func removeNow(_ identifiers: [String], from skipCenter: UNUserNotificationCenter) {
        skipCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Runs `operation` with its sequence number once every operation asked for before it has
    /// finished.
    private func enqueue(_ operation: @escaping @Sendable (_ sequence: Int) async -> Void) {
        state.withLock { state in
            state.sequence += 1
            state.unfinished += 1
            let sequence = state.sequence
            let previous = state.tail
            state.tail = Task {
                await previous?.value
                await operation(sequence)
                self.finish()
            }
        }
    }

    private func finish() {
        state.withLock { state in
            state.unfinished -= 1
            if state.unfinished == 0 {
                state.tail = nil
                state.removedAt = [:]
            }
        }
    }

    /// Whether `identifier` was removed after the operation numbered `sequence` was asked for.
    private func isRemoved(_ identifier: String, after sequence: Int) -> Bool {
        state.withLock { ($0.removedAt[identifier] ?? 0) > sequence }
    }
}

/// A repeating calendar reminder on Android. Skip's calendar trigger carries its
/// DateComponents as `Any`, which the bridge cannot hand to Kotlin (a fatal error on
/// schedule), so the reminder is the next matching moment as a one-shot interval trigger.
/// The routine reminders are rescheduled whenever the app runs, which carries it forward.
enum AndroidCalendarTrigger {
    static func make(dateMatching components: DateComponents, repeats _: Bool) -> UNNotificationTrigger {
        let next = Calendar.current.nextDate(after: .now, matching: components, matchingPolicy: .nextTime)
            ?? .now.addingTimeInterval(60)
        return UNTimeIntervalNotificationTrigger(timeInterval: max(1, next.timeIntervalSinceNow), repeats: false)
    }
}

/// The notification delegate on Android. SkipUI schedules a notification only when a delegate
/// asks to present it, so `willPresent` answers as iOS shows a reminder in the foreground. A tap
/// lands at the notification's deep link, as `DoseNotificationDelegate` does on iOS.
final class AndroidNotificationDelegate: UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = AndroidNotificationDelegate()

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let link = response.notification.request.content.userInfo[DoseNotificationManager.deepLinkUserInfoKey] as? String
        guard let link, let url = URL(string: link), let outcome = DeepLink.decode(url) else { return }
        await MainActor.run { AppNavigator.shared.apply(outcome) }
    }
}
