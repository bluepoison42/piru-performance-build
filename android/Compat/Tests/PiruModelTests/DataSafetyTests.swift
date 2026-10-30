import Foundation
import GRDB
import PortableData
import Testing

@MainActor
@Suite(.serialized)
struct DataSafetyTests {
    private func dose(_ id: UUID? = nil, amount: Double = 10, note: String = "note") -> [String: Any] {
        var row: [String: Any] = [
            "substance": "caffeine", "amount": amount, "unit": "mg", "route": RouteOfAdministration.oral.rawValue,
            "timestamp": Int64(1_790_000_000_000), "notes": note, "tags": ["kept"], "isBackgroundMed": false
        ]
        if let id { row["id"] = id.uuidString }
        return row
    }

    private func native(_ doses: [[String: Any]], sessions: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["orphanDoses": doses, "sessions": sessions])
    }

    @Test func nativeDistinctIDsKeepIdenticalDosesAndSeparateSessions() throws {
        let store = TestStore()
        let container = try store.container()
        let context = ModelContext(container)
        let first = UUID(), second = UUID(), sessionA = UUID(), sessionB = UUID()
        let file = try native([], sessions: [
            ["id": sessionA.uuidString, "startDate": Int64(1_790_000_000_000), "doses": [dose(first, note: "first")]],
            ["id": sessionB.uuidString, "startDate": Int64(1_790_000_000_000), "doses": [dose(second, note: "second")]]
        ])
        try DataExportImport.importNativeDoseFile(file, context: context)
        try context.save()
        let reopened = ModelContext(container)
        #expect(try reopened.doses().count == 2)
        #expect(try reopened.dose(first)?.notes == "first")
        #expect(try reopened.dose(second)?.notes == "second")
        #expect(try reopened.dose(first)?.session?.id == sessionA)
        #expect(try reopened.dose(second)?.session?.id == sessionB)
        try DataExportImport.importNativeDoseFile(file, context: reopened)
        try reopened.save()
        #expect(try ModelContext(container).doses().count == 2)
    }

    @Test func nativeMergeKeepsLocallyEditedUUIDAndDoesNotCopyOldDose() throws {
        let store = TestStore()
        let container = try store.container()
        let context = ModelContext(container)
        let id = UUID()
        try DataExportImport.importNativeDoseFile(native([dose(id)]), context: context)
        let local = try #require(try context.dose(id))
        local.amount = 20
        local.notes = "local edit"
        try context.save()
        try DataExportImport.importNativeDoseFile(native([dose(id), dose(id, amount: 30)]), context: context)
        try context.save()
        let rows = try ModelContext(container).doses()
        #expect(rows.count == 1)
        #expect(rows.first?.id == id && rows.first?.amount == 20 && rows.first?.notes == "local edit")
    }

    @Test func nativeMissingIDStillDeduplicatesButNewIDOverridesContentMatch() throws {
        let store = TestStore()
        let context = try ModelContext(store.container())
        let file = try native([dose(), dose(note: "duplicate legacy")])
        try DataExportImport.importNativeDoseFile(file, context: context)
        try DataExportImport.importNativeDoseFile(file, context: context)
        #expect(try context.doses().count == 1)
        let differentID = UUID()
        try DataExportImport.importNativeDoseFile(native([dose(differentID)]), context: context)
        try context.save()
        #expect(try context.doses().count == 2)
        #expect(try context.dose(differentID) != nil)
    }

    @Test func snapshotCopiesEveryExistingSiblingAndReportsCopyFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = StoreRecovery.testStoreURL
        defer { StoreRecovery.testStoreURL = previous }
        StoreRecovery.testStoreURL = directory.appending(path: "journal.store")
        for suffix in StoreRecovery.storeSuffixes {
            try Data(("complete" + suffix).utf8).write(to: directory.appending(path: "journal.store" + suffix))
        }
        #expect(StoreRecovery.snapshotStore(reason: "good"))
        #expect(StoreRecovery.snapshotStore(reason: "good"))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let snapshots = files.filter { $0.lastPathComponent.hasPrefix("journal.store.good-") }
        #expect(snapshots.count == 6)
        for file in snapshots {
            let suffix = file.lastPathComponent.hasSuffix("-wal") ? "-wal" : file.lastPathComponent.hasSuffix("-shm") ? "-shm" : ""
            #expect(try Data(contentsOf: file) == Data(("complete" + suffix).utf8))
        }
        #expect(!StoreRecovery.snapshotStore(reason: "missing/parent"))
        #expect(try Data(contentsOf: StoreRecovery.testStoreURL) == Data("complete".utf8))
    }

    @Test func recoveryEnumerationAndDatesAcceptLegacyAndUniqueSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = StoreRecovery.testStoreURL
        defer { StoreRecovery.testStoreURL = previous }
        StoreRecovery.testStoreURL = directory.appending(path: "journal.store")
        let names = ["journal.store.prerestore-1790000000", "journal.store.prerestore-1790000000123_a1b2c3d4"]
        for name in names {
            for suffix in StoreRecovery.storeSuffixes {
                try Data().write(to: directory.appending(path: name + suffix))
            }
            #expect(StoreRecovery.sidecarReason(name) == "prerestore")
        }
        let candidates = StoreRecovery.recoveryCandidates(excluding: StoreRecovery.testStoreURL, includeIntentional: true)
        #expect(Set(candidates.map(\.lastPathComponent)) == Set(names))
        #expect(StoreRecovery.recoveryCandidates(excluding: StoreRecovery.testStoreURL, includeIntentional: false).isEmpty)
        #expect(StoreRecovery.sidecarTimestamp(names[0]) == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(StoreRecovery.sidecarTimestamp(names[1] + "-wal") == Date(timeIntervalSince1970: 1_790_000_000.123))
    }

    @Test func replaceAbortsBeforeDeleteWhenProductionSnapshotCannotCopy() throws {
        let store = TestStore()
        let seeded = try seedJournal(store)
        let container = try store.container()
        let context = ModelContext(container)
        let previous = StoreRecovery.testStoreURL
        defer { StoreRecovery.testStoreURL = previous }
        // Force a missing source without touching the live database or depending on names.
        StoreRecovery.testStoreURL = store.url.appending(path: "missing-store")
        do {
            try BackupManager().apply(plaintext: native([dose(UUID())]), strategy: .replace, context: context)
            Issue.record("Replace proceeded after a failed snapshot")
        } catch BackupManager.ManagerError.snapshotFailed {
            // Expected: the production guard throws before deleteAll commits anything.
        }
        let reopened = ModelContext(container)
        #expect(Set(try reopened.doses().map(\.id)) == Set(seeded.doses))
        #expect(try reopened.sessions().first?.id == seeded.session)
    }

    @Test func loadFailuresDiscoveredDuringCaptureKeepThePreviousBackup() throws {
        let store = TestStore()
        try seedJournal(store)
        let container = try store.container()
        let cached = ModelContext(container)
        #expect(try cached.doses().count == 3)
        #expect(container.loadFailures.isEmpty)
        let backup = store.url.deletingLastPathComponent().appending(path: "existing-backup")
        let original = Data("complete previous backup".utf8)
        try original.write(to: backup)
        var rejected = false
        do {
            let data = try DataExportImport.checkedBackup(container: container) {
                try store.execute("INSERT INTO portable_models (entity, pk, data) VALUES ('DoseEntry', 'broken', CAST('{bad' AS BLOB))")
                _ = try cached.doses()
                return Data("incomplete export".utf8)
            }
            try data.write(to: backup)
        } catch { rejected = true }
        #expect(rejected && !container.loadFailures.isEmpty)
        #expect(try Data(contentsOf: backup) == original)
        var capturedAgain = false
        rejected = false
        do {
            _ = try DataExportImport.checkedBackup(container: container) {
                capturedAgain = true
                return Data()
            }
        } catch { rejected = true }
        #expect(rejected && !capturedAgain)
        #expect(try store.count("DoseEntry") == 4)
    }

    @Test func repairedRowsAllowBackupAgainOnTheSameContainer() throws {
        let store = TestStore()
        try seedJournal(store)
        let originalRows = try store.rows("DoseEntry")
        let original = try #require(originalRows.first)
        let goodData = try JSONSerialization.data(withJSONObject: original.value)
        let container = try store.container()
        try store.execute("UPDATE portable_models SET data = CAST('{bad' AS BLOB) WHERE entity = 'DoseEntry' AND pk = ?", [original.key])
        let cached = ModelContext(container)
        #expect(try cached.doses().count == 2)
        #expect(!container.loadFailures.isEmpty)
        for _ in 0 ..< 2 {
            var rejected = false
            do {
                _ = try DataExportImport.checkedBackup(container: container) { try cached.doses().count }
            } catch { rejected = true }
            #expect(rejected)
        }
        try store.execute("UPDATE portable_models SET data = ? WHERE entity = 'DoseEntry' AND pk = ?", [goodData, original.key])
        let count = try DataExportImport.checkedBackup(container: container) { try ModelContext(container).doses().count }
        #expect(count == 3)
        // Historical diagnostics remain available but do not poison the new complete read.
        #expect(!container.loadFailures.isEmpty)
        #expect(try DataExportImport.checkedBackup(container: container) { try ModelContext(container).doses().count } == 3)
    }

    @Test func readableBackupStillCapturesNormally() throws {
        let store = TestStore()
        try seedJournal(store)
        let container = try store.container()
        let count = try DataExportImport.checkedBackup(container: container) { try ModelContext(container).doses().count }
        #expect(count == 3 && container.loadFailures.isEmpty)
    }

    @Test func failedPartialWriteNeverPublishesOrTouchesTheOldBackup() throws {
        let old = Data("old complete".utf8)
        var files = ["backup": old]
        var published = false
        let error = FolderBackupPublication.write(name: "backup") { partial in
            #expect(files["backup"] == old)
            #expect(partial.hasSuffix(".partial"))
            files[partial] = Data("truncated".utf8)
            return FolderBackupPublication.StageResult(uri: nil, error: "write failed")
        } publish: { _ in
            published = true
            return nil
        }
        #expect(error == "write failed" && !published && files["backup"] == old)
    }

    @Test func retryPreservesTheOnlyCompletePartialAfterFailedPromotion() throws {
        var files = ["backup": Data("old complete".utf8)]
        let complete = Data("new complete".utf8)
        var recoveryName = ""
        let error = FolderBackupPublication.write(name: "backup") { partial in
            #expect(files["backup"] != nil)
            files[partial] = complete
            recoveryName = partial
            return FolderBackupPublication.StageResult(uri: partial, error: nil)
        } publish: { partial in
            #expect(files[partial] == complete)
            // Provider fault: old final deleted, rename failed, fallback copy cut short.
            files["backup"] = Data("truncated".utf8)
            return "publish failed"
        }
        #expect(error == "publish failed")
        var publishedAgain = false
        let retry = FolderBackupPublication.write(name: "backup") { partial in
            #expect(partial != recoveryName)
            files[partial] = Data()
            return FolderBackupPublication.StageResult(uri: nil, error: "new file failed")
        } publish: { _ in
            publishedAgain = true
            return nil
        }
        #expect(retry == "new file failed" && !publishedAgain)
        #expect(files[recoveryName] == complete)
    }

    @Test func completedPartialIsPublishedAfterStageSucceeds() throws {
        var order: [String] = []
        let providerURI = "content://provider/renamed-and-not-yet-listed"
        let error = FolderBackupPublication.write(name: "backup") { partial in
            #expect(partial != providerURI)
            order.append("stage closed")
            return FolderBackupPublication.StageResult(uri: providerURI, error: nil)
        } publish: { partial in
            #expect(partial == providerURI)
            order.append("publish")
            return nil
        }
        #expect(error == nil && order == ["stage closed", "publish"])
    }

    @Test func missingStageURINeverPublishes() {
        var published = false
        let error = FolderBackupPublication.write(name: "backup") { _ in
            FolderBackupPublication.StageResult(uri: nil, error: nil)
        } publish: { _ in
            published = true
            return nil
        }
        #expect(error != nil && !published)
    }

    @Test func psyLogPositiveUnknownJSONImportsOnlyOnceAndDoesNotMatchKnownZero() throws {
        let store = TestStore()
        let container = try store.container()
        let context = ModelContext(container)
        let known = DoseEntry(substance: "unknown-med", amount: 0, unit: "mg", route: .other,
            timestamp: Date(ms: 1_790_000_000_000))
        context.insert(known)
        try context.save()
        let data = Data(#"{"experiences":[{"ingestions":[{"substanceName":"unknown-med","dose":42,"isUnknownDose":true,"units":"mg","administrationRoute":"SMOKED","time":1790000000000}]}]}"#.utf8)
        try DataExportImport.importPsyLog(data: data, context: context, customStore: .shared)
        try context.save()
        let reopened = ModelContext(container)
        try DataExportImport.importPsyLog(data: data, context: reopened, customStore: .shared)
        try reopened.save()
        let doses = try ModelContext(container).doses()
        #expect(doses.count == 2)
        #expect(doses.filter(\.isUnknownDose).count == 1)
        #expect(doses.allSatisfy { $0.amount == 0 })
        #expect(doses.first { !$0.isUnknownDose }?.route == .other)
        #expect(try ModelContext(container).sessions().count == 1)
    }

    @Test func psyLogPositiveUnknownJSONRepeatedIntoEmptyStoreCreatesOneRecord() throws {
        let store = TestStore()
        let container = try store.container()
        let data = Data(#"{"experiences":[{"ingestions":[{"substanceName":"unknown-med","dose":42,"isUnknownDose":true,"units":"mg","time":1790000000000}]}]}"#.utf8)
        for _ in 0 ..< 2 {
            let context = ModelContext(container)
            try DataExportImport.importPsyLog(data: data, context: context, customStore: .shared)
            try context.save()
        }
        let reopened = ModelContext(container)
        let doses = try reopened.doses()
        #expect(doses.count == 1 && doses.first?.amount == 0 && doses.first?.isUnknownDose == true)
        #expect(try reopened.sessions().count == 1)
    }

    @Test func psyLogUnknownDoseSurvivesProductionExportEncodingAndImport() throws {
        let store = TestStore()
        let container = try store.container()
        let context = ModelContext(container)
        let original = DoseEntry(substance: "unknown-med", amount: 42, unit: "mg", route: .sublingual,
            timestamp: Date(ms: 1_790_000_000_000), notes: "unknown amount #kept", isUnknownDose: true)
        let ingestion = DataExportImport.exportPsyLogIngestion(original)
        #expect(ingestion.dose == 0 && ingestion.isUnknownDose)
        let encoded = try JSONEncoder().encode(ingestion)
        let row = try JSONSerialization.jsonObject(with: encoded)
        let data = try JSONSerialization.data(withJSONObject: [
            "experiences": [["title": "Unknown dose session", "ingestions": [row]]]
        ])
        try DataExportImport.importPsyLog(data: data, context: context, customStore: .shared)
        try context.save()
        let reopened = ModelContext(container)
        let rows = try reopened.doses()
        #expect(rows.count == 1)
        let restored = try #require(rows.first)
        #expect(restored.amount == 0 && restored.isUnknownDose)
        #expect(restored.route == .sublingual && restored.timestamp == original.timestamp)
        #expect(restored.notes == original.notes && restored.tags == ["kept"])
        #expect(restored.session?.title == "Unknown dose session")
        try DataExportImport.importPsyLog(data: data, context: reopened, customStore: .shared)
        #expect(try reopened.doses().count == 1)
    }

    @Test func psyLogUnmarkedZeroMissingAndNegativeDosesStillSkip() throws {
        let store = TestStore()
        let context = try ModelContext(store.container())
        let rows: [[String: Any]] = [
            ["substanceName": "zero", "dose": 0, "time": Int64(1_790_000_000_000)],
            ["substanceName": "missing", "isUnknownDose": true, "time": Int64(1_790_000_000_000)],
            ["substanceName": "negative", "dose": -1, "isUnknownDose": true, "time": Int64(1_790_000_000_000)],
            ["substanceName": "known", "dose": 5, "time": Int64(1_790_000_000_000)]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["experiences": [["ingestions": rows]]])
        try DataExportImport.importPsyLog(data: data, context: context, customStore: .shared)
        let doses = try context.doses()
        #expect(doses.count == 1 && doses.first?.substance == "known" && doses.first?.isUnknownDose == false)
    }
}
