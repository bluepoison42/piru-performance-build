import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Imports a CSV or TSV file exported from a spreadsheet: choose the file,
/// check what each column was taken to be, preview what will be imported,
/// then import. Each step is its own view fed only what it shows; the work
/// lives in ``SpreadsheetImportModel``.
struct SpreadsheetImportSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appNavigator) private var navigator
    @State private var model = SpreadsheetImportModel()
    @State private var picking = false

    var body: some View {
        NavigationStack {
            content
                .themedPage()
                .navigationTitle(title)
                .inlineNavigationTitle()
                .toolbar { toolbar }
        }
        .fileImporter(
            isPresented: $picking,
            allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .data],
        ) { result in
            Task { await model.load(result) }
        }
        .alert("Import Failed", isPresented: errorBinding, presenting: model.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        #if DEBUG
        .task { await model.loadDebugPreloadIfRequested() }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .pick:
            SpreadsheetPickStep(isWorking: model.isWorking) { picking = true }
        case .mapping:
            if let analysis = model.analysis {
                SpreadsheetMappingStep(
                    fileName: model.fileName,
                    columns: analysis.columns,
                    mapping: model.mapping,
                    showsDateOrder: model.showsDateOrder,
                    dateOrderIsAmbiguous: model.dateOrderIsAmbiguous,
                    showsCoordinateSwap: model.showsCoordinateSwap,
                    swapEvidence: model.swapEvidence,
                    ambiguousNumber: model.ambiguousNumberSample,
                    canContinue: model.canContinue,
                    onRole: { model.setRole($0, forColumn: $1) },
                    onDateOrder: { model.setDateOrder($0) },
                    onSwap: { model.setSwapCoordinates($0) },
                    onDecimalStyle: { model.setDecimalStyle($0) },
                )
            }
        case .preview:
            if let conversion = model.conversion {
                SpreadsheetPreviewStep(conversion: conversion, duplicateCount: model.duplicateCount)
            }
        case let .done(outcome):
            SpreadsheetDoneStep(outcome: outcome, onAnother: { model.reset() })
        }
    }

    private var title: LocalizedStringKey {
        switch model.step {
        case .pick: "Import a Spreadsheet"
        case .mapping: "Columns"
        case .preview: "Preview"
        case .done: "Imported"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            switch model.step {
            case .preview:
                Button("Back") { model.backToMapping() }
            case .done:
                EmptyView()
            default:
                Button {
                    navigator.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close")
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            switch model.step {
            case .pick:
                EmptyView()
            case .mapping:
                Button("Next") { model.showPreview(context: modelContext) }
                    .disabled(!model.canContinue)
            case .preview:
                Button("Import") { model.commit(context: modelContext) }
                    .disabled(model.isWorking || (model.conversion?.drafts.count ?? 0) <= model.duplicateCount)
            case .done:
                Button("Done") { navigator.dismiss() }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

// MARK: - Choose a file

private struct SpreadsheetPickStep: View {
    let isWorking: Bool
    let onPick: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Image(systemName: "tablecells")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Bring in a dose log you kept in Google Sheets, Excel or Numbers. Export it as CSV, then choose the file. Piru reads its columns and shows you what it found before anything is saved.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Spacing.sm)
                .listRowBackground(CardBackground())

                Button(action: onPick) {
                    HStack {
                        Label("Choose File…", systemImage: "doc.badge.plus")
                        Spacer(minLength: 0)
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(isWorking)
                .listRowBackground(CardBackground())
            } footer: {
                Text("A sheet with several tabs exports one file per tab. Import each one; doses already in your journal are skipped.")
            }
        }
    }
}

// MARK: - Done

private struct SpreadsheetDoneStep: View {
    let outcome: DataExportImport.SpreadsheetImportOutcome
    let onAnother: () -> Void

    var body: some View {
        List {
            Section {
                LabeledContent("Doses imported") {
                    Text("\(outcome.imported)").foregroundStyle(Theme.secondaryLabel)
                }
                .listRowBackground(CardBackground())
                if outcome.duplicates > 0 {
                    LabeledContent("Already in your journal") {
                        Text("\(outcome.duplicates)").foregroundStyle(Theme.secondaryLabel)
                    }
                    .listRowBackground(CardBackground())
                }
            } footer: {
                Text("Imported doses are grouped into sessions in your journal.")
            }
            Section {
                Button(action: onAnother) {
                    Label("Import Another File", systemImage: "doc.badge.plus")
                }
                .listRowBackground(CardBackground())
            }
        }
    }
}
