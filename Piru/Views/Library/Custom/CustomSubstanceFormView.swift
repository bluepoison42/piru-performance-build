import SwiftUI

/// The form's edit state: one draft object instead of two dozen `@State`
/// fields, so the view is a thin renderer and the seeding / validation /
/// build logic is testable in one place. Mirrors `MedFormDraft` /
/// `EntryDraft`. Seeded once in `init` (held via `State(initialValue:)`,
/// so it resets with the sheet's identity, matching form semantics).
@Observable @MainActor
private final class CustomSubstanceDraft {
    /// Dose tiers — nil means "leave blank / keep library value".
    struct DoseTierFields {
        var threshold: Double?
        var lightMin: Double?
        var lightMax: Double?
        var commonMin: Double?
        var commonMax: Double?
        var strongMin: Double?
        var strongMax: Double?
        var heavy: Double?
    }

    struct DurationFields {
        var hasDuration = false
        var onsetMin: Double?
        var onsetMax: Double?
        var comeupMin: Double?
        var comeupMax: Double?
        var peakMin: Double?
        var peakMax: Double?
        var offsetMin: Double?
        var offsetMax: Double?
    }

    /// One compound of a combination draft: the picked substance and how much
    /// of it one unit of the product carries.
    struct ComponentDraft: Identifiable {
        let id = UUID()
        /// Canonical library name, or the raw name of a substance the library
        /// doesn't know.
        var substance: String
        /// What the row shows — the brand the user picked, else the display title.
        var displayName: String
        var amount: Double?
        var unit: String
        var route: RouteOfAdministration
        var availableRoutes: [RouteOfAdministration]
        var availableUnits: [String]

        static let defaultUnits = ["mg", "g", "µg", "mL", "IU"]

        /// A row for a library substance, opening on its default route and
        /// that route's unit, with the amount left for the label's strength.
        init(substance: Substance, displayName: String?) {
            self.substance = substance.name
            self.displayName = displayName ?? substance.displayTitle
            amount = nil
            route = substance.defaultRoute
            let defaultUnit = substance.unit(for: substance.defaultRoute)
            unit = defaultUnit
            availableRoutes = substance.orderedRoutes
            let others = Set(substance.routes.map(\.unit) + Self.defaultUnits).subtracting([defaultUnit])
            availableUnits = [defaultUnit] + others.sorted()
        }

        /// A row for a name the library doesn't carry.
        init(rawName: String) {
            substance = rawName
            displayName = rawName
            amount = nil
            unit = "mg"
            route = .oral
            availableRoutes = RouteOfAdministration.allCases
            availableUnits = Self.defaultUnits
        }

        /// A row restored from a saved component.
        init(component: CombinationComponent) {
            if let library = SubstanceLibrary.lookup(component.substance) {
                self.init(substance: library, displayName: CustomSubstanceStore.shared.displayName(for: library.name))
            } else {
                self.init(rawName: component.substance)
            }
            amount = component.amountPerUnit
            unit = component.unit
            route = component.route
            if !availableUnits.contains(component.unit) { availableUnits.insert(component.unit, at: 0) }
            if !availableRoutes.contains(component.route) { availableRoutes.append(component.route) }
        }
    }

    var name: String
    var displayName: String
    var category: SubstanceCategory
    var defaultRoute: RouteOfAdministration
    var unit: String
    var notes: String
    var doses = DoseTierFields()
    var halfLifeMinutes: Double?
    var duration = DurationFields()
    /// Combination mode: the entry is a product of several compounds, logged
    /// as one dose per component. Chosen once for a new entry; editing keeps it.
    var isCombination: Bool
    /// What one unit of the combination is called — "tablet", "capsule".
    var unitWord: String
    var components: [ComponentDraft]

