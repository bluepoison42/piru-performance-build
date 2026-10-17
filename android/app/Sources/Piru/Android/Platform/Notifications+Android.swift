// What UserNotifications gives the iOS build beyond SkipFuseUI's bridge: the interruption level
// and relevance (Android sets these per notification channel rather than per notification), and
// actionable categories, which register nothing: an Android notification action needs a Kotlin
// broadcast receiver this build does not ship.

import SwiftUI

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
        // The center is the process-wide singleton, so handing it to the task shares nothing new.
        nonisolated(unsafe) let center = self
        Task {
            do {
                try await center.add(request)
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) {
        nonisolated(unsafe) let center = self
        Task {
            await completionHandler(center.pendingNotificationRequests())
        }
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
