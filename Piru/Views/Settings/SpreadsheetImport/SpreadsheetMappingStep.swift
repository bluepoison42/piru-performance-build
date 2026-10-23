import SwiftUI

/// Each column with the field Piru took it to be, a few of its values, and a
/// picker to correct it; then the two sheet-wide choices, date order and
/// coordinate swap, when they apply.
struct SpreadsheetMappingStep: View {
    let fileName: String?
    let columns: [SpreadsheetColumn]
    let mapping: SpreadsheetMapping
    let showsDateOrder: Bool
    let dateOrderIsAmbiguous: Bool
    let showsCoordinateSwap: Bool
    let swapEvidence: SpreadsheetSwapEvidence?
    let canContinue: Bool
    let onRole: (SpreadsheetColumnRole, Int) -> Void
    let onDateOrder: (SpreadsheetDateOrder) -> Void
    let onSwap: (Bool) -> Void

    var body: some View {
        List {
            Section {
                ForEach(columns) { column in
                    SpreadsheetColumnRow(
                        column: column,
                        role: mapping.roles.indices.contains(column.index) ? mapping.roles[column.index] : .ignore,
                        onRole: { onRole($0, column.index) },
                    )
                }
            } header: {
                if let fileName { Text(fileName) }
            } footer: {
                if canContinue {
                    Text("Piru guessed what each column holds. Change any that are wrong.")
                } else {
                    Text("Choose a Date column and a Substance column to continue.")
                        .foregroundStyle(.cautionText)
                }
            }

            if showsDateOrder {
                SpreadsheetDateOrderSection(order: mapping.dateOrder, isAmbiguous: dateOrderIsAmbiguous, onChange: onDateOrder)
            }
            if showsCoordinateSwap {
                SpreadsheetSwapSection(isOn: mapping.swapCoordinates, evidence: swapEvidence, onChange: onSwap)
            }
        }
    }
}

/// One column: its title, sample values, how sure the guess is, and the role picker.
private struct SpreadsheetColumnRow: View {
    let column: SpreadsheetColumn
    let role: SpreadsheetColumnRole
    let onRole: (SpreadsheetColumnRole) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(column.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: Spacing.md)
                Picker(selection: roleBinding) {
                    ForEach(SpreadsheetColumnRole.assignable) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    Text("Field")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if !column.samples.isEmpty {
                Text(column.samples.joined(separator: " · "))
                    .captionSecondary()
                    .lineLimit(2)
            }
            if role != .ignore, role == column.inferredRole {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: confidenceSymbol).accessibilityHidden(true)
                    Text(SpreadsheetImportCopy.confidence(column.confidence))
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .listRowBackground(CardBackground())
        .accessibilityElement(children: .combine)
    }

    private var roleBinding: Binding<SpreadsheetColumnRole> {
        Binding(get: { role }, set: { onRole($0) })
    }

    private var confidenceSymbol: String {
        column.confidence >= 0.9 ? "checkmark.circle" : column.confidence >= 0.6 ? "circle.dashed" : "questionmark.circle"
    }
}

private struct SpreadsheetDateOrderSection: View {
    let order: SpreadsheetDateOrder
    let isAmbiguous: Bool
    let onChange: (SpreadsheetDateOrder) -> Void

    var body: some View {
        Section {
            Picker(selection: Binding(get: { order }, set: onChange)) {
                ForEach(SpreadsheetDateOrder.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Text("Date Order")
            }
            .listRowBackground(CardBackground())
        } footer: {
            if isAmbiguous {
                Text("No date in this file settles which number is the day. Check a date you know.")
            } else {
                Text("Dates in this file disagree on their order. The more common one is chosen.")
            }
        }
    }
}

private struct SpreadsheetSwapSection: View {
    let isOn: Bool
    let evidence: SpreadsheetSwapEvidence?
    let onChange: (Bool) -> Void

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { isOn }, set: onChange)) {
                Text("Swap Latitude and Longitude")
            }
            .tint(Theme.accent)
            .listRowBackground(CardBackground())
        } footer: {
            Text(SpreadsheetImportCopy.swapFooter(evidence))
        }
    }
}
