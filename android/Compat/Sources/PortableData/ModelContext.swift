import Foundation
import GRDB
import Synchronization

/// A container: one SQLite file (or an in-memory database) holding every model as a row.
public final class ModelContainer: @unchecked Sendable {
    public let schema: Schema
    public let configurations: [ModelConfiguration]
    let store: Store
    private nonisolated(unsafe) var main: ModelContext?
    private let failures = Mutex<[LoadFailure]>([])

    public init(for schema: Schema, configurations: [ModelConfiguration]) throws {
        self.schema = schema
        self.configurations = configurations
        let configuration = configurations.first
        store = try Store(url: configuration?.url, readOnly: configuration.map { !$0.allowsSave } ?? false)
        if !store.readOnly {
            for type in schema.types {
                for keys in EntityDescription.of(type).uniqueKeys {
                    try store.uniqueIndex(entity: type._$entityName, keys: keys)
                }
            }
        }
    }

    public convenience init(for schema: Schema, configurations: ModelConfiguration...) throws {
        try self.init(for: schema, configurations: configurations)
    }

    public convenience init(for types: any PersistentModel.Type..., configurations: ModelConfiguration...) throws {
        try self.init(for: Schema(types), configurations: configurations)
    }

    /// The container the app's views read, set by `.modelContainer(_:)`; `@Query` and the
    /// `modelContext` environment default to its main context.
    public nonisolated(unsafe) static var application: ModelContainer?

    /// The context views use. It autosaves, as SwiftData's main context does.
    @MainActor
    public var mainContext: ModelContext {
        if let main { return main }
        let context = ModelContext(self)
        context.autosaveEnabled = true
        main = context
        return context
    }

    /// Saves the main context's pending changes now, rather than on the next main-actor turn.
    /// The Android host calls it when the activity pauses, since the process may be killed
    /// before another turn.
    @MainActor
    public func flush() throws {
        try main?.save()
    }

    /// Rows that could not be read into their model. Each is skipped, logged, and left on
    /// disk untouched; a context that loads the entity again reports it again.
    public var loadFailures: [LoadFailure] {
        failures.withLock { $0 }
    }

    func report(_ failure: LoadFailure) {
        failures.withLock { $0.append(failure) }
        PortableDataLog.error("load", "Skipped \(failure.description)")
    }

    func type(named name: String) -> (any PersistentModel.Type)? {
        schema.types.first { $0._$entityName == name }
    }

    /// After another context's save, the main context catches up on the next main-queue turn,
    /// so views showing it see what a background context wrote.
    func contextSaved(_ context: ModelContext) {
        guard let main, main !== context else { return }
        DispatchQueue.main.async {
            main.storeChanged()
        }
    }
}

/// A stored row that could not become a model.
public struct LoadFailure: Sendable, CustomStringConvertible {
    public let entity: String
    public let primaryKey: String
    public let reason: String

    public var description: String {
        "\(entity)/\(primaryKey): \(reason)"
    }
}

public struct FetchDescriptor<T: PersistentModel> {
    public var predicate: Predicate<T>?
    public var sortBy: [SortDescriptor<T>]
    public var fetchLimit: Int?
    public var fetchOffset: Int?
    public var includePendingChanges = true
    public var propertiesToFetch: [PartialKeyPath<T>] = []
    public var relationshipKeyPathsForPrefetching: [PartialKeyPath<T>] = []

    public init(predicate: Predicate<T>? = nil, sortBy: [SortDescriptor<T>] = []) {
        self.predicate = predicate
        self.sortBy = sortBy
    }
}

public enum PortableDataError: Error, CustomStringConvertible {
    case notInContainer(String)
    case readOnly
    case malformedRow
    case missingValue(entity: String, key: String)
    case undecodable(entity: String, key: String, underlying: String)
    case unencodable(entity: String, key: String, underlying: String)

    public var description: String {
        switch self {
        case let .notInContainer(name): "\(name) is not in the container's schema"
        case .readOnly: "the store was opened read-only"
        case .malformedRow: "the row is not a JSON object"
        case let .missingValue(entity, key): "\(entity).\(key) has no stored value and no default"
        case let .undecodable(entity, key, underlying): "\(entity).\(key) cannot be read: \(underlying)"
        case let .unencodable(entity, key, underlying): "\(entity).\(key) cannot be stored: \(underlying)"
        }
    }
}

/// A working set of models over a container, the shape of a personal journal: an entity is
/// read whole on first use, together with every entity its relationships reach, and held in
/// an identity map, so a fetch after that is a filter over objects already in memory.
///
/// Each held model keeps the row it was read from. A model's accessors report every write
/// to it, and the first one records the model's encoding as it was; a save encodes only the
/// models written since and writes only the keys that differ, over the row as it is on disk
/// then, so values this context did not change are never written back. Before a fetch, and
/// after a save, the context reads what other contexts saved since it last looked and applies
/// it to the models it holds, except where it has changes of its own.
///
/// `@unchecked Sendable` as SwiftData's is used: one context lives on one actor, and the
/// environment value that carries the main context needs a Sendable default.
public final class ModelContext: @unchecked Sendable {
    public let container: ModelContainer

