import AppIntents
import Foundation

/// "Log Dose": saves a dose straight to the journal, with no screen. For
/// Shortcuts, Siri and any automation that already knows what was taken — an
/// LLM shortcut that parses "27 mg of Concerta at 9:30 on an empty stomach"
/// hands it the pieces. Returns the entry's id so a shortcut can chain on it.
struct LogDoseIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Dose"
    static let description = IntentDescription(
        "Saves a dose to the journal without opening Piru.",
        categoryName: "Journal",
    )
    // Never `.alwaysAllowed`: a dose is health data, and this must not run
    // from Siri on a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Substance")
    var substance: SubstanceEntity

    @Parameter(title: "Amount", description: "Leave empty to log the dose with its amount unknown.")
    var amount: Double?

    @Parameter(title: "Unit", description: "The substance's usual unit for the route when empty.")
    var unit: String?

    @Parameter(title: "Route", description: "The substance's usual route when empty.")
    var route: RouteOfAdministration?

    @Parameter(title: "Time", description: "Now when empty.")
    var time: Date?

    @Parameter(title: "Meal", description: "What was eaten before an oral dose.")
    var meal: MealState?

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "Tags")
    var tags: [String]?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) \(\.$unit) of \(\.$substance)") {
            \.$route
            \.$time
            \.$meal
            \.$notes
            \.$tags
        }
    }

    // `perform` is nonisolated by inference, and the save and its summary read
    // main-actor state; the framework hops here for an async witness.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let entry = try await DoseIntentLogger.log(DoseIntentLogger.Request(
            name: substance.typedName,
            amount: amount,
            unit: unit,
            route: route,
            time: time,
            meal: meal,
            notes: notes,
            tags: tags ?? [],
        ))
        let summary = DoseIntentLogger.summary(for: entry)
        return .result(value: entry.id.uuidString, dialog: IntentDialog("Logged \(summary)."))
    }
}
