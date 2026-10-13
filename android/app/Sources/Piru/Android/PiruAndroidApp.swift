// The Android entry point, standing in for Piru/PiruApp.swift (excluded: its `@main App`
// is Darwin-only). Skip's generated MainActivity shows `PiruRootView` and forwards the
// activity lifecycle to `PiruAppDelegate`. Launch and lifecycle policy is AppLaunch's, the
// same calls PiruApp makes; this host adds only what Android owns.

import Foundation
import SkipFuse
import SwiftData
import SwiftUI

/* SKIP @bridge */ public struct PiruRootView: View {
    /* SKIP @bridge */ public init() {}

    public var body: some View {
        ContentView()
            .modelContainer(PiruAndroidLaunch.container)
            .task {
                await AppLaunch.finishLaunching(container: PiruAndroidLaunch.container)
                PiruAndroidLaunch.finishedLaunching = true
            }
            .modifier(ProblemReportPrompt())
    }
}

/* SKIP @bridge */ public final class PiruAppDelegate: Sendable {
    /* SKIP @bridge */ public static let shared = PiruAppDelegate()

    private init() {}

    /// Runs from Application.onCreate, before any view or model reads the time zone.
    /* SKIP @bridge */ public func onInit() {
        AndroidPlatform.adoptDeviceTimeZone()
        UNUserNotificationCenter.current().delegate = AndroidNotificationDelegate.shared
        PortableDataLog.install { category, message in
            Logger(subsystem: "PortableData", category: category).error("\(message, privacy: .public)")
        }
    }

    /* SKIP @bridge */ public func onTimeZoneChanged(_ identifier: String) {
        AndroidPlatform.adoptDeviceTimeZone(identifier)
    }

    /* SKIP @bridge */ public func onLaunch() {}

    /// A tap on one of the app's notifications: the string extras of the intent it opened the
    /// activity with, which are the request's userInfo.
    /* SKIP @bridge */ public func onNotificationTap(_ userInfo: [String: String]) {
        AndroidNotificationDelegate.shared.receiveTap(userInfo: userInfo)
    }

    /// A return to the foreground. The activity also resumes as it launches, which on iOS is
    /// the launch task's work, so a resume counts only once the launch passes have run.
    /* SKIP @bridge */ public func onResume() {
        guard PiruAndroidLaunch.finishedLaunching else { return }
        AppLaunch.becameActive(container: PiruAndroidLaunch.container)
    }

    /// Pending edits are saved before Android may stop the process: autosave waits for the
    /// next main-actor turn, which a killed process never reaches.
    /* SKIP @bridge */ public func onPause() {
        guard PiruAndroidLaunch.finishedLaunching else { return }
        MainActor.assumeIsolated {
            try? PiruAndroidLaunch.container.flush()
        }
        Task { await AppLaunch.enteredBackground(container: PiruAndroidLaunch.container) }
    }

    /* SKIP @bridge */ public func onStop() {}
    /* SKIP @bridge */ public func onDestroy() {}
    /* SKIP @bridge */ public func onLowMemory() {}
}

@MainActor
enum PiruAndroidLaunch {
    static var finishedLaunching = false

    static let container: ModelContainer = {
        // iOS creates an app's Documents folder with its sandbox; Android's files/Documents
        // exists only once made, and the stores inside it cannot open without it.
        for directory in [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory, .cachesDirectory] {
            if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        return AppLaunch.openStore()
    }()
}