    /// Saves pending changes on the next main-queue turn after an insert, a delete or a write
    /// to a held model's stored property. On by default for the main context only, as in
    /// SwiftData; the save runs on the main queue.
    public var autosaveEnabled = false {
        didSet {
            if autosaveEnabled, !inserted.isEmpty || !deleted.isEmpty || !touched.isEmpty {
                scheduleAutosave()
            }
        }
    }

    /// Called after every insert, delete, save and rollback, and after this context applies
    /// another context's save outside a fetch. A UI layer hangs its invalidation here, in
    /// whichever Observation its views track (Skip's, on Android).
    public var changeHandler: (() -> Void)?

    final class Entry {
        let model: any PersistentModel
        /// The row as last read or written; `nil` until an inserted model is first saved.
        var committed: [String: Data]?
        /// The model's own encoding of `committed`, taken when an accessor first reports a write
        /// (at once, for an entity with an untracked property). A key whose encoding differs
        /// from this is a change the context has not saved; `nil` means the model still holds
        /// `committed`.
        var baseline: [String: Data]?

        init(_ model: any PersistentModel, committed: [String: Data]?) {
            self.model = model
            self.committed = committed
        }
    }

    private var registry: [PersistentIdentifier: Entry] = [:]
    /// Each entity's identifiers in the order they arrived; one whose model has left the
    /// registry is dropped when the entity is next read.
    private var members: [String: [PersistentIdentifier]] = [:]
    private var loaded: Set<String> = []
    private var backupReadFailures: [LoadFailure] = []
    private var inserted: Set<PersistentIdentifier> = []
    private var deleted: [PersistentIdentifier: Entry] = [:]
    /// Models whose accessors reported a write since the last save.
    private var touched: Set<PersistentIdentifier> = []
    /// The store generation this context has read up to.
    private var generation = 0
    /// Advances whenever what a fetch could return may have changed; see ``currentRevision()``.
    private var revision = 0 {
        didSet { sortedReads.removeAll(keepingCapacity: true) }
    }
    // Keep ascending, descending and unsorted reads from evicting each other
    // between tabs. Only stored attributes qualify; computed keys may change.
    private var sortedReads: [String: [(revision: Int, order: Any, result: Any)]] = [:]
    private var autosaveScheduled = false
    /// Set while the context itself writes into models (loading, applying another context's
    /// changes, rolling back), so the accessors' reports stand aside.
    private(set) var isApplying = false

    public init(_ container: ModelContainer) {
        self.container = container
    }

    /// Lets go of the models this context read, through ``detach(_:)``. A session held past
    /// its context reads no doses, where SwiftData's model would keep its context alive:
    /// read a to-many side while its context is held.
    deinit {
        detach((Array(registry.values) + Array(deleted.values)).map(\.model))
    }

    public var hasChanges: Bool {
        if !inserted.isEmpty || !deleted.isEmpty { return true }
        return ModelObservation.traversing {
            candidates.contains { registry[$0].map(isDirty) ?? false }
        }
    }

    /// The held models that may differ from what they last saved: inserted ones, those whose
    /// accessors reported a write, and every model of an entity with an untracked property.
    private var candidates: [PersistentIdentifier] {
        var ids = touched.union(inserted)
        for (name, members) in members {
            guard let type = container.type(named: name), !EntityDescription.of(type).tracksMutations else { continue }
            ids.formUnion(members.filter { registry[$0] != nil })
        }
        return Array(ids)
    }

    // MARK: Changes

    public func insert(_ model: some PersistentModel) {
        ModelObservation.traversing {
            insertModel(model)
        }
    }

    private func insertModel<T: PersistentModel>(_ model: T) {
        if let id = model._$backing.identifier {
            if let entry = deleted[id], entry.model === model {
                deleted[id] = nil
                model._$backing.isDeleted = false
                register(entry, id)
                changed()
                return
            }
            if registry[id]?.model === model { return }
        }
        let id = model._$backing.identifier
            ?? PersistentIdentifier(entityName: T._$entityName, primaryKey: UUID().uuidString)
        model._$backing.identifier = id
        model._$backing.context = self
        model._$backing.isDeleted = false
        register(Entry(model, committed: nil), id)
        inserted.insert(id)
        // A to-one set in the model's initializer went through its init accessor, which reports nothing.
        for relationship in EntityDescription.of(T.self).toOne {
            guard let target = relationship.get(model) else { continue }
            for inverse in EntityDescription.of(relationship.target).inverses where inverse.childPath == relationship.path {
                inverse.add(model, to: target)
            }
        }
        changed()
    }

    public func delete(_ model: some PersistentModel) {
        ModelObservation.traversing {
            remove(model)
        }
        changed()
    }

    public func delete<T: PersistentModel>(model _: T.Type, where predicate: Predicate<T>? = nil) throws {
        try ModelObservation.traversing {
            for model in try fetch(FetchDescriptor(predicate: predicate)) {
                remove(model)
            }
        }
        changed()
    }

