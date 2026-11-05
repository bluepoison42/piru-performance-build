import Foundation

nonisolated enum FolderBackupPublication {
    nonisolated struct StageResult {
        let uri: String?
        let error: String?
    }

    static func write(
        name: String,
        stage: (String) throws -> StageResult,
        publish: (String) throws -> String?
    ) rethrows -> String? {
        // A previous attempt may have lost its final name but left a complete
        // partial. Never truncate or discard that recovery copy on a retry.
        let partial = name + "." + UUID().uuidString + ".partial"
        let result = try stage(partial)
        if let failure = result.error { return failure }
        guard let uri = result.uri else { return "The folder did not return a staged backup URI." }
        return try publish(uri)
    }
}
