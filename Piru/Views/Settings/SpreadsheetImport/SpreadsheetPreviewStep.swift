import SwiftUI

/// What the import will do under the current mapping: how many doses it
/// adds, how many are already in the journal, what it noticed, which rows it
/// leaves out and why, and the first few doses as they will be logged.
struct SpreadsheetPreviewStep: View {
    let conversion: SpreadsheetConversion
    let duplicateCount: Int

    private static let sampleCount = 5
    private static let skippedShown = 20

    var body: some View {
        List {
            Section {
                SummaryRow(title: "Doses to import", value: max(0, conversion.drafts.count - duplicateCount))
                if duplicateCount > 0 {
                    SummaryRow(title: "Already in your journal", value: duplicateCount)
                }
                if !conversion.skipped.isEmpty {
                    SummaryRow(title: "Rows left out", value: conversion.skipped.count)
                }
                SummaryRow(title: "Rows read", value: conversion.rowCount)
            } footer: {
                Text("Nothing is saved until you tap Import.")
            }

            if !conversion.warnings.isEmpty {
                Section("Worth Checking") {
                    ForEach(Array(conversion.warnings.enumerated()), id: \.offset) { _, warning in
                        Label {
                            Text(SpreadsheetImportCopy.warning(warning))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(Theme.accent).accessibilityHidden(true)
                        }
                        .font(.footnote)
                        .listRowBackground(CardBackground())
                    }
                }
            }

            if !conversion.drafts.isEmpty {
                Section("First Doses") {
                    ForEach(conversion.drafts.prefix(Self.sampleCount), id: \.row) { draft in
                        DraftRow(draft: draft)
                    }
                }
            }

            if !conversion.skipped.isEmpty {
                Section {
                    ForEach(conversion.skipped.prefix(Self.skippedShown), id: \.row) { row in
                        Text(SpreadsheetImportCopy.skipped(row))
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryLabel)
                            .listRowBackground(CardBackground())
                    }
                } header: {
                    Text("Left Out")
                } footer: {
                    if conversion.skipped.count > Self.skippedShown {
                        Text("And \(conversion.skipped.count - Self.skippedShown) more.")
                    }
                }
            }
        }
    }
}

private struct SummaryRow: View {
    let title: LocalizedStringKey
    let value: Int

    var body: some View {
        LabeledContent(title) {
            Text("\(value)").foregroundStyle(Theme.secondaryLabel).monospacedDigit()
        }
        .listRowBackground(CardBackground())
    }
}

/// A dose as it will be logged: substance, amount, time, and where it was.
private struct DraftRow: View {
    let draft: SpreadsheetDoseDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.substance).font(.body.weight(.medium))
                Spacer(minLength: Spacing.md)
                Text(amountText).foregroundStyle(Theme.secondaryLabel).monospacedDigit()
            }
            Text(detailText)
                .captionSecondary()
                .lineLimit(2)
        }
        .listRowBackground(CardBackground())
        .accessibilityElement(children: .combine)
    }

    private var amountText: String {
        let amount = draft.isUnknownDose ? "?" : draft.amount.doseFormatted
        return "\(draft.isApproximate ? "~" : "")\(amount) \(draft.unit)"
    }

    private var detailText: String {
        var parts = [draft.timestamp.formatted(date: .abbreviated, time: .shortened), String(localized: draft.route.localizedName)]
        if let place = draft.locationName {
            parts.append(place)
        } else if draft.latitude != nil {
            parts.append(String(localized: "Map location"))
        }
        if let notes = draft.notes {
            parts.append(notes)
        }
        return parts.joined(separator: " · ")
    }
}
