// Which Android release on GitHub is the newest, and whether it is newer than the installed app.
// Pure, so it is tested on macOS: android/Compat/Tests/AppReleaseTests compiles this file.
// AppUpdateCheck+Android.swift does the asking and the remembering.

import Foundation

/// A release version: whole numbers separated by dots, compared number by number, so 1.10 is
/// newer than 1.9 and 1.1 equals 1.1.0.
nonisolated struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let components: [Int]

    /// Reads `1.2` or `1.2.3`; anything else, a suffix like `1.0-a3` included, is no version.
    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ ("0" ... "9").contains($0) }), let value = Int(part) else {
                return nil
            }
            components.append(value)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    /// Missing trailing components count as zero.
    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> Int {
        for index in 0 ..< max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

/// A published Android release of Piru: its tag is `android-v` and a version, and its page is
/// on the repository's releases.
nonisolated struct AppRelease: Equatable, Sendable {
    static let tagPrefix = "android-v"
    static let pagePrefix = "https://github.com/kageroumado/piru/releases/"

    let version: AppVersion
    let tag: String
    /// The release's page on GitHub, where the APK is.
    let page: URL

    init?(tag: String, page: String) {
        guard tag.hasPrefix(Self.tagPrefix),
              let version = AppVersion(String(tag.dropFirst(Self.tagPrefix.count))),
              page.hasPrefix(Self.pagePrefix),
              let url = URL(string: page)
        else { return nil }
        self.version = version
        self.tag = tag
        self.page = url
    }

    /// One entry of GitHub's release list, with only the fields read here. A field that is
    /// missing or of the wrong type reads as absent, so one odd entry never hides the rest.
    struct Listing: Decodable, Equatable {
        var tag: String?
        var page: String?
        var isDraft: Bool?
        var isPrerelease: Bool?

        init(tag: String?, page: String?, isDraft: Bool?, isPrerelease: Bool?) {
            self.tag = tag
            self.page = page
            self.isDraft = isDraft
            self.isPrerelease = isPrerelease
        }

        private enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
            case isDraft = "draft"
            case isPrerelease = "prerelease"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tag = try? container.decode(String.self, forKey: .tag)
            page = try? container.decode(String.self, forKey: .page)
            isDraft = try? container.decode(Bool.self, forKey: .isDraft)
            isPrerelease = try? container.decode(Bool.self, forKey: .isPrerelease)
        }
    }

    /// The release a listing describes, when it is a published Android release: an entry that
    /// does not say it is neither a draft nor a prerelease is left out.
    init?(listing: Listing) {
        guard listing.isDraft == false, listing.isPrerelease == false,
              let tag = listing.tag, let page = listing.page
        else { return nil }
        self.init(tag: tag, page: page)
    }

    /// The newest published Android release in a list, or `nil` when there is none.
    static func newest(in listings: [Listing]) -> AppRelease? {
        listings.compactMap(AppRelease.init(listing:)).max { $0.version < $1.version }
    }

    /// The newest published Android release in the body of GitHub's release list, or `nil`
    /// when the body is not a list or holds none.
    static func newest(inReleaseList data: Data) -> AppRelease? {
        guard let listings = try? JSONDecoder().decode([Listing].self, from: data) else { return nil }
        return newest(in: listings)
    }

    /// Whether this release is newer than the installed version; `false` when that cannot be read.
    func isNewer(than installed: String) -> Bool {
        guard let installed = AppVersion(installed) else { return false }
        return version > installed
    }
}
