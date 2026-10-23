import Foundation
import SwiftData

/// Everything behind the spreadsheet import sheet: reading the picked file,
/// the column mapping the person adjusts, the conversion that mapping yields,
/// and committing it. The views only present.
@Observable
@MainActor
final class SpreadsheetImportModel {
    enum Step: Equatable {
        case pick
        case mapping
        case preview
        case done(DataExportImport.SpreadsheetImportOutcome)
    }

    private(set) var step = Step.pick
    private(set) var fileName: String?
    private(set) var analysis: SpreadsheetAnalysis?
    /// The mapping as adjusted; every change re-runs the conversion.
    private(set) var mapping = SpreadsheetMapping(roles: [], dateOrder: .dayMonthYear, swapCoordinates: false)
    private(set) var conversion: SpreadsheetConversion?
    private(set) var duplicateCount = 0
    private(set) var isWorking = false
    var errorMessage: String?

    /// Files past this size are refused rather than parsed on the main actor.
    private static let maxBytes = 20 * 1_024 * 1_024

    // MARK: - Reading the file

    func load(_ result: Result<URL, Error>) async {
        switch result {
        case let .success(url):
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = String(localized: "Couldn't access the selected file.")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let maxBytes = Self.maxBytes
            do {
                let data = try await Task.detached {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= maxBytes else { throw SpreadsheetFileError.tooLarge }
                    return try Data(contentsOf: url)
                }.value
                await load(data, name: url.lastPathComponent)
            } catch SpreadsheetFileError.tooLarge {
                errorMessage = String(localized: "This file is too large to import. Split it into smaller files and import each one.")
            } catch {
                errorMessage = error.localizedDescription
            }
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    func load(_ data: Data, name: String) async {
        isWorking = true
        defer { isWorking = false }
        await SubstanceStore.shared.ensureAllLoaded()
        let table = await Task.detached { DelimitedText.read(data) }.value
        guard let table else {
            errorMessage = String(localized: "This file isn't text Piru can read. Export the sheet as CSV and try again.")
            return
        }
        guard !table.records.isEmpty, table.columnCount >= 2 else {
            errorMessage = String(localized: "This file has no columns Piru can read. Export the sheet as CSV, with one dose per row.")
            return
        }
        let analysis = SpreadsheetInference.analyze(table, resolver: SpreadsheetSubstanceMatch.library)
        self.analysis = analysis
        fileName = name
        mapping = analysis.suggestedMapping
        errorMessage = nil
        step = .mapping
    }

    // MARK: - Mapping

    func setRole(_ role: SpreadsheetColumnRole, forColumn column: Int) {
        mapping.assign(role, to: column)
    }

    func setDateOrder(_ order: SpreadsheetDateOrder) {
        mapping.dateOrder = order
    }

    func setSwapCoordinates(_ swap: Bool) {
        mapping.swapCoordinates = swap
    }

    /// A row needs both to become a dose.
    var canContinue: Bool {
        mapping.column(for: .date) != nil && mapping.column(for: .substance) != nil
    }

    var showsDateOrder: Bool {
        guard let analysis else { return false }
        return analysis.dateOrderIsAmbiguous(mapping) || analysis.dateOrderConflict(mapping) != nil
    }

    var dateOrderIsAmbiguous: Bool {
        analysis?.dateOrderIsAmbiguous(mapping) ?? false
    }

    var showsCoordinateSwap: Bool {
        mapping.column(for: .latitude) != nil && mapping.column(for: .longitude) != nil
    }

    var swapEvidence: SpreadsheetSwapEvidence? {
        analysis?.swapEvidence(mapping)
    }

    // MARK: - Preview and commit

    func showPreview(context: ModelContext) {
        guard let analysis else { return }
        let conversion = SpreadsheetConverter.convert(analysis, mapping: mapping, resolver: SpreadsheetSubstanceMatch.library)
        self.conversion = conversion
        duplicateCount = DataExportImport.spreadsheetDuplicateCount(conversion.drafts, context: context)
        step = .preview
    }

    func backToMapping() {
        step = .mapping
    }

    func commit(context: ModelContext) {
        guard let conversion else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try DataExportImport.importSpreadsheet(conversion.drafts, context: context)
            step = .done(outcome)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Back to choosing a file, for the next tab of the same sheet.
    func reset() {
        step = .pick
        fileName = nil
        analysis = nil
        conversion = nil
        duplicateCount = 0
        errorMessage = nil
    }

    #if DEBUG
        /// `-piruSpreadsheetFile <absolute path>` opens the import sheet with
        /// that file already read, so the mapping screen can be captured without
        /// driving the system file picker (`AppLaunch.runDebugFixtures`).
        static var debugPreloadPath: String? {
            UserDefaults.standard.string(forKey: "piruSpreadsheetFile")
        }

        func loadDebugPreloadIfRequested() async {
            guard step == .pick, let path = Self.debugPreloadPath, let data = FileManager.default.contents(atPath: path) else { return }
            await load(data, name: URL(fileURLWithPath: path).lastPathComponent)
        }
    #endif
}

private nonisolated enum SpreadsheetFileError: Error {
    case tooLarge
}
