import CryptoKit
import Foundation
import SwiftData

/// The parts of a Piru-native export kept outside the model store: custom
/// substances and the exported settings. Read on the main actor, where their
/// stores live, and handed to a background gather as values.
nonisolated struct ExportStoresSnapshot: Sendable {
    var customSubstances: [PiruCustomSubstanceData]
    var settings: PiruSettingsData

    @MainActor
    init(customStore: CustomSubstanceStore, settings: DataExportImport.SettingsScope) {
        customSubstances = customStore.all.map(PiruCustomSubstanceData.init)
        self.settings = DataExportImport.exportSettings(from: settings)
    }
}

/// One automatic backup's captured data and the revision it represents.
nonisolated struct BackupSnapshot: Sendable {
    let file: PiruFile
    /// SHA-256 of the file's content with its write time and app version blanked:
    /// two captures of the same data share a revision, and a change to any
    /// exported source (the model store, custom substances, settings) moves it.
    let revision: String

    init(file: PiruFile) throws {
        self.file = file
        var content = file
        content.exportedAt = 0
        content.appVersion = ""
        revision = try SHA256.hash(data: DataExportImport.encodeJSON(content))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The file as written to the destination.
    func plaintext() throws -> Data {
        try DataExportImport.encodeJSON(file)
    }
}

extension DataExportImport {
    /// Captures a backup with the main actor doing only the small reads: custom
    /// substances and settings here, then the model graph on a fresh background
    /// context and the revision hash beside it. The background context reads
    /// committed data, so the caller saves pending edits first.
    @MainActor
    static func captureBackup(
        container: ModelContainer,
        customStore: CustomSubstanceStore = .shared,
        settings: SettingsScope = .live,
    ) async throws -> BackupSnapshot {
        let stores = ExportStoresSnapshot(customStore: customStore, settings: settings)
        return try await captureBackup(container: container, stores: stores)
    }

    @DatabaseActor
    private static func captureBackup(container: ModelContainer, stores: ExportStoresSnapshot) throws -> BackupSnapshot {
        try BackupSnapshot(file: makePiruFile(context: ModelContext(container), stores: stores))
    }
}

/// Decides whether an automatic backup writes, by comparing the revision of the
/// data it captured with the revision the destination last received.
@MainActor
final class BackupRevisionGate {
    enum Outcome: Equatable {
        case unchanged
        case written(revision: String)
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    /// The revision of the snapshot the destination holds, or `nil` before the
    /// first write.
    var writtenRevision: String? {
        defaults.string(forKey: key)
    }

    /// Forgets the written revision, so the next run writes whatever it captures.
    func reset() {
        defaults.removeObject(forKey: key)
    }

    /// Captures, writes when the capture's revision differs from
    /// ``writtenRevision``, and records the capture's revision once `write`
    /// returns. A failed write records nothing, so the next run writes again;
    /// data changed after the capture has another revision than the one
    /// recorded, so the next run writes that too.
    func run(
        capture: () async throws -> BackupSnapshot,
        write: (BackupSnapshot) async throws -> Void,
    ) async throws -> Outcome {
        let snapshot = try await capture()
        guard snapshot.revision != writtenRevision else { return .unchanged }
        try await write(snapshot)
        defaults.set(snapshot.revision, forKey: key)
        return .written(revision: snapshot.revision)
    }
}
