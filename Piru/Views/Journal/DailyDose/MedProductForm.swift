import SwiftData
import SwiftUI

// MARK: - Draft

/// One compound of a product draft: the picked substance and how much of it
/// one unit (or one mL) of the product carries.
struct ProductComponentDraft: Identifiable {
    let id = UUID()
    /// Canonical library name, or the raw name of a substance the library
    /// doesn't know.
    var substance: String
    /// What the row shows: the brand the user picked, else the display title.
    var displayName: String
    var productName: String?
    var isomer: String?
    var releaseForm: String?
    var saltForm: String?
    var amount: Double?
    var unit: String
    var route: RouteOfAdministration
    var availableRoutes: [RouteOfAdministration]
    var availableUnits: [String]

    static let defaultUnits = ["mg", "g", "µg", "mL", "IU"]

    /// A row for a library substance, opening on its default route and that
    /// route's unit, with the amount left for the label's strength.
    init(substance: Substance, displayName: String?) {
        self.substance = substance.name
        self.displayName = displayName ?? substance.displayTitle
        productName = displayName
        isomer = DoseTrayModel.seedIsomer(productName: displayName, librarySubstance: substance, route: substance.defaultRoute)
        releaseForm = SubstanceLibrary.releaseForm(for: displayName ?? substance.name)
        saltForm = nil
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
        productName = nil
        isomer = nil
        releaseForm = nil
        saltForm = nil
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
        productName = component.productName
        isomer = component.isomer
        releaseForm = component.releaseForm
        saltForm = component.saltForm
        if let productName { displayName = productName }
        if !availableUnits.contains(component.unit) { availableUnits.insert(component.unit, at: 0) }
        if !availableRoutes.contains(component.route) { availableRoutes.append(component.route) }
    }
}

/// The edit state of a product: a single compound taken as a liquid, or a
/// compounded product of several (co-codamol), solid or liquid. Saved as a
/// ``CustomSubstanceEntry`` with components, which a med (``DailyDoseItem``)
/// then names.
@Observable
@MainActor
final class MedProductDraft {
    var name = ""
    /// Each component's amount is per mL and the product is taken by volume.
    /// Saved as the unit word "mL" (``CombinationComponent/volumeUnitWord``),
    /// which is what makes a product a liquid.
    var isLiquid = false
    /// What one unit of a solid product is called, saved as the product's unit.
    var unitWord = ProductUnitWord.standard.rawValue
    var components: [ProductComponentDraft] = []
    /// The saved product this draft edits. `nil` for a new one.
    let existing: CustomSubstanceEntry?

    init() {
        existing = nil
    }

    init(product: CustomSubstanceEntry) {
        existing = product
        name = product.name
        isLiquid = product.isLiquidCombination
        if !product.isLiquidCombination { unitWord = product.unit }
        components = (product.components ?? []).map(ProductComponentDraft.init(component:))
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// The word the product is saved under and its amounts are "per".
    var savedUnitWord: String {
        isLiquid ? CombinationComponent.volumeUnitWord : unitWord
    }

    /// The solid unit words the picker offers: the standard ones, and a word
    /// an older product was typed with ("dose") so it keeps its own.
    var unitWordChoices: [String] {
        let standard = ProductUnitWord.allCases.map(\.rawValue)
        return standard.contains(unitWord) ? standard : standard + [unitWord]
    }

    /// A name, and at least one component, every one of them with an amount,
    /// since a row left blank is a strength nobody typed, not a zero.
    var canSave: Bool {
        !trimmedName.isEmpty && !components.isEmpty && components.allSatisfy { ($0.amount ?? 0) > 0 }
    }

    /// Whether the name belongs to something else: another custom entry, or a
    /// library substance's own name, which a product of that name would shadow
    /// in every lookup.
    func nameIsTaken(in store: CustomSubstanceStore) -> Bool {
        let name = trimmedName
        if let other = store.first(whereName: name), other.id != existing?.id { return true }
        let keepsOwnName = existing?.name.caseInsensitiveCompare(name) == .orderedSame
        if !keepsOwnName, let library = SubstanceLibrary.lookup(name), library.name.caseInsensitiveCompare(name) == .orderedSame {
            return true
        }
        return false
    }

    /// The saved entry: the existing one updated in place, else a new one. A
    /// product carries its unit word and components and no pharmacology of
    /// its own; each component brings its substance's.
    func makeEntry() -> CustomSubstanceEntry {
        var entry = existing ?? CustomSubstanceEntry(name: trimmedName)
        let built = components.compactMap { row -> CombinationComponent? in
            guard let amount = row.amount, amount > 0 else { return nil }
            return CombinationComponent(
                substance: row.substance, amountPerUnit: amount, unit: row.unit, route: row.route,
                productName: row.productName, isomer: row.isomer, releaseForm: row.releaseForm, saltForm: row.saltForm,
            )
        }
        entry.name = trimmedName
        entry.unit = savedUnitWord
        entry.components = built.isEmpty ? nil : built
        entry.defaultRoute = built.first?.route ?? .oral
        entry.doses = nil
        entry.duration = nil
        entry.halfLifeMinutes = nil
        return entry
    }
}

// MARK: - Sections

/// The product's name.
struct MedProductNameSection: View {
    @Bindable var draft: MedProductDraft

