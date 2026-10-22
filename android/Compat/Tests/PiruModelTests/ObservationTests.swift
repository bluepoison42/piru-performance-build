import Foundation
import PortableData
import Synchronization
import Testing

/// `@Model` makes a class Observable, as SwiftData's does: a view holding a model re-renders
/// when a property it read changes, however the change is made.
@Suite("Observation", .serialized)
struct ObservationTests {
    /// Runs `read` under observation tracking and reports whether `change` then fired it.
    private func fires(_ read: () -> Void, when change: () -> Void) -> Bool {
        let fired = Recorder()
        withObservationTracking(read) {
            fired.record("fired", \DoseEntry.amount)
        }
        change()
        return !fired.entries.isEmpty
    }

    @Test
    func `Setting a stored property notifies an observer that read it`() {
        let dose = DoseEntry(substance: "caffeine", amount: 80, timestamp: origin)
        #expect(fires {
            _ = dose.amount
        } when: {
            dose.amount = 90
        })
        #expect(!fires {
            _ = dose.amount
        } when: {
            dose.notes = "unrelated"
        })
    }

    @Test
    func `Assigning an equal value does not notify`() {
        let dose = DoseEntry(substance: "caffeine", amount: 80, timestamp: origin)
        #expect(!fires {
            _ = dose.amount
        } when: {
            dose.amount = 80
        })
    }

    /// MedDetailView's "Add a Time": `reminderTimesMinutes` is computed over the stored
    /// `reminderTimesMinutesData`.
    @Test
    func `Changing a computed property over a stored one notifies an observer of it`() {
        let item = DailyDoseItem(substance: "methylphenidate", amount: 10)
        #expect(fires {
            _ = item.reminderTimesMinutes
        } when: {
            item.reminderTimesMinutes.append(480)
        })
        #expect(item.reminderTimesMinutes == [480])
    }

    @Test
    func `An in-place mutation notifies and is saved`() throws {
        let store = TestStore()
        let seeded = try seedJournal(store)
        let context = try ModelContext(store.container())
        let dose = try #require(try context.dose(seeded.doses[0]))
        #expect(fires {
            _ = dose.isApproximate
        } when: {
            dose.isApproximate.toggle()
        })
        #expect(context.hasChanges)
        try context.save()
        #expect(try ModelContext(store.container()).dose(seeded.doses[0])?.isApproximate == true)
    }

    @Test
    func `Assigning a relationship notifies observers of both sides`() throws {
        let store = TestStore()
        try seedJournal(store)
        let context = try ModelContext(store.container())
        let session = try #require(try context.sessions().first)
        let dose = DoseEntry(substance: "late", amount: 1, timestamp: origin)
        context.insert(dose)
        #expect(fires {
            _ = session.doses
        } when: {
            dose.session = session
        })
    }

    @Test
    func `Another context's save notifies observers of the models it changed`() throws {
        let store = TestStore()
        let seeded = try seedJournal(store)
        let container = try store.container()
        let viewing = ModelContext(container)
        let dose = try #require(try viewing.dose(seeded.doses[0]))
        let editing = ModelContext(container)
        try #require(try editing.dose(seeded.doses[0])).amount = 1
        try editing.save()
        #expect(fires {
            _ = dose.amount
        } when: {
            _ = try? viewing.doses()
        })
        #expect(dose.amount == 1)
    }

    /// The Android app installs Skip's registrar as the bridge; every read and write
    /// reaches it too.
    @Test
    func `An installed bridge sees each model's reads and writes`() {
        let log = Recorder()
        ModelObservation.makeBridge = { RecordingBridge(log: log) }
        defer { ModelObservation.makeBridge = nil }
        let dose = DoseEntry(substance: "caffeine", amount: 80, timestamp: origin)
        _ = dose.amount
        dose.amount = 90
        dose.isApproximate.toggle()
        #expect(log.contains("access", \DoseEntry.amount))
        #expect(log.contains("willSet", \DoseEntry.amount))
        #expect(log.contains("didSet", \DoseEntry.amount))
        #expect(log.contains("willSet", \DoseEntry.isApproximate))
        #expect(!log.contains("willSet", \DoseEntry.notes))
    }

    /// A context made for one background read lets go of the models it read once it is gone,
    /// and their bridges with them. On Android each bridge holds a JNI global reference, and
    /// ART aborts the process when 51,200 of them are live.
    @Test
    func `A dropped context releases the models it read and their bridges`() throws {
        let store = TestStore()
        try seedJournal(store)
        let container = try store.container()
        let live = LiveCount()
        ModelObservation.makeBridge = { CountingBridge(token: LiveToken(live)) }
        defer { ModelObservation.makeBridge = nil }
        weak var dose: DoseEntry?
        weak var session: Session?
        weak var note: SessionNote?
        do {
            let context = ModelContext(container)
            dose = try context.doses().first
            session = dose?.session
            note = session?.notes?.first
            #expect(session?.doses?.count == 3)
            #expect(live.value > 0)
        }
        #expect(dose == nil)
        #expect(session == nil)
        #expect(note == nil)
        #expect(live.value == 0)
    }

    /// What a held model points at stays reachable after its context is gone.
    @Test
    func `A dose held past its context still reaches its session`() throws {
        let store = TestStore()
        try seedJournal(store)
        let dose = try #require(try ModelContext(store.container()).doses().first)
        #expect(dose.session?.title == "Saturday")
    }

    /// Astra's `remoteDeleteRetention` probe: a context that read a session and its note
    /// lets go of both when another context deletes the session and the cascade takes the
    /// note, though the two still point at each other when the deletion arrives.
    @Test
    func `A graph another context deletes is released by a context that read it`() throws {
        let store = TestStore()
        let container = try store.container()
        do {
            let seeding = ModelContext(container)
            let session = Session(startDate: origin, title: "Saturday")
            seeding.insert(session)
            seeding.insert(SessionNote(text: "calm", session: session))
            try seeding.save()
        }
        let live = LiveCount()
        ModelObservation.makeBridge = { CountingBridge(token: LiveToken(live)) }
        defer { ModelObservation.makeBridge = nil }
        weak var session: Session?
        weak var note: SessionNote?
        let reader = ModelContext(container)
        do {
            let read = try #require(try reader.sessions().first)
            let readNote = try #require(read.notes?.first)
            #expect(readNote.session === read)
            session = read
            note = readNote
        }
        #expect(live.value > 0)

        let writer = ModelContext(container)
        try writer.delete(model: Session.self)
        try writer.save()
        #expect(try reader.sessions().isEmpty)

        #expect(session == nil)
        #expect(note == nil)
        #expect(live.value == 0)
    }

    /// A model a remote deletion let go of stays deleted and keeps its to-one relationships;
    /// its to-many sides are empty.
    @Test
    func `A model a remote deletion lets go of stays deleted and keeps its to-one`() throws {
        let store = TestStore()
        try seedJournal(store)
        let container = try store.container()
        let reader = ModelContext(container)
        let session = try #require(try reader.sessions().first)
        let note = try #require(session.notes?.first)

        let writer = ModelContext(container)
        try writer.delete(model: Session.self)
        try writer.save()
        _ = try reader.sessions()

        #expect(session.isDeleted)
        #expect(note.isDeleted)
        #expect(session.modelContext == nil)
        #expect(note.session === session)
        #expect(session.notes?.isEmpty ?? true)
        #expect(session.doses?.isEmpty ?? true)
        #expect(!reader.hasChanges)
    }

    /// Astra's `ordinaryContextCleanup` control: a context that inserted and saved a graph
    /// frees it when it ends.
    @Test
    func `A context that saved a graph frees it when it ends`() throws {
        let store = TestStore()
        let container = try store.container()
        weak var session: Session?
        weak var note: SessionNote?
        do {
            let context = ModelContext(container)
            let inserted = Session(startDate: origin, title: "Saturday")
            let insertedNote = SessionNote(text: "calm", session: inserted)
            context.insert(inserted)
            context.insert(insertedNote)
            try context.save()
            #expect(inserted.notes?.count == 1)
            session = inserted
            note = insertedNote
        }
        #expect(session == nil)
        #expect(note == nil)
    }

    /// Discarded models are let go of the same way: inserts a rollback forgets, and deletions
    /// a save commits.
    @Test
    func `A rollback and a save free the graphs they discard while the context lives`() throws {
        let store = TestStore()
        try seedJournal(store)
        let context = try ModelContext(store.container())
        weak var rolledBack: Session?
        weak var rolledBackNote: SessionNote?
        weak var rolledBackDose: DoseEntry?
        do {
            let held = try #require(try context.sessions().first)
            do {
                let session = Session(startDate: origin, title: "Sunday")
                let note = SessionNote(text: "tired", session: session)
                let dose = DoseEntry(substance: "late", amount: 1, timestamp: origin)
                dose.session = held
                context.insert(session)
                context.insert(note)
                context.insert(dose)
                #expect(held.doses?.count == 4)
                rolledBack = session
                rolledBackNote = note
                rolledBackDose = dose
            }
            context.rollback()
            #expect(rolledBack == nil)
            #expect(rolledBackNote == nil)
            #expect(rolledBackDose == nil)
            #expect(held.doses?.count == 3)
        }

        weak var deleted: Session?
        weak var deletedNote: SessionNote?
        do {
            let session = try #require(try context.sessions().first)
            deleted = session
            deletedNote = session.notes?.first
            context.delete(session)
        }
        try context.save()
        #expect(deleted == nil)
        #expect(deletedNote == nil)
        #expect(!context.hasChanges)
    }
}

