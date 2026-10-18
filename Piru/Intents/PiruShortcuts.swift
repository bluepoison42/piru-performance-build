import AppIntents

/// The App Shortcuts the Shortcuts app and Siri offer without setup. Both
/// take their parameters when invoked by voice ("Log a dose in Piru" asks for
/// the substance), and every parameter is available from the Shortcuts
/// editor.
nonisolated struct PiruShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogDoseIntent(),
            phrases: [
                "Log a dose in \(.applicationName)",
                "Log a dose with \(.applicationName)",
            ],
            shortTitle: "Log Dose",
            systemImageName: "pills",
        )
        AppShortcut(
            intent: StartDoseLogIntent(),
            phrases: [
                "Start a dose log in \(.applicationName)",
                "Start a dose log with \(.applicationName)",
            ],
            shortTitle: "Start Dose Log",
            systemImageName: "square.and.pencil",
        )
    }
}
