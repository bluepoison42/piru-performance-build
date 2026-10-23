import Foundation
import GRDB
import Testing
@testable import PortableData

@Model
final class Label {
    #Unique<Label>([\.namespace, \.name])

    var namespace: String
    var name: String
    var note: String?

    init(namespace: String, name: String, note: String? = nil) {
        self.namespace = namespace
        self.name = name
        self.note = note
    }
}

/// A container on its own file, with every model these tests use.
private func container(_ url: URL) throws -> ModelContainer {
    try ModelContainer(for: Dose.self, Visit.self, Label.self, configurations: ModelConfiguration(url: url))
}

private let origin = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: - Counting

@Suite("Counting")
struct CountingTests {
    let url = FileManager.default.temporaryDirectory.appending(path: "portable-count-\(UUID().uuidString).sqlite")

    private func seed(_ count: Int) throws -> [PersistentIdentifier] {
        let context = try ModelContext(container(url))
        let doses = (0 ..< count).map { Dose(substance: "s\($0)", amount: Double($0), timestamp: origin.addingTimeInterval(Double($0))) }
        doses.forEach(context.insert)
        try context.save()
        return doses.map(\.persistentModelID)
    }

    @Test
    func `A count of an entity the context has not read reads no model and honors offset and limit`() throws {
        let ids = try seed(5)
        let context = try ModelContext(container(url))
        #expect(try context.fetchCount(FetchDescriptor<Dose>()) == 5)
        let held: Dose? = context.registeredModel(for: ids[0])
        #expect(held == nil)
        for (offset, limit, expected) in [(2, nil, 3), (nil, 2, 2), (4, 3, 1), (9, nil, 0), (0, 0, 0)] as [(Int?, Int?, Int)] {
            var descriptor = FetchDescriptor<Dose>()
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit
            #expect(try context.fetchCount(descriptor) == expected, "offset \(String(describing: offset)), limit \(String(describing: limit))")
            #expect(try ModelContext(container(url)).fetch(descriptor).count == expected)
        }
    }

    @Test
    func `A count includes unsaved inserts and leaves out unsaved deletions`() throws {
        _ = try seed(5)
        let context = try ModelContext(container(url))
        context.insert(Dose(substance: "new", amount: 1, timestamp: origin))
        #expect(try context.fetchCount(FetchDescriptor<Dose>()) == 6)
        let doses = try context.fetch(FetchDescriptor<Dose>())
        context.delete(doses[0])
        context.delete(doses[1])
        #expect(try context.fetchCount(FetchDescriptor<Dose>()) == 4)
    }

    @Test
    func `A count with a predicate counts the models it matches`() throws {
        _ = try seed(5)
        let context = try ModelContext(container(url))
        #expect(try context.fetchCount(FetchDescriptor<Dose>(predicate: #Predicate { $0.amount >= 3 })) == 2)
    }
}

// MARK: - Unique inserts

@Suite("Unique inserts")
struct UniqueInsertTests {
    let url = FileManager.default.temporaryDirectory.appending(path: "portable-unique-\(UUID().uuidString).sqlite")

    private func labels(_ context: ModelContext) throws -> [Label] {
        try context.fetch(FetchDescriptor<Label>(sortBy: [SortDescriptor(\.name)]))
    }

