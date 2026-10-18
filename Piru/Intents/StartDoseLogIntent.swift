import AppIntents
import Foundation

/// "Start Dose Log": opens Piru on the quick log with the dose staged for
/// review. Nothing is saved until the person taps Log — the review step for an
/// automation that is not sure enough to use ``LogDoseIntent``. Every
/// parameter is optional; with none, it opens the quick log empty.
struct StartDoseLogIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dose Log"
    static let description = IntentDescription(
        "Opens Piru with a dose staged in the quick log, ready to review and save.",
        categoryName: "Journal",
    )
    static let openAppWhenRun = true

    @Parameter(title: "Substance")
    var substance: SubstanceEntity?

    @Parameter(title: "Amount", description: "Leave empty to open the dose editor on the usual dose.")
    var amount: Double?

    @Parameter(title: "Unit")
    var unit: String?

    @Parameter(title: "Route")
    var route: RouteOfAdministration?

    @Parameter(title: "Time")
    var time: Date?

    @Parameter(title: "Meal", description: "What was eaten before an oral dose.")
    var meal: MealState?

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "Tags")
    var tags: [String]?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a dose log for \(\.$substance)") {
            \.$amount
            \.$unit
            \.$route
            \.$time
            \.$meal
            \.$notes
            \.$tags
        }
    }

    // `perform` is nonisolated by inference and the navigator is main-actor
    // state; the framework hops here for an async witness.
    @MainActor
    func perform() async throws -> some IntentResult {
        let prefill = DosePrefill(
            amount: amount,
            unit: unit,
            time: time,
            meal: meal,
            note: notes,
            tags: tags.flatMap { $0.isEmpty ? nil : $0 },
        )
        let navigator = AppNavigator.shared
        // A quick log already on top would swallow the new one and keep whatever
        // it had staged; the automation asked for this dose, so start clean.
        navigator.dismissAll()
        navigator.apply(DeepLinkOutcome(sheet: .quickLog(
            routine: nil,
            prefillSubstance: substance?.typedName,
            prefillDose: prefill == DosePrefill() ? nil : prefill,
            prefillRoute: route,
        )))
        return .result()
    }
}
