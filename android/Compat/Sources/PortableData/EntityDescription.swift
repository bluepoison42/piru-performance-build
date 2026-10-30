import Foundation
import Synchronization

/// What PortableData knows about a model type beyond its stored values: its relationships
/// with their delete rules, its unique attributes and its renamed keys. `@Model` generates
/// the `_$describe` that fills one in; ``of(_:)`` builds each type's once.
public final class EntityDescription: @unchecked Sendable {
    public let name: String
    let type: any PersistentModel.Type
    /// Whether every stored property's accessors report writes, so a context need look only at
    /// the models it was told about. `@Model` clears it for a property it leaves untracked.
    public var tracksMutations = true
    private(set) var attributePaths: Set<AnyKeyPath> = []
    private(set) var toOne: [ToOne] = []
    private(set) var toMany: [ToMany] = []
    private(set) var inverses: [Inverse] = []
    private(set) var uniqueKeys: [[String]] = []
    /// Each renamed property's current key → the key an older row stored it under.
    private(set) var renames: [String: String] = [:]

    init(_ type: any PersistentModel.Type) {
        self.type = type
        name = type._$entityName
    }

    private static let cache = Mutex<[ObjectIdentifier: EntityDescription]>([:])

    static func of(_ type: any PersistentModel.Type) -> EntityDescription {
        if let known = cache.withLock({ $0[ObjectIdentifier(type)] }) { return known }
        let description = EntityDescription(type)
        type._$describe(description)
        return cache.withLock { cache in
            if let known = cache[ObjectIdentifier(type)] { return known }
            cache[ObjectIdentifier(type)] = description
            return description
        }
    }

    // MARK: Building

    /// A stored attribute: nothing to record beyond its value.
    public func property(_: String, _ path: KeyPath<some Any, some Any>, deleteRule _: Schema.Relationship.DeleteRule) {
        attributePaths.insert(path)
    }

    public func property<Owner: PersistentModel, Target: PersistentModel>(
        _ key: String, _ path: ReferenceWritableKeyPath<Owner, Target?>, deleteRule: Schema.Relationship.DeleteRule,
    ) {
        toOne.append(ToOne(
            key: key,
            target: Target.self,
            path: path,
            deleteRule: deleteRule,
            get: { ($0 as! Owner)[keyPath: path] },
            set: { ($0 as! Owner)[keyPath: path] = $1.map { $0 as! Target } },
        ))
    }

    public func property<Owner: PersistentModel, Target: PersistentModel>(
        _ key: String, _ path: ReferenceWritableKeyPath<Owner, [Target]?>, deleteRule: Schema.Relationship.DeleteRule,
    ) {
        toMany.append(ToMany(
            key: key,
            target: Target.self,
            deleteRule: deleteRule,
            get: { ($0 as! Owner)[keyPath: path] ?? [] },
            set: { ($0 as! Owner)[keyPath: path] = $1.map { $0 as! Target } },
        ))
    }

    public func property<Owner: PersistentModel, Target: PersistentModel>(
        _ key: String, _ path: ReferenceWritableKeyPath<Owner, [Target]>, deleteRule: Schema.Relationship.DeleteRule,
    ) {
        toMany.append(ToMany(
            key: key,
            target: Target.self,
            deleteRule: deleteRule,
            get: { ($0 as! Owner)[keyPath: path] },
            set: { ($0 as! Owner)[keyPath: path] = $1.map { $0 as! Target } },
        ))
    }

    /// A to-many side derived from the children's to-one `childPath`, never stored itself.
    public func inverse<Owner: PersistentModel, Child: PersistentModel>(
        _ key: String, _ path: ReferenceWritableKeyPath<Owner, [Child]?>, _ childPath: ReferenceWritableKeyPath<Child, Owner?>,
        deleteRule: Schema.Relationship.DeleteRule,
    ) {
        inverses.append(Inverse(
            key: key,
            child: Child.self,
            childPath: childPath,
            deleteRule: deleteRule,
            children: { ($0 as! Owner)[keyPath: path] ?? [] },
            setChildren: { ($0 as! Owner)[keyPath: path] = $1.map { $0 as! Child } },
            owner: { ($0 as! Child)[keyPath: childPath] },
            setOwner: { ($0 as! Child)[keyPath: childPath] = $1.map { $0 as! Owner } },
        ))
    }

    public func inverse<Owner: PersistentModel, Child: PersistentModel>(
        _ key: String, _ path: ReferenceWritableKeyPath<Owner, [Child]>, _ childPath: ReferenceWritableKeyPath<Child, Owner?>,
        deleteRule: Schema.Relationship.DeleteRule,
    ) {
        inverses.append(Inverse(
            key: key,
            child: Child.self,
            childPath: childPath,
            deleteRule: deleteRule,
            children: { ($0 as! Owner)[keyPath: path] },
            setChildren: { ($0 as! Owner)[keyPath: path] = $1.map { $0 as! Child } },
            owner: { ($0 as! Child)[keyPath: childPath] },
            setOwner: { ($0 as! Child)[keyPath: childPath] = $1.map { $0 as! Owner } },
        ))
    }

    public func unique(_ keys: [String]) {
        uniqueKeys.append(keys)
    }

    public func rename(_ key: String, from original: String) {
        renames[key] = original
    }

    // MARK: Relationships

    struct ToOne {
        let key: String
        let target: any PersistentModel.Type
        let path: AnyKeyPath
        let deleteRule: Schema.Relationship.DeleteRule
        let get: (any PersistentModel) -> (any PersistentModel)?
        let set: (any PersistentModel, (any PersistentModel)?) -> Void
    }

    struct ToMany {
        let key: String
        let target: any PersistentModel.Type
        let deleteRule: Schema.Relationship.DeleteRule
        let get: (any PersistentModel) -> [any PersistentModel]
        let set: (any PersistentModel, [any PersistentModel]) -> Void
    }

    struct Inverse {
        let key: String
        let child: any PersistentModel.Type
        let childPath: AnyKeyPath
        let deleteRule: Schema.Relationship.DeleteRule
        let children: (any PersistentModel) -> [any PersistentModel]
        let setChildren: (any PersistentModel, [any PersistentModel]) -> Void
        let owner: (any PersistentModel) -> (any PersistentModel)?
        let setOwner: (any PersistentModel, (any PersistentModel)?) -> Void

        func owner(of child: any PersistentModel) -> (any PersistentModel)? {
            owner(child)
        }

        func remove(_ child: any PersistentModel, from owner: any PersistentModel) {
            let current = children(owner)
            guard current.contains(where: { $0 === child }) else { return }
            setChildren(owner, current.filter { $0 !== child })
        }

        func add(_ child: any PersistentModel, to owner: any PersistentModel) {
            let current = children(owner)
            guard !current.contains(where: { $0 === child }) else { return }
            setChildren(owner, current + [child])
        }
    }

    /// Every entity type a load of this one must bring in: what its relationships point at,
    /// and what points back at it through an inverse.
    var related: [any PersistentModel.Type] {
        toOne.map(\.target) + toMany.map(\.target) + inverses.map(\.child)
    }
}