    init(existing: CustomSubstanceEntry?, initialName: String?, personalizing: Substance?) {
        // Shipped route to seed personalize defaults from.
        let baseRoute = personalizing.flatMap { sub in
            sub.routes.first { $0.route == sub.defaultRoute } ?? sub.routes.first
        }

        name = personalizing?.name ?? existing?.name ?? initialName ?? ""
        displayName = existing?.displayName ?? ""
        category = existing?.category ?? personalizing?.category ?? .other
        defaultRoute = existing?.defaultRoute ?? personalizing?.defaultRoute ?? .oral
        isCombination = existing?.isCombination ?? false
        unit = (existing?.isCombination == true ? nil : existing?.unit) ?? baseRoute?.unit ?? "mg"
        unitWord = (existing?.isCombination == true ? existing?.unit : nil) ?? "dose"
        components = (existing?.components ?? []).map(ComponentDraft.init(component:))
        notes = existing?.notes ?? ""

        let seedDoses = existing?.doses ?? (existing == nil ? baseRoute?.doses : nil)
        doses.threshold = Self.positive(seedDoses?.threshold)
        doses.lightMin = Self.positive(seedDoses?.light?.lowerBound)
        doses.lightMax = Self.positive(seedDoses?.light?.upperBound)
        doses.commonMin = Self.positive(seedDoses?.common?.lowerBound)
        doses.commonMax = Self.positive(seedDoses?.common?.upperBound)
        doses.strongMin = Self.positive(seedDoses?.strong?.lowerBound)
        doses.strongMax = Self.positive(seedDoses?.strong?.upperBound)
        doses.heavy = Self.positive(seedDoses?.heavy)

        let halfLife = existing?.halfLifeMinutes ?? (existing == nil ? personalizing?.halfLifeMinutes : nil)
        halfLifeMinutes = Self.positive(halfLife)

        let seedDuration = existing?.duration ?? (existing == nil ? baseRoute?.duration : nil)
        duration.hasDuration = seedDuration != nil
        duration.onsetMin = Self.positive(seedDuration?.onset?.min)
        duration.onsetMax = Self.positive(seedDuration?.onset?.max)
        duration.comeupMin = Self.positive(seedDuration?.comeup?.min)
        duration.comeupMax = Self.positive(seedDuration?.comeup?.max)
        duration.peakMin = Self.positive(seedDuration?.peak?.min)
        duration.peakMax = Self.positive(seedDuration?.peak?.max)
        duration.offsetMin = Self.positive(seedDuration?.offset?.min)
        duration.offsetMax = Self.positive(seedDuration?.offset?.max)
    }

    /// Non-positive shipped values render as an empty field, matching the
    /// old "blank means unset" semantics.
    private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }

    // MARK: - Derived

    var unitLabel: String {
        unit.trimmingCharacters(in: .whitespaces).isEmpty ? "mg" : unit
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespaces)
    }

    var trimmedUnitWord: String {
        unitWord.trimmingCharacters(in: .whitespaces)
    }

    /// A name, and in combination mode at least one component — every one of
    /// them with an amount, since a row left blank is a strength nobody typed,
    /// not a zero.
    var canSave: Bool {
        guard !trimmedName.isEmpty else { return false }
        guard isCombination else { return true }
        return !components.isEmpty && components.allSatisfy { ($0.amount ?? 0) > 0 }
    }

    // MARK: - Builders

    func buildDoses() -> DoseRange? {
        func val(_ v: Double?) -> Double? {
            guard let v, v > 0 else { return nil }
            return v
        }
        func range(_ lo: Double?, _ hi: Double?) -> ClosedRange<Double>? {
            guard let l = val(lo) else { return nil }
            let h = val(hi) ?? l
            guard h >= l else { return nil }
            return l ... h
        }
        let dr = DoseRange(
            threshold: val(doses.threshold),
            light: range(doses.lightMin, doses.lightMax),
            common: range(doses.commonMin, doses.commonMax),
            strong: range(doses.strongMin, doses.strongMax),
            heavy: val(doses.heavy),
        )
        return dr.hasAnyValue ? dr : nil
    }

    func buildDuration() -> DurationProfile? {
        guard duration.hasDuration else { return nil }
        func range(_ min: Double?, _ max: Double?) -> DurationRange? {
            guard let lo = min, lo > 0 else { return nil }
            let hi = max ?? lo
            guard hi >= lo else { return nil }
            return DurationRange(min: lo, max: hi)
        }
        let onset = range(duration.onsetMin, duration.onsetMax)
        let comeup = range(duration.comeupMin, duration.comeupMax)
        let peak = range(duration.peakMin, duration.peakMax)
        let offset = range(duration.offsetMin, duration.offsetMax)
        guard onset != nil || comeup != nil || peak != nil || offset != nil else { return nil }
        return DurationProfile(onset: onset, comeup: comeup, peak: peak, offset: offset, afterglow: nil, total: nil)
    }

    func buildHalfLife() -> Double? {
        guard let v = halfLifeMinutes, v > 0 else { return nil }
        return v
    }

    func buildComponents() -> [CombinationComponent]? {
        guard isCombination else { return nil }
        let built = components.compactMap { row -> CombinationComponent? in
            guard let amount = row.amount, amount > 0 else { return nil }
            return CombinationComponent(substance: row.substance, amountPerUnit: amount, unit: row.unit, route: row.route)
        }
        return built.isEmpty ? nil : built
    }

    /// Write every draft field onto an entry — the one assignment block all
    /// three save modes share. A combination carries its unit word and its
    /// components and no pharmacology of its own; a compound the reverse.
    func apply(to entry: inout CustomSubstanceEntry) {
        entry.name = trimmedName
        entry.displayName = trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
        entry.category = category
        entry.notes = notes
        if isCombination {
            let components = buildComponents()
            entry.components = components
            entry.unit = trimmedUnitWord.isEmpty ? "dose" : trimmedUnitWord
            entry.defaultRoute = components?.first?.route ?? defaultRoute
            entry.doses = nil
            entry.duration = nil
            entry.halfLifeMinutes = nil
        } else {
            entry.components = nil
            entry.unit = unit
            entry.defaultRoute = defaultRoute
            entry.doses = buildDoses()
            entry.duration = buildDuration()
            entry.halfLifeMinutes = buildHalfLife()
        }
    }
}