    /// Deletes `model` and applies its relationships' delete rules: `.cascade` deletes what
    /// it holds, `.nullify` clears the children's pointer to it, and it leaves the inverse
    /// arrays it was in.
    private func remove(_ model: any PersistentModel) {
        guard !model.isDeleted else { return }
        model._$backing.isDeleted = true
        guard let id = model._$backing.identifier, let entry = registry[id], entry.model === model else { return }
        unregister(id)
        touched.remove(id)
        if inserted.remove(id) == nil {
            deleted[id] = entry
        }
        let description = EntityDescription.of(type(of: model))
        for inverse in description.inverses {
            for child in children(of: model, through: inverse) {
                switch inverse.deleteRule {
                case .cascade: remove(child)
                case .nullify: inverse.setOwner(child, nil)
                case .deny, .noAction: break
                }
            }
        }
        for relationship in description.toOne {
            guard let target = relationship.get(model) else { continue }
            for inverse in EntityDescription.of(relationship.target).inverses where inverse.childPath == relationship.path {
                inverse.remove(model, from: target)
            }
            if relationship.deleteRule == .cascade {
                remove(target)
            }
        }
        for relationship in description.toMany where relationship.deleteRule == .cascade {
            for target in relationship.get(model) {
                remove(target)
            }
        }
    }

    /// An owner's children: its inverse array, which the accessors keep current, and, for a
    /// child entity with an untracked property, every held child that points at it.
    private func children(of owner: any PersistentModel, through inverse: EntityDescription.Inverse) -> [any PersistentModel] {
        var children = inverse.children(owner).filter { inverse.owner(of: $0) === owner }
        guard !EntityDescription.of(inverse.child).tracksMutations else { return children }
        for child in models(inverse.child._$entityName) where inverse.owner(of: child) === owner {
            if !children.contains(where: { $0 === child }) {
                children.append(child)
            }
        }
        return children
    }

    /// Puts every held model back to its last saved values, forgets inserted models and
    /// restores deleted ones, as SwiftData's rollback does. Held references stay valid.
    public func rollback() {
        ModelObservation.traversing {
            rollbackModels()
        }
        revision += 1
        changeHandler?()
    }

    private func rollbackModels() {
        isApplying = true
        defer { isApplying = false }
        var discarded: [any PersistentModel] = []
        for id in inserted {
            guard let entry = registry[id] else { continue }
            unregister(id)
            entry.model._$backing.context = nil
            entry.model._$backing.identifier = nil
            discarded.append(entry.model)
        }
        inserted.removeAll()
        detach(discarded)
        for (id, entry) in deleted {
            entry.model._$backing.isDeleted = false
            register(entry, id)
            touched.insert(id)
        }
        deleted.removeAll()
        for id in candidates {
            guard let entry = registry[id], let baseline = entry.baseline else { continue }
            let changes = changedKeys(entry)
            if !changes.isEmpty {
                restore(entry, from: baseline, keys: changes)
            }
        }
        touched.removeAll()
        rebuildInverses()
    }

    // MARK: Saving

    /// Writes this context's inserts, deletes and changed keys in one transaction. A value
    /// that cannot be encoded fails the save before anything is written. A row another
    /// context deleted stays deleted; this context's changes to it are dropped.
    public func save() throws {
        try ModelObservation.traversing {
            try saveChanges()
        }
    }