private final nonisolated class LiveCount: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func add(_ delta: Int) {
        count.withLock { $0 += delta }
    }
}

/// Stands in for the JNI global reference a Skip bridge holds: counted while it lives.
private final nonisolated class LiveToken: Sendable {
    let live: LiveCount

    init(_ live: LiveCount) {
        self.live = live
        live.add(1)
    }

    deinit {
        live.add(-1)
    }
}

private nonisolated struct CountingBridge: ModelObservationBridge {
    let token: LiveToken

    func access<Subject: Observable>(_: Subject, keyPath _: KeyPath<Subject, some Any>) {}
    func willSet<Subject: Observable>(_: Subject, keyPath _: KeyPath<Subject, some Any>) {}
    func didSet<Subject: Observable>(_: Subject, keyPath _: KeyPath<Subject, some Any>) {}
}

private final nonisolated class Recorder: Sendable {
    private let log = Mutex<[String]>([])

    var entries: [String] {
        log.withLock { $0 }
    }

    func record(_ event: String, _ keyPath: AnyKeyPath) {
        let entry = "\(event) \(keyPath)"
        log.withLock { $0.append(entry) }
    }

    func contains(_ event: String, _ keyPath: AnyKeyPath) -> Bool {
        entries.contains("\(event) \(keyPath)")
    }
}

private nonisolated struct RecordingBridge: ModelObservationBridge {
    let log: Recorder

    func access<Subject: Observable>(_: Subject, keyPath: KeyPath<Subject, some Any>) {
        log.record("access", keyPath)
    }

    func willSet<Subject: Observable>(_: Subject, keyPath: KeyPath<Subject, some Any>) {
        log.record("willSet", keyPath)
    }

    func didSet<Subject: Observable>(_: Subject, keyPath: KeyPath<Subject, some Any>) {
        log.record("didSet", keyPath)
    }
}
