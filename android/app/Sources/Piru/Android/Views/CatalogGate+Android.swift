// The launch gate for the substance catalog. Android serves the catalog as a copy taken out of
// the APK (Platform/Resources+Android.swift), and that copy can fail on a full phone. The shared
// accessor, `SubstanceStore.bundledSubstancesDBURL()`, answers a missing catalog with
// `fatalError`, so the copy is made here first, before any view or store reads the catalog.

import Foundation
import SkipFuse
import SwiftUI

/// `content` once the substance catalog is on disk; otherwise the screen that says why it is
/// not, with a way to try again.
struct CatalogGate<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var catalog = AndroidResources.copiedURL(for: AndroidResources.catalogFile)

    var body: some View {
        switch catalog {
        case .success:
            content()
        case let .failure(failure):
            CatalogCopyFailedView(failure: failure) {
                catalog = AndroidResources.copiedURL(for: AndroidResources.catalogFile)
            }
        }
    }
}

/// Why the substance catalog could not be copied onto the phone, and the retry. It reads no
/// store or skin: nothing behind the gate has opened.
private struct CatalogCopyFailedView: View {
    let failure: AndroidResources.CopyFailure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xxl) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Piru Couldn't Set Up Its Substance Library")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            explanation
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Try Again") { retry() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        if case .insufficientSpace = failure { "internaldrive" } else { "exclamationmark.triangle" }
    }

    private var explanation: Text {
        switch failure {
        case .missing:
            Text("This copy of Piru is missing its substance library. Installing Piru again from its release page restores it and keeps your journal.")
        case let .insufficientSpace(needed):
            Text("Setting up the substance library needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) of free space on this phone. Free up some space, then try again. Your journal is untouched.")
        case let .failed(reason):
            Text("The substance library couldn't be copied onto this phone (\(reason)). Your journal is untouched.")
        }
    }
}
