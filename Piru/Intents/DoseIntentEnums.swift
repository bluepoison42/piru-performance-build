import AppIntents

// The two enums the dose actions take as parameters. Literal dictionaries,
// because the App Intents metadata processor reads the display names from the
// source at build time; a dictionary built from `localizedName` compiles but
// leaves the Shortcuts picker without names.

nonisolated extension RouteOfAdministration: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Route"

    static let caseDisplayRepresentations: [RouteOfAdministration: DisplayRepresentation] = [
        .oral: "Oral",
        .sublingual: "Sublingual",
        .buccal: "Buccal",
        .insufflation: "Insufflation",
        .inhalation: "Inhalation",
        .intravenous: "Intravenous",
        .intramuscular: "Intramuscular",
        .subcutaneous: "Subcutaneous",
        .transdermal: "Transdermal",
        .rectal: "Rectal",
        .other: "Other",
    ]
}

nonisolated extension MealState: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meal"

    static let caseDisplayRepresentations: [MealState: DisplayRepresentation] = [
        .empty: "Empty stomach",
        .light: "Light snack",
        .full: "Full meal",
    ]
}