    var body: some View {
        Section("Product") {
            TextField("Product name (e.g. Co-codamol)", text: $draft.name)
                .autocorrectionDisabled()
        }
    }
}

/// What one unit of a solid product is called. A liquid has no word to pick:
/// it is measured in mL.
struct MedProductUnitSection: View {
    @Bindable var draft: MedProductDraft

    var body: some View {
        Section {
            if !draft.isLiquid {
                Picker("Unit", selection: $draft.unitWord) {
                    ForEach(draft.unitWordChoices, id: \.self) { word in
                        if let known = ProductUnitWord(rawValue: word) {
                            Text(known.pickerLabel).tag(word)
                        } else {
                            Text(verbatim: word).tag(word)
                        }
                    }
                }
            }
        } footer: {
            if draft.isLiquid {
                Text("Each component's amount is per mL, and logging it asks for the volume you took.")
            } else {
                Text("Each component's amount is per unit.")
            }
        }
    }
}

/// The product's components, each with its amount per unit (or per mL), and
/// the button that adds one. A single compound taken as a liquid holds one.
/// The form root presents the picker, through `productComponentPicker`.
struct MedProductComponentsSection: View {
    @Bindable var draft: MedProductDraft
    /// Whether more than one component may be added: a compounded product.
    let allowsSeveral: Bool
    let onAdd: () -> Void

    var body: some View {
        Section {
            ForEach($draft.components) { $component in
                ProductComponentRow(component: $component, unitWord: draft.savedUnitWord)
            }
            .onDelete { offsets in
                withAnimation(.snappy) { draft.components.remove(inRangeOffsets: offsets) }
            }
            if allowsSeveral || draft.components.isEmpty {
                Button(action: onAdd) {
                    Label(allowsSeveral ? "Add Component" : "Choose Substance", systemImage: "plus.circle.fill")
                }
            }
        } header: {
            Text(allowsSeveral ? "Components" : "Substance")
        }
    }
}

extension View {
    /// Presents the component picker that appends to `draft`. Attach it to the
    /// form's root, never to a `Section` or a row: a List spreads a section's
    /// modifiers over its rows and rebuilds them as the form changes, which
    /// tears the presenter down and dismisses the sheet as it appears.
    func productComponentPicker(isPresented: Binding<Bool>, draft: MedProductDraft, allowsSeveral: Bool) -> some View {
        sheet(isPresented: isPresented) {
            ProductComponentPicker { picked in
                withAnimation(.snappy) { draft.components.append(picked) }
                // A single compound's liquid is named after it until the user
                // names it otherwise.
                if !allowsSeveral, draft.trimmedName.isEmpty {
                    draft.name = String(localized: "\(picked.displayName) solution")
                }
            }
        }
    }
}

/// How much of the product one dose of the med is: a count of units for a
/// solid, a volume in mL for a liquid.
struct MedProductDoseSection: View {
    @Binding var amount: Double?
    let unitWord: String
    let isLiquid: Bool