    private func saveChanges() throws {
        guard !container.store.readOnly else {
            if hasChanges { throw PortableDataError.readOnly }
            return
        }
        adoptReferencedModels()
        applyInverseAppends()

        var inserts: [PersistentIdentifier: [String: Data]] = [:]
        var updates: [PersistentIdentifier: Update] = [:]
        for id in candidates {
            guard let entry = registry[id] else { continue }
            let encoded = try encode(entry.model, id)
            if entry.committed == nil {
                inserts[id] = encoded
            } else if let baseline = entry.baseline {
                let changes = encoded.keys.filter { encoded[$0] != baseline[$0] }
                if !changes.isEmpty {
                    updates[id] = (encoded, changes)
                }
            }
        }
        let removals = Array(deleted.keys)
        guard !inserts.isEmpty || !updates.isEmpty || !removals.isEmpty else {
            touched.removeAll()
            return
        }

        let known = generation
        let entities = loaded
        let renames = Dictionary(uniqueKeysWithValues: Set(inserts.keys.map(\.entityName)).union(updates.keys.map(\.entityName)).map {
            ($0, container.type(named: $0).map { EntityDescription.of($0).renames } ?? [:])
        })
        let arrivals = members.values.joined().filter { inserts[$0] != nil }
        let outcome = try container.store.write { db, generation in
            var written: [PersistentIdentifier: [String: Data]] = [:]
            var found: [PersistentIdentifier: [String: Data]] = [:]
            var vanished: [PersistentIdentifier] = []
            for id in removals {
                try Store.remove(db, id, generation: generation)
            }
            var plan = WritePlan(inserts: inserts, updates: updates)
            try resolveUniqueInserts(db, &plan, arrivals: arrivals)
            for (id, update) in plan.updates {
                guard let current = try Store.row(db, id) else {
                    vanished.append(id)
                    continue
                }
                var fields = try RowCodec.fields(from: current)
                found[id] = fields
                for key in update.changes {
                    fields[key] = update.encoded[key]
                    if let original = renames[id.entityName]?[key] { fields[original] = nil }
                }
                try Store.put(db, id, RowCodec.data(from: fields), generation: generation)
                written[id] = fields
            }
            for (id, encoded) in plan.inserts {
                var fields = try Store.row(db, id).map(RowCodec.fields) ?? [:]
                fields.merge(encoded) { $1 }
                for original in (renames[id.entityName] ?? [:]).values {
                    fields[original] = nil
                }
                try Store.put(db, id, RowCodec.data(from: fields), generation: generation)
                written[id] = fields
            }
            // Read after this save's writes, so a row it rewrote carries this generation and
            // only other contexts' writes come back.
            let others = try Store.changes(db, after: known, entities: entities)
            return (generation: generation, written: written, found: found, vanished: vanished, others: others, plan: plan)
        }

        rehome(outcome.plan.moves, found: outcome.found)
        isApplying = true
        var absorbed: [(Entry, [String: Data], Set<String>?)] = []
        for (id, update) in outcome.plan.updates {
            guard let entry = registry[id], let fields = outcome.written[id], let found = outcome.found[id] else { continue }
            // Keys another context saved to this row since this context last read it.
            let committed = entry.committed ?? [:]
            let remote = Set(found.keys).union(committed.keys)
                .filter { found[$0] != committed[$0] }
                .subtracting(update.changes)
            entry.committed = fields
            settle(entry, update.encoded)
            if !remote.isEmpty {
                restoreAttributes(entry, from: fields, keys: remote)
                absorbed.append((entry, fields, remote))
            }
        }
        for (id, encoded) in outcome.plan.inserts {
            guard let entry = registry[id] else { continue }
            entry.committed = outcome.written[id]
            settle(entry, encoded)
        }
        connect(absorbed)
        inserted.removeAll()
        forget(outcome.vanished)
        let discarded = deleted.values.map(\.model)
        for model in discarded {
            model._$backing.context = nil
        }
        deleted.removeAll()
        detach(discarded)
        touched.removeAll()
        isApplying = false
        var others = outcome.others
        others.rows.removeAll { outcome.written[PersistentIdentifier(entityName: $0.entity, primaryKey: $0.primaryKey)] != nil }
        // The accessors kept this context's inverse arrays current; others' rows may move models.
        if apply(others) || !outcome.vanished.isEmpty {
            rebuildInverses()
        }
        generation = outcome.generation
        revision += 1
        changeHandler?()
        container.contextSaved(self)
    }

    /// A model's encoding. An accessor's first write report asks for it too, outside any
    /// other pass, so it holds off bridges itself.
    private func encode(_ model: any PersistentModel, _ id: PersistentIdentifier) throws -> [String: Data] {
        var snapshot = Snapshot(identifier: id)
        try ModelObservation.traversing {
            try model._$encode(into: &snapshot)
        }
        return snapshot.written
    }

    private func isDirty(_ entry: Entry) -> Bool {
        entry.committed == nil || !changedKeys(entry).isEmpty
    }

    private func changedKeys(_ entry: Entry) -> Set<String> {
        guard let baseline = entry.baseline else { return [] }
        guard let id = entry.model._$backing.identifier, let encoded = try? encode(entry.model, id) else {
            return Set(baseline.keys)
        }
        return Set(encoded.keys.filter { encoded[$0] != baseline[$0] })
    }

    /// Records that a held model now matches its row, `encoded` being its encoding.
    private func settle(_ entry: Entry, _ encoded: [String: Data]) {
        entry.baseline = EntityDescription.of(type(of: entry.model)).tracksMutations ? nil : encoded
    }

    /// Inserts every model a held model points at that no context holds, as SwiftData does,
    /// so no saved row names a model that has no row.
    private func adoptReferencedModels() {
        var pending = candidates.compactMap { registry[$0]?.model }
        while let model = pending.popLast() {
            let description = EntityDescription.of(type(of: model))
            let targets = description.toOne.compactMap { $0.get(model) } + description.toMany.flatMap { $0.get(model) }
            for target in targets where !target.isDeleted && target._$backing.context == nil {
                adopt(target)
                pending.append(target)
            }
        }
    }

    private func adopt(_ model: any PersistentModel) {
        func open(_ model: some PersistentModel) {
            insert(model)
        }
        open(model)
    }

    /// A model appended to an inverse array, rather than assigned its to-one, gets that to-one
    /// here, as SwiftData sets it on append. Only where both sides are tracked: otherwise an
    /// inverse array can be stale, so the to-one is what counts.
    private func applyInverseAppends() {
        for id in touched {
            guard let owner = registry[id]?.model else { continue }
            let description = EntityDescription.of(type(of: owner))
            guard description.tracksMutations else { continue }
            for inverse in description.inverses where EntityDescription.of(inverse.child).tracksMutations {
                for child in inverse.children(owner) where !child.isDeleted && inverse.owner(of: child) !== owner {
                    inverse.setOwner(child, owner)
                }
            }
        }
    }

