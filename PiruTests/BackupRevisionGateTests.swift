import Foundation
import SwiftData
import Testing
@testable import Piru

/// The automatic backup's change gate: a capture taken on a background context
/// carries the revision of every exported source, a run writes only when that
/// revision differs from the one last written, and the revision is recorded
/// only once the write has returned.
@Suite("Backup revision gate", .serialized)
@MainActor
struct BackupRevisionGateTests {
    /// One source a Piru-native export carries, changed on its own.
    enum Source: CaseIterable, CustomTestStringConvertible {
        case dose
        case profile
        case favorite
        case inventory
        case customSubstance
        case notificationPreferences
        case setting

        var testDescription: String {
            switch self {
            case .dose: "dose log"
            case .profile: "profile"
            case .favorite: "favorites"
            case .inventory: "inventory"
            case .customSubstance: "custom substances"
            case .notificationPreferences: "notification preferences"
            case .setting: "settings"
            }
        }
    }

    private struct WriteFailed: Error {}

    @MainActor
    private final class Fixture {
        let container: ModelContainer
        let context: ModelContext
        let customs: CustomSubstanceStore
        let settings: DataExportImport.SettingsScope
        let gate: BackupRevisionGate
        private let suites: [String]
        private(set) var written: [BackupSnapshot] = []

        init() throws {
            let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            container = try ModelContainer(for: Schema(PiruSchema.models), configurations: config)
            context = container.mainContext
            customs = CustomSubstanceStore.forTesting(context: context)
            let names = ["standard", "group", "gate"].map { "piru.tests.backup-revision.\($0).\(UUID().uuidString)" }
            suites = names
            settings = try .init(
                standard: #require(UserDefaults(suiteName: names[0])),
                appGroup: #require(UserDefaults(suiteName: names[1])),
                sources: nil,
            )
            gate = try BackupRevisionGate(defaults: #require(UserDefaults(suiteName: names[2])), key: "revision")

            context.insert(DoseEntry(
                substance: "Caffeine", amount: 100, unit: "mg", route: .oral,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            ))
            context.insert(UserProfileRecord(bodyWeightKg: 70))
            context.insert(NotificationPreferences())
            try context.save()
        }

        func tearDown() {
            for name in suites {
                UserDefaults().removePersistentDomain(forName: name)
            }
        }

        func capture() async throws -> BackupSnapshot {
            try await DataExportImport.captureBackup(container: container, customStore: customs, settings: settings)
        }

        /// One gated run whose write records the snapshot, after running
        /// `duringWrite` and failing when `failing`.
        func run(failing: Bool = false, duringWrite: () throws -> Void = {}) async throws -> BackupRevisionGate.Outcome {
            try await gate.run(capture: capture) { snapshot in
                try duringWrite()
                if failing { throw WriteFailed() }
                written.append(snapshot)
            }
        }

        func change(_ source: Source) throws {
            switch source {
            case .dose:
                context.insert(DoseEntry(
                    substance: "Caffeine", amount: 50, unit: "mg", route: .oral,
                    timestamp: Date(timeIntervalSince1970: 1_700_003_600),
                ))
            case .profile:
                try #require(context.fetch(FetchDescriptor<UserProfileRecord>()).first).bodyWeightKg = 81
            case .favorite:
                context.insert(FavoriteSubstance(substance: "Caffeine"))
            case .inventory:
                context.insert(InventoryItem(substance: "Caffeine", baselineQuantity: 20))
            case .customSubstance:
                customs.add(CustomSubstanceEntry(name: "Testamine"))
            case .notificationPreferences:
                try #require(context.fetch(FetchDescriptor<NotificationPreferences>()).first).hydrationEnabled.toggle()
            case .setting:
                let setting = try #require(ExportedSettings.all.first { $0.kind == .bool })
                settings.defaults(setting.domain).set(true, forKey: setting.key)
            }
            try context.save()
        }
    }

    @Test
    func `An unchanged journal skips the write`() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let first = try await fixture.run()
        let second = try await fixture.run()

        #expect(first != .unchanged)
        #expect(second == .unchanged)
        #expect(fixture.written.count == 1)
    }

    @Test(arguments: Source.allCases)
    func `A change to one exported source writes a backup`(source: Source) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try await fixture.run()
        let before = fixture.gate.writtenRevision

        try fixture.change(source)
        let outcome = try await fixture.run()

        #expect(outcome != .unchanged)
        #expect(fixture.gate.writtenRevision != before)
        #expect(fixture.written.count == 2)
    }

    @Test
    func `A change during the write leaves another backup pending`() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let first = try await fixture.run { try fixture.change(.profile) }
        let captured = try #require(fixture.written.first)
        #expect(first == .written(revision: captured.revision))
        #expect(captured.file.profile?.bodyWeightKg == 70)

        let second = try await fixture.run()
        #expect(second != .unchanged)
        #expect(fixture.written.last?.file.profile?.bodyWeightKg == 81)
    }

    @Test
    func `A failed write records nothing and the next run retries`() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        await #expect(throws: WriteFailed.self) { try await fixture.run(failing: true) }
        #expect(fixture.gate.writtenRevision == nil)

        let retry = try await fixture.run()
        #expect(retry != .unchanged)
        #expect(fixture.written.count == 1)
    }

    @Test
    func `The recorded revision describes the data written`() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.change(.favorite)
        try fixture.change(.setting)

        _ = try await fixture.run()
        let snapshot = try #require(fixture.written.first)
        let restored = try JSONDecoder().decode(PiruFile.self, from: snapshot.plaintext())

        #expect(try BackupSnapshot(file: restored).revision == fixture.gate.writtenRevision)
        #expect(restored.favorites.map(\.substance) == ["Caffeine"])
        #expect(restored.sessions.isEmpty && restored.orphanDoses.count == 1)
    }

    @Test
    func `The background capture matches the main-actor export`() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.change(.customSubstance)
        try fixture.change(.inventory)

        let background = try await fixture.capture()
        let main = try DataExportImport.makePiruFile(
            context: fixture.context, customStore: fixture.customs, settings: fixture.settings,
        )

        #expect(try BackupSnapshot(file: main).revision == background.revision)
    }

    @Test
    func `Reset makes the next run write`() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try await fixture.run()

        fixture.gate.reset()
        let outcome = try await fixture.run()

        #expect(outcome != .unchanged)
        #expect(fixture.written.count == 2)
    }
}
