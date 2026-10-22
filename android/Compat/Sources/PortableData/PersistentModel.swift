import Foundation

/// A class `@Model` has made storable. The underscored requirements are the macro's; app
/// code reaches a model through ``persistentModelID`` and ``modelContext``, as with SwiftData.
///
/// Refines `SendableMetatype`, as SwiftData's does, and `@Model` declares the conformance
/// on the class itself: that is what keeps a model out of `-default-isolation MainActor`,
/// so its key paths are `Sendable` and `#Predicate` and `SortDescriptor` accept them.
public protocol PersistentModel: AnyObject, Hashable, Identifiable, SendableMetatype {
    var _$backing: ModelBacking { get }
    /// Builds a model from a stored row. Relationships start empty; the context connects them.
    init(_$snapshot: Snapshot) throws
    /// Writes the stored attributes named in `keys` (every one when `nil`) back into this instance.
    func _$restore(from snapshot: Snapshot, keys: Set<String>?) throws
    /// Every stored property, relationships as the identifiers they point at.
    func _$encode(into snapshot: inout Snapshot) throws
    static func _$describe(_ entity: EntityDescription)
}

public extension PersistentModel {
    static var _$entityName: String {
        String(describing: Self.self)
    }

    /// Assigned when the model is inserted; a model never inserted has a provisional one.
    var persistentModelID: PersistentIdentifier {
        _$backing.identifier ?? PersistentIdentifier(
            entityName: Self._$entityName, primaryKey: "provisional-\(ObjectIdentifier(self).hashValue)",
        )
    }

    var modelContext: ModelContext? {
        _$backing.context
    }

    var isDeleted: Bool {
        _$backing.isDeleted
    }

    /// A model without an `id` of its own is identified by its store identity, as in SwiftData.
    var id: PersistentIdentifier {
        persistentModelID
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// What a model knows about its place in a store.
public final class ModelBacking: @unchecked Sendable {
    public var identifier: PersistentIdentifier?
    weak var context: ModelContext?
    var isDeleted = false

    public init() {}
}

// MARK: - Accessor hooks

/// Called by a tracked setter before a to-one relationship changes from `old` to `new`:
/// moves `child` from `old`'s inverse array to `new`'s, as SwiftData updates the other side
/// of a relationship on assignment.
public func _willSet<Target: PersistentModel>(_ child: some PersistentModel, from old: Target?, to new: Target?) {
    guard old !== new else { return }
    let context = child._$backing.context
    if context?.isApplying == true { return }
    let childType = ObjectIdentifier(type(of: child))
    ModelObservation.traversing {
        for inverse in EntityDescription.of(Target.self).inverses where ObjectIdentifier(inverse.child) == childType {
            guard inverse.owner(of: child) === old else { continue }
            if let old {
                inverse.remove(child, from: old)
            }
            if let new {
                inverse.add(child, to: new)
            }
            break
        }
    }
    context?.noteMutation(of: child)
}

/// Called by a tracked setter before any other stored property changes.
public func _willSet<Value>(_ model: some PersistentModel, from _: Value, to _: Value) {
    model._$backing.context?.noteMutation(of: model)
}

/// Called by a tracked property's `_modify`, which changes the value in place.
public func _willMutate(_ model: some PersistentModel) {
    model._$backing.context?.noteMutation(of: model)
}

/// Whether an assignment changes the value, so observers hear only of real changes, as
/// Observation's own setters decide it.
public func _differs<Value>(_: Value, _: Value) -> Bool {
    true
}

public func _differs<Value: Equatable>(_ lhs: Value, _ rhs: Value) -> Bool {
    lhs != rhs
}

public func _differs<Value: AnyObject>(_ lhs: Value, _ rhs: Value) -> Bool {
    lhs !== rhs
}

public func _differs<Value: Equatable & AnyObject>(_ lhs: Value, _ rhs: Value) -> Bool {
    lhs != rhs
}