    @Test
    func `Finding the row an insert duplicates searches an index, for one key and for several`() throws {
        let store = try container(url).store
        for (entity, keys, arguments) in [("Visit", ["id"], ["Visit", "new", "\"x\""]), ("Label", ["namespace", "name"], ["Label", "new", "\"a\"", "\"b\""])] {
            let plan = try store.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + Store.uniqueMatchSQL(entity: entity, keys: keys), arguments: StatementArguments(arguments))
                    .map { $0["detail"] as String }
            }
            #expect(plan.contains { $0.contains("INDEX portable_unique_\(entity)") && $0.contains("<expr>=?") }, "\(keys): \(plan)")
        }
    }

    @Test
    func `A store holding a row that is not JSON still opens, indexes and saves`() throws {
        let plain = try ModelContainer(for: Dose.self, configurations: ModelConfiguration(url: url))
        try plain.store.queue.write { db in
            try db.execute(sql: "INSERT INTO portable_models (entity, pk, data) VALUES ('Label', 'garbage', CAST('{not json' AS BLOB))")
        }
        let context = try ModelContext(container(url))
        context.insert(Label(namespace: "a", name: "b"))
        try context.save()
        #expect(try labels(ModelContext(container(url))).map(\.name) == ["b"])
    }

    @Test
    func `Of two inserts with the same unique values in one save, the later one is kept`() throws {
        let context = try ModelContext(container(url))
        context.insert(Label(namespace: "a", name: "b", note: "first"))
        context.insert(Label(namespace: "a", name: "b", note: "second"))
        try context.save()
        let stored = try labels(ModelContext(container(url)))
        #expect(stored.map(\.note) == ["second"])
    }

    @Test
    func `An insert matching a stored row takes its identity and updates it`() throws {
        let first = try ModelContext(container(url))
        let original = Label(namespace: "a", name: "b", note: "first")
        first.insert(original)
        try first.save()

        let second = try ModelContext(container(url))
        let again = Label(namespace: "a", name: "b", note: "again")
        second.insert(again)
        try second.save()
        #expect(again.persistentModelID == original.persistentModelID)
        let stored = try labels(ModelContext(container(url)))
        #expect(stored.map(\.note) == ["again"])
    }

    @Test
    func `A composite constraint matches only when every key does`() throws {
        let context = try ModelContext(container(url))
        context.insert(Label(namespace: "a", name: "b"))
        context.insert(Label(namespace: "a", name: "c"))
        context.insert(Label(namespace: "z", name: "b"))
        try context.save()
        #expect(try labels(ModelContext(container(url))).count == 3)
    }

    @Test
    func `Two contexts saving the same unique values leave one row, the later save's`() throws {
        let one = try ModelContext(container(url))
        let other = try ModelContext(container(url))
        one.insert(Label(namespace: "a", name: "b", note: "one"))
        other.insert(Label(namespace: "a", name: "b", note: "other"))
        try one.save()
        try other.save()
        #expect(try labels(ModelContext(container(url))).map(\.note) == ["other"])
    }

    @Test
    func `A save that fails leaves the insert with its own identity, and a retry updates the stored row`() throws {
        let stored = Label(namespace: "a", name: "b", note: "stored")
        let seeding = try ModelContext(container(url))
        seeding.insert(stored)
        try seeding.save()

        let failing = try container(url)
        let context = ModelContext(failing)
        let label = Label(namespace: "a", name: "b", note: "retried")
        context.insert(label)
        let arrived = label.persistentModelID
        try failing.store.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse BEFORE INSERT ON portable_models BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        #expect(throws: (any Error).self) { try context.save() }
        #expect(label.persistentModelID == arrived)
        #expect(context.hasChanges)

        try failing.store.queue.write { db in try db.execute(sql: "DROP TRIGGER refuse") }
        try context.save()
        #expect(label.persistentModelID == stored.persistentModelID)
        #expect(try labels(ModelContext(container(url))).map(\.note) == ["retried"])
    }
}

@Suite("Unique insert scaling", .serialized)
struct UniqueInsertScalingTests {
    /// Saves `added` new labels into a store already holding `existing`, and times the save.
    private func timeSave(existing: Int, added: Int) throws -> Duration {
        let url = FileManager.default.temporaryDirectory.appending(path: "portable-scaling-\(UUID().uuidString).sqlite")
        let seeding = try ModelContext(container(url))
        for index in 0 ..< existing {
            seeding.insert(Label(namespace: "old", name: "\(index)"))
        }
        try seeding.save()
        let context = try ModelContext(container(url))
        for index in 0 ..< added {
            context.insert(Label(namespace: "new", name: "\(index)"))
        }
        return try ContinuousClock().measure { try context.save() }
    }

    /// Probe N3: each insert scanned every stored row of its entity, 16 s for 8k into 8k.
    /// Eight times the stored rows would cost eight times as long by scanning.
    @Test
    func `Saving new unique rows costs about the same however many are stored`() throws {
        let small = try timeSave(existing: 1000, added: 1000)
        let large = try timeSave(existing: 8000, added: 1000)
        #expect(large < small * 3, "\(small) → \(large)")
    }
}

// MARK: - Revision

@Suite("Revision")
struct RevisionTests {
    let url = FileManager.default.temporaryDirectory.appending(path: "portable-revision-\(UUID().uuidString).sqlite")

    @Test
    func `The revision holds across reads and moves on every change a fetch could see`() throws {
        let container = try container(url)
        let context = ModelContext(container)
        context.insert(Dose(substance: "a", amount: 1, timestamp: origin))
        try context.save()
        let dose = try #require(try context.fetch(FetchDescriptor<Dose>()).first)

        var last = try #require(context.currentRevision())
        func moved(_ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let now = context.currentRevision()
            #expect(now != nil && now != last, "\(step)", sourceLocation: sourceLocation)
            last = now ?? last
        }

        _ = try context.fetch(FetchDescriptor<Dose>())
        #expect(context.currentRevision() == last, "a plain fetch")

        dose.amount = 2
        moved("an edit before saving")
        try context.save()
        moved("a save")
        dose.amount = 3
        last = context.currentRevision() ?? last
        context.rollback()
        moved("a rollback")
        context.insert(Dose(substance: "b", amount: 1, timestamp: origin))
        moved("an insert")
        context.delete(dose)
        moved("a delete")
        try context.save()
        last = context.currentRevision() ?? last

        let other = ModelContext(container)
        other.insert(Dose(substance: "c", amount: 1, timestamp: origin))
        try other.save()
        moved("another context's save")
        #expect(try context.fetch(FetchDescriptor<Dose>()).map(\.substance).sorted() == ["b", "c"])
    }
}
