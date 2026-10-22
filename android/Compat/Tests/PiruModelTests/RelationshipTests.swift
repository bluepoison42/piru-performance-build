import Foundation
import PortableData
import Testing

/// Contract item 6: the inverse side follows an assignment at once, and delete rules run.
@Suite("Relationships")
struct RelationshipTests {
    let store = TestStore()

    /// Probe P08, SessionService.assignSession's shape: assign, then read the bounds.
    @Test
    func `Assigning a dose's session adds it to the session's doses at once`() throws {
        try seedJournal(store)
        let context = try ModelContext(store.container())
        let session = try #require(try context.sessions().first)
        let late = DoseEntry(substance: "extends session", amount: 1, timestamp: origin.addingTimeInterval(5 * 3600))
        context.insert(late)
        late.session = session
        session.refreshDoseBounds()

        #expect(session.doses?.count == 4)
        #expect(session.lastDoseDate == late.timestamp)
        try context.save()
        // A context lets go of its sessions' doses when it ends, so it is held for the reads.
        let rereading = try ModelContext(store.container())
        let reread = try #require(try rereading.sessions().first)
        withExtendedLifetime(rereading) {
            #expect(reread.doses?.count == 4)
            #expect(reread.lastDoseDate == late.timestamp)
        }
    }

    /// SessionService.move deletes the source once its doses are empty.
    @Test
    func `Moving a session's only dose empties the source session`() throws {
        try seedJournal(store)
        let context = try ModelContext(store.container())
        let target = try #require(try context.sessions().first)
        let source = Session(startDate: origin.addingTimeInterval(86400))
        context.insert(source)
        let only = DoseEntry(substance: "only dose", amount: 1, timestamp: origin.addingTimeInterval(86400))
        context.insert(only)
        only.session = source
        try context.save()
        #expect(source.doses?.count == 1)

        only.session = target
        #expect((source.doses ?? []).isEmpty)
        #expect(target.doses?.contains { $0 === only } == true)
    }

    @Test
    func `A note built with its session is in the session's notes once inserted`() throws {
        let context = try ModelContext(store.container())
        let session = Session(startDate: origin)
        context.insert(session)
        let note = SessionNote(text: "hello", session: session)
        context.insert(note)
        #expect(session.notes?.contains { $0 === note } == true)
    }

    /// Probe P08's last part: appending on the inverse side sets the dose's session.
    @Test
    func `Appending to a session's doses sets the dose's session when saved`() throws {
        try seedJournal(store)
        let context = try ModelContext(store.container())
        let session = try #require(try context.sessions().first)
        let orphan = DoseEntry(substance: "appended", amount: 1, timestamp: origin)
        context.insert(orphan)
        session.doses?.append(orphan)
        try context.save()

        #expect(orphan.session === session)
        let reread = try ModelContext(store.container())
        #expect(try reread.doses().first { $0.substance == "appended" }?.session != nil)
    }

    /// Probe P09: `Session.notes` is `.cascade`, `Session.doses` is `.nullify`.
    @Test
    func `Deleting a session deletes its notes and detaches its doses`() throws {
        try seedJournal(store)
        let context = try ModelContext(store.container())
        let session = try #require(try context.sessions().first)
        let doses = try context.doses()
        let note = try #require(session.notes?.first)
        context.delete(session)

        #expect(note.isDeleted)
        #expect(doses.allSatisfy { $0.session == nil && !$0.isDeleted })
        try context.save()

        let reread = try ModelContext(store.container())
        #expect(try reread.fetch(FetchDescriptor<SessionNote>()).isEmpty)
        #expect(try reread.sessions().isEmpty)
        let stored = try reread.doses()
        #expect(stored.count == 3)
        #expect(stored.allSatisfy { $0.session == nil })
    }

    @Test
    func `Deleting a dose removes it from its session's doses`() throws {
        try seedJournal(store)
        let context = try ModelContext(store.container())
        let session = try #require(try context.sessions().first)
        let dose = try context.doses()[1]
        context.delete(dose)
        #expect(session.doses?.count == 2)
        #expect(session.doses?.contains { $0 === dose } == false)
        try context.save()
        let rereading = try ModelContext(store.container())
        let rereadCount = try rereading.sessions().first?.doses?.count
        withExtendedLifetime(rereading) {}
        #expect(rereadCount == 2)
    }

    @Test
    func `A fresh context connects both sides of every relationship`() throws {
        try seedJournal(store)
        let context = try ModelContext(store.container())
        let doses = try context.doses()
        let session = try #require(doses.first?.session)
        #expect(doses.allSatisfy { $0.session === session })
        #expect(Set((session.doses ?? []).map(ObjectIdentifier.init)) == Set(doses.map(ObjectIdentifier.init)))
        #expect(session.notes?.first?.text == "calm")
        #expect(session.notes?.first?.session === session)
    }
}