    private typealias Update = (encoded: [String: Data], changes: [String])

    /// The rows a save writes, keyed by the identity each is written under.
    private struct WritePlan {
        var inserts: [PersistentIdentifier: [String: Data]]
        var updates: [PersistentIdentifier: Update]
        /// Each inserted model that takes another model's identity, in the order it does so:
        /// the identity it arrived with, then the one it takes.
        var moves: [(from: PersistentIdentifier, to: PersistentIdentifier)] = []
    }

    /// An inserted model whose unique attributes match a stored row takes that row's identity,
    /// so the save updates the row instead of adding a second one, as SwiftData upserts. Of
    /// two inserts with the same values, the later one is kept. Runs in the save's transaction,
    /// after its deletions, so no other context's write comes between a lookup and the write
    /// it decides, and a save that fails leaves every model with the identity it had.
    private func resolveUniqueInserts(_ db: Database, _ plan: inout WritePlan, arrivals: [PersistentIdentifier]) throws {
        var claimed: [String: PersistentIdentifier] = [:]
        for id in arrivals {
            guard let encoded = plan.inserts[id], let type = container.type(named: id.entityName) else { continue }
            for keys in EntityDescription.of(type).uniqueKeys {
                let signature = ([id.entityName] + keys.map { String(decoding: encoded[$0] ?? Data(), as: UTF8.self) })
                    .joined(separator: "\u{0}")
                if let earlier = claimed[signature] {
                    plan.inserts[id] = nil
                    if plan.inserts[earlier] != nil {
                        plan.inserts[earlier] = encoded
                    } else {
                        plan.updates[earlier] = (encoded, Array(encoded.keys))
                    }
                    plan.moves.append((id, earlier))
                    break
                }
                if let (primaryKey, _) = try Store.uniqueMatch(db, entity: id.entityName, keys: keys, fields: encoded, excluding: id.primaryKey) {
                    let target = PersistentIdentifier(entityName: id.entityName, primaryKey: primaryKey)
                    plan.inserts[id] = nil
                    plan.updates[target] = (encoded, Array(encoded.keys))
                    plan.moves.append((id, target))
                    claimed[signature] = target
                    break
                }
                claimed[signature] = id
            }
        }
    }

    /// Gives each moved model the identity it took and the row stored under it, letting go of
    /// a held model that had the identity before.
    private func rehome(_ moves: [(from: PersistentIdentifier, to: PersistentIdentifier)], found: [PersistentIdentifier: [String: Data]]) {
        for (from, to) in moves {
            guard let entry = registry[from] else { continue }
            unregister(from)
            inserted.remove(from)
            touched.remove(from)
            if let held = registry[to], held !== entry {
                unregister(to)
                inserted.remove(to)
                touched.remove(to)
                held.model._$backing.context = nil
                detach([held.model])
            }
            entry.model._$backing.identifier = to
            entry.committed = found[to]
            register(entry, to)
        }
    }

    // MARK: Autosave

    /// Called by an accessor before the write it reports, so the model still holds what it
    /// last saved and its encoding now is the baseline its changes are measured against.
    func noteMutation(of model: some PersistentModel) {
        guard !isApplying, let id = model._$backing.identifier, let entry = registry[id], entry.model === model else { return }
        if entry.baseline == nil, entry.committed != nil {
            entry.baseline = (try? encode(model, id)) ?? [:]
        }
        touched.insert(id)
        revision += 1
        scheduleAutosave()
    }

    private func changed() {
        revision += 1
        changeHandler?()
        scheduleAutosave()
    }

    /// A number that stays the same exactly as long as every fetch would return what it did:
    /// it advances on an insert, a delete, a write to a held model, a save, a rollback, an
    /// entity read, and another context's save applied here, which this call applies first.
    /// `nil` when the schema has an entity whose writes go unreported, so no number can say.
    public func currentRevision() -> Int? {
        ModelObservation.traversing {
            _ = try? refresh()
        }
        return reportsEveryWrite ? revision : nil
    }

    private lazy var reportsEveryWrite = container.schema.types.allSatisfy { EntityDescription.of($0).tracksMutations }

    private func scheduleAutosave() {
        guard autosaveEnabled, !autosaveScheduled, !isApplying else { return }
        autosaveScheduled = true
        DispatchQueue.main.async { [self] in
            autosaveScheduled = false
            guard autosaveEnabled else { return }
            do {
                try save()
            } catch {
                PortableDataLog.error("autosave", "Autosave failed: \(error)")
            }
        }
    }

    // MARK: Reads

