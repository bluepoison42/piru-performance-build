// The update check's views (Android/Update/AppUpdateCheck+Android.swift): the launch sheet that
// announces a new version once, the Settings row that stays while the app is out of date, and
// the Settings toggle. Wired into upstream by patches/0024-app-update-check.patch.

import SkipFuse
import SwiftUI

/// The launch sheet for a new version: what it is, and the way to its release page.
struct AppUpdateSheet: View {
    let release: AppRelease
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: Spacing.xxl) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .padding(.top, Spacing.xxxl)
                .accessibilityHidden(true)

            Text("Piru \(release.version.description) is available")
                .font(.piru(.title2, weight: .bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("It is on GitHub, where Piru comes from, and installing it over this version keeps your journal.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Spacing.md) {
                GlassPillButton(title: "Download") {
                    openURL(release.page)
                    dismiss()
                }
                GlassPillButton(title: "Not Now", prominence: .neutral) { dismiss() }
            }
        }
        .padding(.horizontal, Spacing.xxxl)
        .padding(.bottom, Spacing.xxl)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// The top of Settings while a newer version exists.
struct AppUpdateSection: View {
    @State private var check = AppUpdateCheck.shared

    var body: some View {
        if let release = check.available {
            Section {
                Link(destination: release.page) {
                    Label("Piru \(release.version.description) is available", systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

/// The switch for the daily question to GitHub.
struct UpdateCheckSection: View {
    @AppStorage(AppUpdateCheck.enabledKey) private var isEnabled = true

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            .onChange(of: isEnabled) { AppUpdateCheck.shared.enabledChanged() }
        } footer: {
            Text("Once a day, Piru asks GitHub for the newest release. Nothing about you or your journal is sent.")
        }
    }
}