/// Create/edit a net-new custom substance, or *personalize* a shipped one.
///
/// When `personalizing` is set, the form edits a personal override of that
/// library substance: the canonical `name` is fixed (it stays the logging/lookup
/// identity), a "Display as" field relabels it everywhere, and the dose / duration
/// / half-life fields pre-fill from the shipped values so the user edits from real
/// numbers. Both modes persist a `CustomSubstanceEntry` (keyed by canonical name).
struct CustomSubstanceFormView: View {
    /// Presented as a *local* sheet (quick-log search, custom list) as well as
    /// a navigator route — the environment dismiss targets whichever
    /// presentation actually owns it, where `navigator.dismiss()` would pop
    /// the navigator's top sheet out from under a local one.
    @Environment(\.dismiss) private var dismiss
    @State private var store = CustomSubstanceStore.shared

    var existing: CustomSubstanceEntry?
    /// The shipped substance being personalized. Nil for net-new customs.
    var personalizing: Substance?
    var onSaved: ((CustomSubstanceEntry) -> Void)?

    @State private var draft: CustomSubstanceDraft
    @State private var showDuplicateAlert = false
    @State private var showComponentPicker = false

    private var isEditing: Bool {
        existing != nil
    }
    private var isPersonalizing: Bool {
        personalizing != nil
    }

    init(
        existing: CustomSubstanceEntry? = nil,
        initialName: String? = nil,
        personalizing: Substance? = nil,
        onSaved: ((CustomSubstanceEntry) -> Void)? = nil,
    ) {
        self.existing = existing
        self.personalizing = personalizing
        self.onSaved = onSaved
        _draft = State(initialValue: CustomSubstanceDraft(
            existing: existing, initialName: initialName, personalizing: personalizing,
        ))
    }

    // MARK: - Rows