    var body: some View {
        Section {
            if isLiquid {
                HStack {
                    TextField("Volume", value: $amount, format: .number)
                        .accessibilityLabel(Text("Volume"))
                        .decimalKeyboard()
                    Text(verbatim: CombinationComponent.volumeUnitWord)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            } else {
                Stepper(value: units, in: 1 ... CombinationComponent.maximumUnits) {
                    Text(verbatim: CustomSubstanceEntry.quantityLabel(Double(units.wrappedValue), unitWord: unitWord, isLiquid: false))
                }
            }
        } header: {
            Text("Dose")
        } footer: {
            Text("Checked off by logging this product.")
        }
    }

    private var units: Binding<Int> {
        Binding(
            get: { CombinationComponent.units(for: amount) },
            set: { amount = Double($0) },
        )
    }
}

// MARK: - Component row

/// One compound of a product: its name, then the amount per unit with its
/// unit, then the route it is taken by.
private struct ProductComponentRow: View {
    @Binding var component: ProductComponentDraft
    let unitWord: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(component.displayName)
                .font(.body.weight(.medium))
            HStack {
                TextField("amount", value: $component.amount, format: .number)
                    .accessibilityLabel(ProductUnitWord.amountPerUnitLabel(unitWord))
                    .decimalKeyboard()
                Picker("Unit", selection: $component.unit) {
                    ForEach(component.availableUnits, id: \.self) { Text($0) }
                }
                .labelsHidden()
                Text(verbatim: ProductUnitWord.perUnitLabel(unitWord))
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
private struct ProductComponentPicker: View {
    let onPick: (ProductComponentDraft) -> Void

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

// MARK: - Edit sheet

/// Edit a saved product's name, unit word and components, from its med or
/// from Library ▸ Custom Substances. Solid or liquid is fixed once saved: a
/// count of pills and a volume in mL mean different things for doses
/// already logged. A rename carries the med (or meds) naming it along.
struct MedProductEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var draft: MedProductDraft
    @State private var showsNameTaken = false
    @State private var showsComponentPicker = false

    init(product: CustomSubstanceEntry) {
        _draft = State(initialValue: MedProductDraft(product: product))
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    MedProductNameSection(draft: draft)
                    MedProductUnitSection(draft: draft)
                    MedProductComponentsSection(draft: draft, allowsSeveral: true) {
                        showsComponentPicker = true
                    }
                }
                .listRowBackground(CardBackground())
            }
            .productComponentPicker(isPresented: $showsComponentPicker, draft: draft, allowsSeveral: true)
            .themedPage()
            .navigationTitle("Edit Product")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Image(systemName: "checkmark").fontWeight(.semibold) }
                        .disabled(!draft.canSave)
                        .accessibilityLabel("Save")
                }
            }
            .alert("Name Taken", isPresented: $showsNameTaken) {
                Button("OK") {}
            } message: {
                Text("\"\(draft.trimmedName)\" already names a substance. Choose another name for this product.")
            }
        }
    }

    private func save() {
        let store = CustomSubstanceStore.shared
        guard draft.canSave, let existing = draft.existing else { return }
        guard !draft.nameIsTaken(in: store) else {
            showsNameTaken = true
            return
        }
        let entry = draft.makeEntry()
        store.update(entry)
        if existing.name != entry.name {
            MedProductStore.rename(existing.name, to: entry.name, in: modelContext)
        }
        dismiss()
    }
}

// MARK: - Med detail

/// The dose of a med saved as a product, on its detail screen: how many units
/// (or mL) one dose is, what the product holds, and the way to edit it.
/// The screen's root presents the editor (`onEdit`), for the reason given on
/// `productComponentPicker`.
struct MedProductDetailSection: View {
    @Bindable var item: DailyDoseItem
    let product: CustomSubstanceEntry
    let onEdit: () -> Void

    var body: some View {
        Section {
            if product.isLiquidCombination {
                HStack {
                    TextField("Volume", value: $item.amount, format: .number)
                        .accessibilityLabel(Text("Volume"))
                        .decimalKeyboard()
                    Text(verbatim: CombinationComponent.volumeUnitWord)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            } else {
                Stepper(value: units, in: 1 ... CombinationComponent.maximumUnits) {
                    Text(verbatim: product.quantityLabel(item.amount))
                }
            }
            if let listing = product.componentsListing {
                Text(listing)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Button("Edit Product", action: onEdit)
        } header: {
            Text("Dose")
        } footer: {
            Text("Checked off by logging this product.")
        }
        .listRowBackground(CardBackground())
    }

    private var units: Binding<Int> {
        Binding(
            get: { CombinationComponent.units(for: item.amount) },
            set: { item.amount = Double($0) },
        )
    }
}

// MARK: - Persistence

/// The med-side writes a product edit needs.
enum MedProductStore {
    /// Point every med that names `oldName` at `newName`, so a renamed product
    /// keeps its meds.
    static func rename(_ oldName: String, to newName: String, in context: ModelContext) {
        let descriptor = FetchDescriptor<DailyDoseItem>(predicate: #Predicate { $0.substance == oldName })
        for item in (try? context.fetch(descriptor)) ?? [] {
            item.substance = newName
        }
        try? context.save()
    }
}
