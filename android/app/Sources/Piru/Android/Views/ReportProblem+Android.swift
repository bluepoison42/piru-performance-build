// Report a Problem, Android's counterpart to TestFlight's crash reports: one text file with the
// app and device details, how Piru's recent processes ended (with the decoded tombstone of a
// native crash, which is what a Swift trap is under Skip Fuse), and the app's own logcat,
// written by Skip/AndroidDiagnostics.kt and handed to the share chooser. Nothing leaves the
// phone unless the user sends it. Settings shows the row (patches/0017-settings-report-a-problem.patch);
// after a crash the root view offers a report once; the launcher shortcut makes one without
// starting the UI.

import Foundation
import SkipBridge
import SwiftUI

private enum ReportProblemLinks {
    static let discord = URL(string: "https://discord.gg/hbpMZhPSdx")!
    static let issues = URL(string: "https://github.com/kageroumado/piru/issues/new")!
    static let guide = URL(string: "https://github.com/kageroumado/piru/blob/main/BUG-REPORTS.md")!
}

/// The Settings row that opens ``ReportProblemView``.
struct ReportProblemSection: View {
    var body: some View {
        Section {
            NavigationLink {
                ReportProblemView()
            } label: {
                Label("Report a Problem", systemImage: "ladybug")
            }
        }
    }
}

/// Writes the report and opens the share chooser, with where to send it.
struct ReportProblemView: View {
    @State private var report = ProblemReport()

    var body: some View {
        Form {
            Section {
                Button {
                    report.create()
                } label: {
                    HStack {
                        Label("Create Report", systemImage: "square.and.arrow.up")
                        Spacer()
                        if report.isWriting { ProgressView() }
                    }
                }
                .disabled(report.isWriting)
            } footer: {
                Text("One file with the app and Android versions, the phone model, how Piru's recent runs ended, any crash traces and Piru's own log. It holds nothing from your journal, and it leaves your phone only if you send it.")
            }
            .listRowBackground(CardBackground())

            Section {
                Link(destination: ReportProblemLinks.discord) {
                    Label("#bug-reports on Discord", systemImage: "arrow.up.right")
                }
                Link(destination: ReportProblemLinks.issues) {
                    Label("Open a GitHub Issue", systemImage: "arrow.up.right")
                }
                Link(destination: ReportProblemLinks.guide) {
                    Label("How to Report a Problem", systemImage: "arrow.up.right")
                }
            } header: {
                Text("Where to Send It")
            } footer: {
                Text("Attach the file and say what you were doing when it went wrong.")
            }
            .listRowBackground(CardBackground())
        }
        .themedPage()
        .navigationTitle("Report a Problem")
        .inlineNavigationTitle()
        .alert("The report could not be written.", isPresented: $report.failed) {
            Button("OK", role: .cancel) {}
        }
    }
}

/// Offers a report once after a crash, a native crash or an ANR ended the previous process.
struct ProblemReportPrompt: ViewModifier {
    @State private var isPresented = false
    @State private var report = ProblemReport()

    func body(content: Content) -> some View {
        content
            .task {
                guard AndroidDiagnostics.hasUnseenProblem else { return }
                AndroidDiagnostics.markSeen()
                isPresented = true
            }
            .alert("Piru Closed Unexpectedly", isPresented: $isPresented) {
                Button("Create Report") { report.create() }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("A report helps fix it. It holds how Piru closed and its own log, nothing from your journal, and you choose where it goes.")
            }
            .alert("The report could not be written.", isPresented: $report.failed) {
                Button("OK", role: .cancel) {}
            }
    }
}

/// One report being written, then shared.
@Observable
@MainActor
final class ProblemReport {
    private(set) var isWriting = false
    var failed = false

    func create() {
        guard !isWriting else { return }
        isWriting = true
        Task {
            // logcat and the trace streams are blocking reads.
            let path = await Task.detached(name: "Problem report") { AndroidDiagnostics.writeReport() }.value
            isWriting = false
            guard let path, AndroidDocuments.share(file: URL(fileURLWithPath: path)) else {
                failed = true
                return
            }
        }
    }
}

/// Calls into Skip/AndroidDiagnostics.kt.
nonisolated enum AndroidDiagnostics {
    private static var kotlin: AnyDynamicObject? {
        try? AnyDynamicObject(forStaticsOfClassName: "piru.module.AndroidDiagnostics")
    }

    /// The report's path in the cache, or `nil` when it could not be written.
    static func writeReport() -> String? {
        try? kotlin?.writeReport() as String?
    }

    /// Whether a crash, native crash or ANR ended a Piru process since the last report or the
    /// last prompt.
    static var hasUnseenProblem: Bool {
        (try? kotlin?.hasUnseenProblem() as Bool?) == true
    }

    static func markSeen() {
        _ = try? kotlin?.markSeen() as Void?
    }
}