    private func rangeRow(_ label: LocalizedStringResource, min: Binding<Double?>, max: Binding<Double?>, suffix: LocalizedStringResource) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("min", value: min, format: .number)
            #if canImport(UIKit)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 56)
            #endif
            Text("–").foregroundStyle(Theme.secondaryLabel)
                .accessibilityHidden(true)
            TextField("max", value: max, format: .number)
            #if canImport(UIKit)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 56)
            #endif
            Text(suffix).foregroundStyle(Theme.secondaryLabel)
        }
    }

    private func singleRow(_ label: LocalizedStringResource, value: Binding<Double?>, suffix: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("amount", value: value, format: .number)
            #if canImport(UIKit)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 56)
            #endif
            Text(suffix).foregroundStyle(Theme.secondaryLabel)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                if isPersonalizing {
                    Section {
                        LabeledContent("Substance", value: draft.name)
                        TextField("Display as (e.g. joint)", text: $draft.displayName)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Display name")
                    } footer: {
                        Text("Shown everywhere in place of \"\(draft.name)\". Leave blank to keep the original name. Your dose history is unaffected.")
                    }
                } else {
                    Section("Name") {
                        // The kind is chosen once: a saved entry keeps it, since a
                        // compound's dose history and a combination's components
                        // mean different things.
                        if !isEditing {
                            Picker("Type", selection: $draft.isCombination.animation()) {
                                Text("Compound").tag(false)
                                Text("Combination").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        TextField(draft.isCombination ? "Product name (e.g. Co-codamol)" : "Substance name", text: $draft.name)
                            .autocorrectionDisabled()
                    }
                }

                Section("Classification") {
                    Picker("Category", selection: $draft.category) {
                        ForEach(SubstanceCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat)
                        }
                    }
                }

                if draft.isCombination {
                    combinationSections
                } else {
                    compoundSections
                }

                Section {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3 ... 6)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Optional notes about this substance for your reference.")
                }
            }
            .themedPage()
            .navigationTitle(navTitle)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .fontWeight(.semibold)
                    .disabled(!draft.canSave)
                    .accessibilityLabel(isEditing || isPersonalizing ? "Save" : "Add")
                }
            }
            .alert("Duplicate Name", isPresented: $showDuplicateAlert) {
                Button("OK") {}
            } message: {
                Text("A custom substance named \"\(draft.trimmedName)\" already exists.")
            }
            .sheet(isPresented: $showComponentPicker) {
                CombinationComponentPicker { picked in
                    withAnimation(.snappy) { draft.components.append(picked) }
                }
            }
        }
    }

    // MARK: - Combination sections

    /// The unit word and the components list — what a combination is made of,
    /// in place of a compound's dose tiers, half-life and duration.
    @ViewBuilder
    private var combinationSections: some View {
        Section {
            TextField("Unit (e.g. tablet, capsule)", text: $draft.unitWord)
                .autocorrectionDisabled()
                .neverAutocapitalize()
        } header: {
            Text("Unit")
        } footer: {
            Text("What one of these is called. Each component's amount is per unit.")
        }

        Section {
            ForEach($draft.components) { $component in
                CombinationComponentRow(component: $component, unitWord: draft.trimmedUnitWord.isEmpty ? "dose" : draft.trimmedUnitWord)
            }
            .onDelete { offsets in
                withAnimation(.snappy) { draft.components.remove(atOffsets: offsets) }
            }
            Button {
                showComponentPicker = true
            } label: {
                Label("Add Component", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Components")
        } footer: {
            Text("Picking this in the quick log stages one dose per component.")
        }
    }

    // MARK: - Compound sections

    @ViewBuilder
    private var compoundSections: some View {
        Section("Dosing Defaults") {
            Picker("Default Route", selection: $draft.defaultRoute) {
                ForEach(RouteOfAdministration.allCases) { route in
                    Text(route.localizedName).tag(route)
                }
            }
            TextField("Unit (e.g. mg, ml, µg)", text: $draft.unit)
                .autocorrectionDisabled()
        }

        Section {
            singleRow("Threshold", value: $draft.doses.threshold, suffix: draft.unitLabel)
            rangeRow("Light", min: $draft.doses.lightMin, max: $draft.doses.lightMax, suffix: "\(draft.unitLabel)")
            rangeRow("Common", min: $draft.doses.commonMin, max: $draft.doses.commonMax, suffix: "\(draft.unitLabel)")
            rangeRow("Strong", min: $draft.doses.strongMin, max: $draft.doses.strongMax, suffix: "\(draft.unitLabel)")
            singleRow("Heavy", value: $draft.doses.heavy, suffix: draft.unitLabel)
        } header: {
            Text("Reported Dose Ranges")
        } footer: {
            Text("Optional dose tiers, in your chosen unit. Leave blank to keep the library values.")
        }

        Section {
            HStack {
                Text("Half-life")
                Spacer()
                TextField("minutes", value: $draft.halfLifeMinutes, format: .number)
                #if canImport(UIKit)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                #endif
                Text("minutes").foregroundStyle(Theme.secondaryLabel)
            }
        } header: {
            Text("Half-life")
        } footer: {
            Text("Optional. Feeds the active-substance and clearance estimates.")
        }

        Section {
            Toggle("Custom duration", isOn: $draft.duration.hasDuration.animation())
            if draft.duration.hasDuration {
                rangeRow("Onset", min: $draft.duration.onsetMin, max: $draft.duration.onsetMax, suffix: "minutes")
                rangeRow("Come-up", min: $draft.duration.comeupMin, max: $draft.duration.comeupMax, suffix: "minutes")
                rangeRow("Peak", min: $draft.duration.peakMin, max: $draft.duration.peakMax, suffix: "minutes")
                rangeRow("Offset", min: $draft.duration.offsetMin, max: $draft.duration.offsetMax, suffix: "minutes")
            }
        } header: {
            Text("Duration")
        } footer: {
            Text(
                draft.duration.hasDuration
                    ? "Minutes for each phase. Leave a phase blank to skip it; the timeline will interpolate from what you provide."
                    : "Add per-phase timing so this substance gets a Live-Activity timeline like library substances.",
            )
        }
    }

    private var navTitle: LocalizedStringResource {
        if isPersonalizing { return "Personalize" }
        if draft.isCombination { return isEditing ? "Edit Combination" : "New Combination" }
        return isEditing ? "Edit Substance" : "New Custom Substance"
    }

    // MARK: - Save

    private func save() {
        guard draft.canSave else { return }

        let saved: CustomSubstanceEntry

        if isPersonalizing {
            // Personalize mode: the entry is keyed by the canonical name. Update
            // an existing override or create one; never a rename, so no collision.
            var entry = existing ?? CustomSubstanceEntry(name: draft.trimmedName)
            draft.apply(to: &entry)
            if existing != nil { store.update(entry) } else { store.add(entry) }
            saved = entry
        } else if let existing {
            // Editing a net-new custom: allow rename unless it collides.
            if let collision = store.first(whereName: draft.trimmedName), collision.id != existing.id {
                showDuplicateAlert = true
                return
            }
            var updated = existing
            draft.apply(to: &updated)
            store.update(updated)
            saved = updated
        } else {
            if store.contains(name: draft.trimmedName) {
                showDuplicateAlert = true
                return
            }
            var entry = CustomSubstanceEntry(name: draft.trimmedName)
            draft.apply(to: &entry)
            store.add(entry)
            saved = entry
        }

        onSaved?(saved)
        dismiss()
    }
}

// MARK: - Component row

/// One compound of a combination: its name, then the amount per unit with its
/// unit, then the route it is taken by.
private struct CombinationComponentRow: View {
    @Binding var component: CustomSubstanceDraft.ComponentDraft
    let unitWord: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(component.displayName)
                .font(.body.weight(.medium))
            HStack {
                TextField("amount", value: $component.amount, format: .number)
                    .accessibilityLabel(Text("Amount per \(unitWord)"))
                    .decimalKeyboard()
                Picker("Unit", selection: $component.unit) {
                    ForEach(component.availableUnits, id: \.self) { Text($0) }
                }
                .labelsHidden()
                Text("per \(unitWord)")
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Picker("Route", selection: $component.route) {
                ForEach(component.availableRoutes) { route in
                    Text(route.localizedName).tag(route)
                }
            }
        }
    }
}

// MARK: - Component picker

/// The My Meds substance picker, hosted in a sheet: the search field over the
/// library, with a "Use …" row for a name the library doesn't carry. One pick
/// appends a component and closes the sheet.
private struct CombinationComponentPicker: View {
    let onPick: (CustomSubstanceDraft.ComponentDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Component") {
                    SubstanceSearchField(text: $query, keepsMatchedName: true) { substance, matched in
                        // The brand the query matched names the row; the canonical
                        // name stays the component's identity.
                        let brand = matched?.trimmingCharacters(in: .whitespaces)
                        onPick(.init(substance: substance, displayName: brand?.isEmpty == false ? brand : nil))
                        dismiss()
                    } onCustom: {
                        let name = query.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        onPick(.init(rawName: name))
                        dismiss()
                    }
                }
                .listRowBackground(CardBackground())
            }
            .themedPage()
            .navigationTitle("Add Component")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 420)
        #endif
    }
}
