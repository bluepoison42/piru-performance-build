import Foundation

extension ModelContainer {
    public func requireCompleteBackup() throws {
        let reader = ModelContext(self)
        guard try reader.readAllForBackup().isEmpty else {
            throw NSError(domain: "Piru.Backup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Backup aborted because stored records could not be decoded. The previous backup was kept."
            ])
        }
    }
}
