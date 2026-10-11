import Foundation
import Synchronization

/// A hold on the process's runtime: while one is open, iOS lets the app keep
/// running instead of suspending it, within the system's background-time budget.
///
/// Open one around a write to the App Group store that can start, or still be
/// running, while the app is in the background or not yet launched in the
/// foreground. RunningBoard kills a process it suspends while a SQLite lock is
/// held on a file in a shared container (`0xdead10cc`), and a SwiftData save
/// cannot be interrupted partway, so a background write either finishes before
/// suspension or must not start. GRDB connections get the same protection from
/// ``DatabaseSuspension``.
///
/// Built on `ProcessInfo.performExpiringActivity`, which needs no
/// `UIApplication`: it works in `App.init`, before UIKit has created the
/// application object, and from any actor.
final nonisolated class BackgroundActivity: Sendable {
    /// Signaled to release the hold; the system's activity block waits on it.
    private let released = DispatchSemaphore(value: 0)
    /// Whether the system has answered the request, so the answer is reported once.
    private let answered = Mutex(false)

    private init() {}

    /// Hold the process awake for `reason` without waiting for the system's
    /// answer, for work that runs either way, such as opening the store at
    /// launch. Pair it with ``end()``.
    static func hold(_ reason: String) -> BackgroundActivity {
        let activity = BackgroundActivity()
        activity.request(reason) { _ in }
        return activity
    }

    /// Ask for a hold and wait for the answer. `nil` when the system refuses,
    /// which means the process is about to be suspended: the caller skips its
    /// write rather than start one the suspension would catch holding a lock.
    /// Pair a non-`nil` result with ``end()``.
    static func begin(_ reason: String) async -> BackgroundActivity? {
        let activity = BackgroundActivity()
        let granted = await withCheckedContinuation { continuation in
            activity.request(reason) { continuation.resume(returning: $0) }
        }
        return granted ? activity : nil
    }

    /// Release the hold. Safe to call more than once, and after the system
    /// has ended the hold itself.
    func end() {
        released.signal()
    }

    /// The system calls the activity block once with `expired == false` when it
    /// grants the hold, which lasts until that call returns, and calls it again
    /// with `expired == true` when the budget runs out. A refused request gets
    /// only the `expired == true` call.
    private func request(_ reason: String, answer: @escaping @Sendable (Bool) -> Void) {
        #if canImport(Darwin)
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { [self] expired in
                let isFirstAnswer = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if isFirstAnswer { answer(!expired) }
                if expired {
                    released.signal()
                } else {
                    released.wait()
                }
            }
        #else
            answer(true)
        #endif
    }
}
