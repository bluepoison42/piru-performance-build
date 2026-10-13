// Android Piru is installed from GitHub releases, so nothing tells its users a new version is
// out. At launch, at most once a day, the app asks GitHub for the repository's release list and
// remembers the newest Android release. While it is newer than the installed app it raises one
// launch sheet per version and a row at the top of Settings. With Check for Updates off in
// Settings the app makes no request at all. Wired into upstream by
// patches/0024-app-update-check.patch; the views are in Android/Views/AppUpdate+Android.swift.

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import SkipFuse

/// Asks GitHub for the newest Android release and remembers the answer.
@Observable
@MainActor
final class AppUpdateCheck {
    static let shared = AppUpdateCheck()

    /// The Settings toggle's key; absent reads as on.
    static let enabledKey = "appUpdate.checkEnabled"
    private static let checkedKey = "appUpdate.lastChecked"
    private static let tagKey = "appUpdate.latestTag"
    private static let pageKey = "appUpdate.latestPage"
    private static let announcedKey = "appUpdate.announcedTag"
    #if DEBUG
        /// `piruInstalledVersion`: the version the check compares against, to see the sheet and
        /// the row on a current build.
        private static let installedVersionOverrideKey = "piruInstalledVersion"
    #endif

    /// Anonymous: no token, no identifier, nothing about the user or the journal.
    private nonisolated static let releaseListURL = URL(string: "https://api.github.com/repos/kageroumado/piru/releases?per_page=30")!
    private static let interval: TimeInterval = 24 * 60 * 60
    private nonisolated static let timeout: TimeInterval = 20

    private static let log = Logger(subsystem: "piru", category: "update")

    /// The newest Android release, while it is newer than this install.
    private(set) var available: AppRelease?

    private let defaults = UserDefaults.standard
    private var launchCheck: Task<Void, Never>?

    private init() {
        available = isEnabled ? newerThanInstalled(rememberedRelease) : nil
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// The release the launch sheet announces: the available one, once per version.
    var releaseToAnnounce: AppRelease? {
        guard let available, defaults.string(forKey: Self.announcedKey) != available.tag else { return nil }
        return available
    }

    /// Retires the launch sheet for this release's version.
    func markAnnounced(_ release: AppRelease) {
        defaults.set(release.tag, forKey: Self.announcedKey)
    }

    /// Starts this launch's check, once. It runs off the main actor and never delays launch.
    func startLaunchCheck() {
        guard launchCheck == nil else { return }
        launchCheck = Task(name: "Update check") { await check() }
    }

    /// Returns once this launch's check has answered or given up, starting it if nothing has.
    func finishLaunchCheck() async {
        startLaunchCheck()
        await launchCheck?.value
    }

    /// The Settings toggle moved. Off forgets what was found, so nothing shows from an old
    /// answer; on asks right away.
    func enabledChanged() {
        if isEnabled {
            launchCheck = Task(name: "Update check") { await check() }
        } else {
            available = nil
            for key in [Self.checkedKey, Self.tagKey, Self.pageKey] {
                defaults.removeObject(forKey: key)
            }
            Self.log.info("checks are off; forgot the last answer")
        }
    }

    private func check() async {
        guard isEnabled else {
            Self.log.info("skipped: checks are off")
            return
        }
        let lastChecked = defaults.double(forKey: Self.checkedKey)
        guard Date().timeIntervalSince1970 - lastChecked >= Self.interval else {
            Self.log.info("skipped: asked GitHub within the last day")
            return
        }
        Self.log.info("asking GitHub for the newest release")
        switch await Self.fetchNewestRelease() {
        case .unreachable:
            Self.log.info("GitHub could not be reached")
        case let .refused(status):
            // Counts as asked, so a rate limit is not hit again at every launch.
            defaults.set(Date().timeIntervalSince1970, forKey: Self.checkedKey)
            Self.log.info("GitHub answered \(status, privacy: .public)")
        case let .answered(newest):
            guard isEnabled else { return }
            defaults.set(Date().timeIntervalSince1970, forKey: Self.checkedKey)
            remember(newest)
            available = newerThanInstalled(newest)
            Self.log.info("newest release \(newest?.tag ?? "none", privacy: .public), installed \(Self.installedVersion ?? "unknown", privacy: .public)")
        }
    }

    private enum FetchResult: Sendable {
        case answered(AppRelease?)
        case refused(Int)
        case unreachable
    }

    @concurrent
    private nonisolated static func fetchNewestRelease() async -> FetchResult {
        var request = URLRequest(url: releaseListURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .unreachable }
        guard status == 200 else { return .refused(status) }
        return .answered(AppRelease.newest(inReleaseList: data))
    }

    private var rememberedRelease: AppRelease? {
        guard let tag = defaults.string(forKey: Self.tagKey), let page = defaults.string(forKey: Self.pageKey) else {
            return nil
        }
        return AppRelease(tag: tag, page: page)
    }

    private func remember(_ release: AppRelease?) {
        if let release {
            defaults.set(release.tag, forKey: Self.tagKey)
            defaults.set(release.page.absoluteString, forKey: Self.pageKey)
        } else {
            defaults.removeObject(forKey: Self.tagKey)
            defaults.removeObject(forKey: Self.pageKey)
        }
    }

    private func newerThanInstalled(_ release: AppRelease?) -> AppRelease? {
        guard let release, let installed = Self.installedVersion, release.isNewer(than: installed) else { return nil }
        return release
    }

    private static var installedVersion: String? {
        #if DEBUG
            if let override = UserDefaults.standard.string(forKey: installedVersionOverrideKey) {
                return override
            }
        #endif
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