    public func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        try ModelObservation.traversing {
            try fetchModels(descriptor)
        }
    }

    private func fetchModels<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        try refresh()
        try ensureLoaded(T.self)
        let entity = T._$entityName
        let attributes = EntityDescription.of(T.self).attributePaths
        let cacheable = descriptor.predicate == nil && reportsEveryWrite && descriptor.sortBy.allSatisfy {
            $0.keyPath.map { attributes.contains($0) } ?? false
        }
        var results: [T]
        if cacheable, let cached = sortedReads[entity]?.first(where: {
            $0.revision == revision && ($0.order as? [SortDescriptor<T>]) == descriptor.sortBy
        }),
           let rows = cached.result as? [T] {
            results = rows
        } else {
            results = models(entity).compactMap { $0 as? T }
            if let predicate = descriptor.predicate {
                results = try results.filter { try predicate.evaluate($0) }
            }
            if !descriptor.sortBy.isEmpty {
                results.sort(using: descriptor.sortBy)
            }
            if cacheable {
                var plans = sortedReads[entity] ?? []
                plans.append((revision, descriptor.sortBy, results))
                sortedReads[entity] = Array(plans.suffix(3))
            }
        }
        let start = min(descriptor.fetchOffset ?? 0, results.count)
        let end = descriptor.fetchLimit.map { min(start + $0, results.count) } ?? results.count
        return Array(results[start ..< end])
    }

    /// The number of models `descriptor` fetches. Without a predicate, for an entity this
    /// context has not read and has no unsaved inserts or deletions of, it is counted in SQL
    /// and nothing is read; that count includes rows the context could not have read.
    public func fetchCount<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> Int {
        let entity = T._$entityName
        guard descriptor.predicate == nil, !loaded.contains(entity),
              !inserted.contains(where: { $0.entityName == entity }),
              !deleted.keys.contains(where: { $0.entityName == entity })
        else {
            return try fetch(descriptor).count
        }
        let stored = try container.store.read { db in try Store.count(db, entity: entity) }
        let remaining = max(0, stored - max(0, descriptor.fetchOffset ?? 0))
        return descriptor.fetchLimit.map { min($0, remaining) } ?? remaining
    }

    public func fetchIdentifiers(_ descriptor: FetchDescriptor<some PersistentModel>) throws -> [PersistentIdentifier] {
        try fetch(descriptor).map(\.persistentModelID)
    }

    public func model(for identifier: PersistentIdentifier) -> any PersistentModel {
        if let model = registry[identifier]?.model { return model }
        if let type = container.type(named: identifier.entityName) {
            ModelObservation.traversing {
                try? load(type)
            }
        }
        guard let model = registry[identifier]?.model else {
            fatalError("PortableData: no \(identifier.entityName) with identifier \(identifier.primaryKey) in the store")
        }
        return model
    }

    public func registeredModel<T: PersistentModel>(for identifier: PersistentIdentifier) -> T? {
        registry[identifier]?.model as? T
    }

    private func models(_ entity: String) -> [any PersistentModel] {
        guard let ids = members[entity] else { return [] }
        var seen = Set<PersistentIdentifier>()
        let live = ids.filter { registry[$0] != nil && seen.insert($0).inserted }
        if live.count != ids.count {
            members[entity] = live
        }
        return live.compactMap { registry[$0]?.model }
    }

    // MARK: Registry

    private func register(_ entry: Entry, _ id: PersistentIdentifier) {
        if registry.updateValue(entry, forKey: id) == nil {
            members[id.entityName, default: []].append(id)
        }
    }

    private func unregister(_ id: PersistentIdentifier) {
        registry[id] = nil
    }

    /// Lets go of the models whose rows another context deleted. Each stays marked deleted,
    /// and its graph is detached while this context can still reach it.
    private func forget(_ ids: some Sequence<PersistentIdentifier>) {
        var forgotten: [any PersistentModel] = []
        for id in ids {
            guard let entry = registry[id] ?? deleted[id] else { continue }
            unregister(id)
            deleted[id] = nil
            touched.remove(id)
            entry.model._$backing.isDeleted = true
            entry.model._$backing.context = nil
            forgotten.append(entry.model)
        }
        detach(forgotten)
    }

    /// Unlinks models this context lets go of (when it ends, when another context deleted
    /// their rows, when a save or rollback discards them) from one another and from the
    /// models it still holds. A dose points at its session and the session's doses point
    /// back, so a graph let go of still linked would stay alive as long as any one of its
    /// models did; on Android each live model holds a JNI global reference through its Skip
    /// bridge, and ART aborts the process when 51,200 are live.
    ///
    /// Every to-many side of each model is emptied, which breaks each cycle, and each model
    /// leaves the inverse arrays of the owners it points at. Its to-one relationships and its
    /// deleted state stay, so a dose held past its context still reaches its session. The
    /// writes register nothing and mark nothing changed.
    private func detach(_ models: [any PersistentModel]) {
        guard !models.isEmpty else { return }
        ModelObservation.traversing {
            let wasApplying = isApplying
            isApplying = true
            defer { isApplying = wasApplying }
            for model in models {
                let description = EntityDescription.of(type(of: model))
                for inverse in description.inverses where !inverse.children(model).isEmpty {
                    inverse.setChildren(model, [])
                }
                for relationship in description.toMany where !relationship.get(model).isEmpty {
                    relationship.set(model, [])
                }
            }
            for model in models {
                for relationship in EntityDescription.of(type(of: model)).toOne {
                    guard let target = relationship.get(model) else { continue }
                    for inverse in EntityDescription.of(relationship.target).inverses where inverse.childPath == relationship.path {
                        inverse.remove(model, from: target)
                    }
                }
            }
        }
    }

    // MARK: Loading

    // Called only on a fresh context dedicated to this complete backup read.
    func readAllForBackup() throws -> [LoadFailure] {
        for type in container.schema.types { try load(type) }
        return backupReadFailures
    }

    private func reportLoadFailure(_ failure: LoadFailure) {
        backupReadFailures.append(failure)
        container.report(failure)
    }

    private func load(_ type: any PersistentModel.Type) throws {
        func open<T: PersistentModel>(_: T.Type) throws {
            try ensureLoaded(T.self)
        }
        try open(type)
    }

    /// Reads `T` and every entity its relationships reach, the first time any of them is
    /// asked for. A row that cannot be read is skipped and reported; the entities count as
    /// loaded only once all their rows have been read.
    private func ensureLoaded<T: PersistentModel>(_: T.Type) throws {
        guard !loaded.contains(T._$entityName) else { return }
        var closure: [any PersistentModel.Type] = []
        var pending: [any PersistentModel.Type] = [T.self]
        while let type = pending.popLast() {
            let name = type._$entityName
            guard !loaded.contains(name), !closure.contains(where: { $0._$entityName == name }) else { continue }
            closure.append(type)
            pending += EntityDescription.of(type).related
        }
        // A closure, never `\._$entityName`: a key path through an existential metatype
        // crashes SILGen in Swift 6.4.
        let names = closure.map { type in type._$entityName }
        let (rows, current) = try container.store.read { db -> ([Store.Row], Int) in
            var rows: [Store.Row] = []
            for name in names {
                try rows += Store.rows(db, entity: name)
            }
            return try (rows, Store.generation(db))
        }
        if loaded.isEmpty {
            generation = current
        }
        isApplying = true
        defer { isApplying = false }
        var arrived: [(Entry, [String: Data], Set<String>?)] = []
        for row in rows {
            let id = PersistentIdentifier(entityName: row.entity, primaryKey: row.primaryKey)
            if let entry = registry[id] {
                // Inserted and saved here before its entity was read: take what others saved since.
                if let update = absorb(row, into: entry) {
                    arrived.append(update)
                }
                continue
            }
            guard deleted[id] == nil,
                  let type = closure.first(where: { $0._$entityName == row.entity }),
                  let (entry, fields) = decode(row, id, as: type)
            else { continue }
            register(entry, id)
            arrived.append((entry, fields, nil))
        }
        loaded.formUnion(names)
        connect(arrived)
        rebuildInverses()
        revision += 1
    }

    private func decode(_ row: Store.Row, _ id: PersistentIdentifier, as type: any PersistentModel.Type) -> (Entry, [String: Data])? {
        do {
            let fields = try RowCodec.fields(from: row.data)
            let model = try type.init(_$snapshot: Snapshot(identifier: id, fields: fields))
            model._$backing.context = self
            return (Entry(model, committed: fields), fields)
        } catch {
            reportLoadFailure(LoadFailure(entity: row.entity, primaryKey: row.primaryKey, reason: String(describing: error)))
            return nil
        }
    }

    /// Points each model's relationships named in `keys` (all when `nil`) at the models their
    /// stored keys name, then records the model's encoding of those keys as what it last saved.
    private func connect(_ entries: [(Entry, [String: Data], Set<String>?)]) {
        for (entry, fields, keys) in entries {
            let description = EntityDescription.of(type(of: entry.model))
            for relationship in description.toOne where keys?.contains(relationship.key) ?? true {
                let target = RowCodec.primaryKey(from: fields[relationship.key]).flatMap {
                    registry[PersistentIdentifier(entityName: relationship.target._$entityName, primaryKey: $0)]?.model
                }
                if relationship.get(entry.model) !== target {
                    relationship.set(entry.model, target)
                }
            }
            for relationship in description.toMany where keys?.contains(relationship.key) ?? true {
                let targets = RowCodec.primaryKeys(from: fields[relationship.key]).compactMap {
                    registry[PersistentIdentifier(entityName: relationship.target._$entityName, primaryKey: $0)]?.model
                }
                relationship.set(entry.model, targets)
            }
        }
        for (entry, fields, keys) in entries {
            guard let id = entry.model._$backing.identifier else { continue }
            let description = EntityDescription.of(type(of: entry.model))
            let renamed = description.renames.filter { key, original in
                fields[key] == nil && fields[original] != nil && keys?.contains(key) ?? true
            }
            guard entry.baseline != nil || !description.tracksMutations || !renamed.isEmpty,
                  let encoded = try? encode(entry.model, id)
            else { continue }
            if let keys, var baseline = entry.baseline {
                for key in keys {
                    baseline[key] = encoded[key]
                }
                entry.baseline = baseline
            } else if keys == nil {
                entry.baseline = encoded
            }
            // A value read from its original name has no row under its current one yet, so
            // the next save writes it there.
            for key in renamed.keys {
                entry.baseline = (entry.baseline ?? encoded).filter { $0.key != key }
                touched.insert(id)
            }
        }
    }

    private func restoreAttributes(_ entry: Entry, from fields: [String: Data], keys: Set<String>) {
        guard let id = entry.model._$backing.identifier else { return }
        do {
            try entry.model._$restore(from: Snapshot(identifier: id, fields: fields), keys: keys)
        } catch {
            reportLoadFailure(LoadFailure(entity: id.entityName, primaryKey: id.primaryKey, reason: String(describing: error)))
        }
    }

    /// Writes stored values for `keys` into a held model: attributes, then relationships.
    private func restore(_ entry: Entry, from fields: [String: Data], keys: Set<String>) {
        restoreAttributes(entry, from: fields, keys: keys)
        connect([(entry, fields, keys)])
    }

    /// Sets every inverse array from the to-one pointers of the models held, through one
    /// grouping pass per relationship. An array is assigned only when its members differ,
    /// keeping its order, so views observing an unchanged one are not invalidated.
    private func rebuildInverses() {
        let wasApplying = isApplying
        isApplying = true
        defer { isApplying = wasApplying }
        for name in Array(members.keys) {
            guard let type = container.type(named: name) else { continue }
            for inverse in EntityDescription.of(type).inverses {
                var groups: [ObjectIdentifier: [any PersistentModel]] = [:]
                for child in models(inverse.child._$entityName) {
                    if let owner = inverse.owner(of: child) {
                        groups[ObjectIdentifier(owner), default: []].append(child)
                    }
                }
                for owner in models(name) {
                    let current = inverse.children(owner)
                    var desired = groups[ObjectIdentifier(owner)] ?? []
                    // A child not yet inserted that points here stays; SwiftData inserts it on save.
                    for child in current where child._$backing.context == nil && !child.isDeleted && inverse.owner(of: child) === owner {
                        desired.append(child)
                    }
                    let wanted = Set(desired.map { ObjectIdentifier($0) })
                    let present = Set(current.map { ObjectIdentifier($0) })
                    guard wanted != present else { continue }
                    let kept = current.filter { wanted.contains(ObjectIdentifier($0)) }
                    inverse.setChildren(owner, kept + desired.filter { !present.contains(ObjectIdentifier($0)) })
                }
            }
        }
    }

    // MARK: Other contexts' saves

    /// Applies what other contexts saved since this one last read the store, and reports
    /// whether any model it holds changed.
    @discardableResult
    private func refresh() throws -> Bool {
        guard !loaded.isEmpty else { return false }
        let known = generation
        let entities = loaded
        let changes = try container.store.read { db in
            try Store.changes(db, after: known, entities: entities)
        }
        guard changes.generation > generation else { return false }
        guard apply(changes) else { return false }
        rebuildInverses()
        revision += 1
        return true
    }

    /// Brings the context up to date after another context's save and tells the UI layer,
    /// as SwiftData merges a background save into the main context.
    func storeChanged() {
        if ModelObservation.traversing({ try? refresh() }) == true {
            changeHandler?()
        }
    }

    /// Another context's rows replace this context's copies key by key, except keys this
    /// context has changed and not saved; its deletions let go of the models they name.
    @discardableResult
    private func apply(_ changes: Store.Changes) -> Bool {
        isApplying = true
        defer { isApplying = false }
        generation = max(generation, changes.generation)
        var gone = Set(changes.deleted)
        if changes.complete {
            let present = Set(changes.rows.map { PersistentIdentifier(entityName: $0.entity, primaryKey: $0.primaryKey) })
            for (id, entry) in registry where entry.committed != nil && loaded.contains(id.entityName) && !present.contains(id) {
                gone.insert(id)
            }
        }
        let forgotten = gone.filter { registry[$0]?.committed != nil || deleted[$0] != nil }
        forget(forgotten)
        let forgot = !forgotten.isEmpty
        var updated: [(Entry, [String: Data], Set<String>?)] = []
        for row in changes.rows {
            let id = PersistentIdentifier(entityName: row.entity, primaryKey: row.primaryKey)
            guard !gone.contains(id) else { continue }
            if let entry = registry[id] {
                if let update = absorb(row, into: entry) {
                    updated.append(update)
                }
            } else if let entry = deleted[id] {
                entry.committed = try? RowCodec.fields(from: row.data)
            } else if let type = container.type(named: row.entity), let (entry, fields) = decode(row, id, as: type) {
                register(entry, id)
                updated.append((entry, fields, nil))
            }
        }
        connect(updated)
        return forgot || !updated.isEmpty
    }

    /// Takes the keys of `row` that differ from what `entry` last read, except those this
    /// context has changed itself, into the held model's attributes. Returns what `connect`
    /// still has to do for its relationships, or `nil` when nothing changed.
    private func absorb(_ row: Store.Row, into entry: Entry) -> (Entry, [String: Data], Set<String>?)? {
        guard let committed = entry.committed, let fields = try? RowCodec.fields(from: row.data) else { return nil }
        let remote = Set(fields.keys).union(committed.keys).filter { fields[$0] != committed[$0] }
        let keys = remote.subtracting(changedKeys(entry))
        entry.committed = fields
        guard !keys.isEmpty else { return nil }
        restoreAttributes(entry, from: fields, keys: keys)
        return (entry, fields, keys)
    }
}
