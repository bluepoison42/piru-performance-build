import Foundation
import Testing

@Suite("AppVersion")
struct AppVersionTests {
    @Test
    func `Compares number by number, not as text`() throws {
        let v19 = try #require(AppVersion("1.9"))
        let v110 = try #require(AppVersion("1.10"))
        let v2 = try #require(AppVersion("2"))
        #expect(v19 < v110)
        #expect(v110 < v2)
        #expect(try #require(AppVersion("0.9.9")) < #require(AppVersion("1.0")))
    }

    @Test
    func `Missing trailing components count as zero`() throws {
        #expect(try #require(AppVersion("1.1")) == #require(AppVersion("1.1.0")))
        #expect(try !(#require(AppVersion("1.1")) < #require(AppVersion("1.1.0"))))
        #expect(try #require(AppVersion("1.1")) < #require(AppVersion("1.1.1")))
    }

    @Test(arguments: [
        "", ".", "1.", ".1", "1..2", "1.0-a3", "v1.1", "1.1-b65", "1.x", "1 .1", "-1", "１.２", "99999999999999999999999",
    ])
    func `Reads only whole numbers separated by dots`(_ text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test
    func `Writes itself back out`() {
        #expect(AppVersion("1.10.0")?.description == "1.10.0")
    }
}

@Suite("AppRelease")
struct AppReleaseTests {
    private static let page = "https://github.com/kageroumado/piru/releases/tag/"

    private func listing(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> AppRelease.Listing {
        AppRelease.Listing(tag: tag, page: Self.page + tag, isDraft: draft, isPrerelease: prerelease)
    }

    @Test
    func `Picks the highest Android version, numerically`() {
        let newest = AppRelease.newest(in: [
            listing("android-v1.9"),
            listing("android-v1.10"),
            listing("android-v1.2"),
        ])
        #expect(newest?.tag == "android-v1.10")
        #expect(newest?.page.absoluteString == Self.page + "android-v1.10")
    }

    @Test
    func `Ignores drafts and prereleases`() {
        let newest = AppRelease.newest(in: [
            listing("android-v1.1"),
            listing("android-v1.3", draft: true),
            listing("android-v1.2", prerelease: true),
        ])
        #expect(newest?.tag == "android-v1.1")
    }

    @Test
    func `Ignores entries that do not say whether they are drafts or prereleases`() {
        let unstated = AppRelease.Listing(tag: "android-v2.0", page: Self.page + "android-v2.0", isDraft: nil, isPrerelease: false)
        #expect(AppRelease.newest(in: [unstated, listing("android-v1.1")])?.tag == "android-v1.1")
    }

    @Test(arguments: [
        "v1.1", "v1.1-b65", "db", "android-v1.0-a3", "android-v", "android-1.2", "Android-v1.2", "android-v1.2-rc1",
    ])
    func `Ignores tags that are not Android releases`(_ tag: String) {
        #expect(AppRelease.newest(in: [listing(tag)]) == nil)
        #expect(AppRelease.newest(in: [listing(tag), listing("android-v1.1")])?.tag == "android-v1.1")
    }

    @Test
    func `Ignores a release whose page is not on the repository's releases`() {
        let elsewhere = AppRelease.Listing(tag: "android-v9.0", page: "https://example.com/piru.apk", isDraft: false, isPrerelease: false)
        #expect(AppRelease.newest(in: [elsewhere]) == nil)
    }

    @Test
    func `Reads GitHub's release list`() throws {
        let json = """
        [
          {"tag_name": "v1.1", "html_url": "https://github.com/kageroumado/piru/releases/tag/v1.1", "draft": false, "prerelease": false},
          {"tag_name": "android-v1.1", "html_url": "https://github.com/kageroumado/piru/releases/tag/android-v1.1", "draft": false, "prerelease": false, "assets": [{"name": "Piru-1.1.apk"}]},
          {"tag_name": "android-v1.0-a3", "html_url": "https://github.com/kageroumado/piru/releases/tag/android-v1.0-a3", "draft": false, "prerelease": true},
          {"tag_name": 12, "html_url": null, "draft": "no", "prerelease": false},
          {"tag_name": "db", "html_url": "https://github.com/kageroumado/piru/releases/tag/db", "draft": false, "prerelease": false}
        ]
        """
        let newest = try #require(AppRelease.newest(inReleaseList: Data(json.utf8)))
        #expect(newest.tag == "android-v1.1")
        #expect(newest.version == AppVersion("1.1"))
    }

    @Test(arguments: [
        "", "not json", "{}", #"{"message": "API rate limit exceeded"}"#, "[1, 2]", "[]",
    ])
    func `Reads nothing from a body that is not a release list`(_ body: String) {
        #expect(AppRelease.newest(inReleaseList: Data(body.utf8)) == nil)
    }

    @Test
    func `Is newer only than an older installed version`() throws {
        let release = try #require(AppRelease(tag: "android-v1.10", page: Self.page + "android-v1.10"))
        #expect(release.isNewer(than: "1.9"))
        #expect(release.isNewer(than: "1.2.5"))
        #expect(!release.isNewer(than: "1.10"))
        #expect(!release.isNewer(than: "1.10.0"))
        #expect(!release.isNewer(than: "1.11"))
        #expect(!release.isNewer(than: "2.0"))
    }

    @Test(arguments: ["", "—", "1.0-a3", "unknown"])
    func `Is newer than nothing when the installed version cannot be read`(_ installed: String) throws {
        let release = try #require(AppRelease(tag: "android-v1.10", page: Self.page + "android-v1.10"))
        #expect(!release.isNewer(than: installed))
    }
}
