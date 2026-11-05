import Foundation

/// One model's stored form: each property as the raw JSON of its value, a to-one
/// relationship as the primary key it points at, a to-many as an array of them.
///
/// A row is read into ``fields`` key by key without re-serializing any value, so a key no
/// property names survives the row's next write untouched.
public struct Snapshot {
    public let identifier: PersistentIdentifier
    var fields: [String: Data]
    var written: [String: Data] = [:]

    init(identifier: PersistentIdentifier, fields: [String: Data] = [:]) {
        self.identifier = identifier
        self.fields = fields
    }

    // MARK: Reading

    private func raw(_ key: String, _ original: String?) -> Data? {
        fields[key] ?? original.flatMap { fields[$0] }
    }

    /// A value that is absent decodes as `nil` when `T` is optional; for any other `T` the
    /// row cannot be read.
    public func decode<T: Decodable>(_ key: String, original: String? = nil) throws -> T {
        guard let raw = raw(key, original) else {
            if let none = (T.self as? any OptionalValue.Type)?.none as? T { return none }
            throw PortableDataError.missingValue(entity: identifier.entityName, key: key)
        }
        return try Self.decode(T.self, from: raw, entity: identifier.entityName, key: key)
    }

    /// A value that is absent, or `null` where `T` is not optional, decodes as `value`: the
    /// property's initializer, which is what a row written before the property existed holds.
    public func decode<T: Decodable>(_ key: String, original: String? = nil, default value: @autoclosure () -> T) throws -> T {
        guard let raw = raw(key, original), !(RowCodec.isNull(raw) && !(T.self is any OptionalValue.Type)) else {
            return value()
        }
        return try Self.decode(T.self, from: raw, entity: identifier.entityName, key: key)
    }

    /// Relationships start empty; the context connects them once every model they could
    /// point at exists.
    public func decode<M: PersistentModel>(_: String, original _: String? = nil) throws -> M? {
        nil
    }

    public func decode<M: PersistentModel>(_: String, original _: String? = nil, default value: @autoclosure () -> M?) throws -> M? {
        value()
    }

    public func decode<M: PersistentModel>(_: String, original _: String? = nil) throws -> [M]? {
        nil
    }

    public func decode<M: PersistentModel>(_: String, original _: String? = nil, default value: @autoclosure () -> [M]?) throws -> [M]? {
        value()
    }

    public func decode<M: PersistentModel>(_: String, original _: String? = nil) throws -> [M] {
        []
    }

    public func decode<M: PersistentModel>(_: String, original _: String? = nil, default value: @autoclosure () -> [M]) throws -> [M] {
        value()
    }

    // MARK: Restoring

    /// Assigns the stored value to a live model's property when `keys` names it.
    public func restore<Owner>(
        _ path: ReferenceWritableKeyPath<Owner, some Decodable>, on owner: Owner, _ key: String, original: String? = nil, keys: Set<String>?,
    ) throws {
        guard keys?.contains(key) ?? true else { return }
        owner[keyPath: path] = try decode(key, original: original)
    }

    public func restore<Owner, Value: Decodable>(
        _ path: ReferenceWritableKeyPath<Owner, Value>, on owner: Owner, _ key: String, original: String? = nil,
        default value: @autoclosure () -> Value, keys: Set<String>?,
    ) throws {
        guard keys?.contains(key) ?? true else { return }
        owner[keyPath: path] = try decode(key, original: original, default: value())
    }

    /// Relationships are restored by the context, and a `let` keeps the value it was built with.
    public func restore<Owner>(_: KeyPath<Owner, some Any>, on _: Owner, _: String, original _: String? = nil, keys _: Set<String>?) {}

    public func restore<Owner, Value>(
        _: KeyPath<Owner, Value>, on _: Owner, _: String, original _: String? = nil, default _: @autoclosure () -> Value, keys _: Set<String>?,
    ) {}

    // MARK: Writing

    /// Throws for a value JSON cannot hold (a non-finite `Double`), so a save fails whole
    /// rather than storing a `null` the property cannot be read back from.
    public mutating func encode(_ value: some Encodable, _ key: String) throws {
        if let primitive = value as? any PrimitiveJSON {
            guard let json = primitive.json else {
                throw PortableDataError.unencodable(entity: identifier.entityName, key: key, underlying: "\(value) is not a JSON number")
            }
            written[key] = json
            return
        }
        do {
            written[key] = try Self.encoder.encode(value)
        } catch {
            throw PortableDataError.unencodable(entity: identifier.entityName, key: key, underlying: String(describing: error))
        }
    }

    public mutating func encode(_ value: (some PersistentModel)?, _ key: String) {
        written[key] = RowCodec.primaryKey(value.flatMap(Self.liveKey))
    }

    public mutating func encode(_ value: [some PersistentModel]?, _ key: String) {
        written[key] = RowCodec.primaryKeys((value ?? []).compactMap(Self.liveKey))
    }

    public mutating func encode(_ value: [some PersistentModel], _ key: String) {
        written[key] = RowCodec.primaryKeys(value.compactMap(Self.liveKey))
    }

    /// A deleted or never-inserted target is stored as no reference. The context inserts
    /// every model a saved one points at before it encodes, so a live target has its key.
    private static func liveKey(_ model: some PersistentModel) -> String? {
        guard !model.isDeleted else { return nil }
        return model._$backing.identifier?.primaryKey
    }

    // MARK: Coding

    /// The format rows have always used: dates as seconds since the reference date, data as
    /// base64. Sorted keys make a nested dictionary encode the same way every time, which
    /// is what lets an unchanged value compare equal to its stored form.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()

    static func decode<T: Decodable>(_: T.Type, from raw: Data, entity: String, key: String) throws -> T {
        if let primitive = T.self as? any PrimitiveJSON.Type, let decoded = primitive.init(json: raw), let value = decoded as? T {
            return value
        }
        do {
            return try decoder.decode(T.self, from: raw)
        } catch {
            throw PortableDataError.undecodable(entity: entity, key: key, underlying: String(describing: error))
        }
    }
}

/// `Optional`, whatever it wraps: lets a generic decode give `nil` for an absent key.
protocol OptionalValue {
    static var none: Self { get }
}

extension Optional: OptionalValue {}

/// Reads and writes a row's JSON object one top-level key at a time, keeping each value's
/// bytes exactly as stored.
enum RowCodec {
    /// Splits `{"key": value, …}` into each key's raw value, a slice sharing the row's bytes.
    static func fields(from data: Data) throws -> [String: Data] {
        let ranges = try data.withUnsafeBytes { buffer in
            var scanner = Scanner(bytes: buffer.bindMemory(to: UInt8.self))
            return try scanner.object()
        }
        let start = data.startIndex
        return ranges.mapValues { data[start + $0.lowerBound ..< start + $0.upperBound] }
    }

    static func data(from fields: [String: Data]) -> Data {
        var out = Data("{".utf8)
        for (index, key) in fields.keys.sorted().enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            out.append(string(key))
            out.append(UInt8(ascii: ":"))
            out.append(fields[key]!)
        }
        out.append(UInt8(ascii: "}"))
        return out
    }

    static func isNull(_ raw: Data) -> Bool {
        raw.elementsEqual("null".utf8)
    }

    static func primaryKey(_ key: String?) -> Data {
        key.map(string) ?? Data("null".utf8)
    }

    static func primaryKeys(_ keys: [String]) -> Data {
        var out = Data("[".utf8)
        for (index, key) in keys.enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            out.append(string(key))
        }
        out.append(UInt8(ascii: "]"))
        return out
    }

    static func string(_ value: String) -> Data {
        (try? Snapshot.encoder.encode(value)) ?? Data("\"\"".utf8)
    }

    /// The primary key a to-one field names, or `nil` for `null`.
    static func primaryKey(from raw: Data?) -> String? {
        guard let raw, !isNull(raw) else { return nil }
        return try? Snapshot.decoder.decode(String.self, from: raw)
    }

    static func primaryKeys(from raw: Data?) -> [String] {
        guard let raw, !isNull(raw) else { return [] }
        return (try? Snapshot.decoder.decode([String].self, from: raw)) ?? []
    }

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
        }

        mutating func object() throws -> [String: Range<Int>] {
            skipSpace()
            try expect(UInt8(ascii: "{"))
            var fields: [String: Range<Int>] = [:]
            skipSpace()
            if peek() == UInt8(ascii: "}") {
                index += 1
                return fields
            }
            while true {
                skipSpace()
                let keyStart = index
                try skipString()
                let raw = Data(bytes[keyStart ..< index])
                let key = try String(json: raw) ?? Snapshot.decoder.decode(String.self, from: raw)
                skipSpace()
                try expect(UInt8(ascii: ":"))
                skipSpace()
                let valueStart = index
                try skipValue()
                fields[key] = valueStart ..< index
                skipSpace()
                guard let next = peek() else { throw PortableDataError.malformedRow }
                index += 1
                if next == UInt8(ascii: "}") { return fields }
                guard next == UInt8(ascii: ",") else { throw PortableDataError.malformedRow }
            }
        }

        private func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard peek() == byte else { throw PortableDataError.malformedRow }
            index += 1
        }

        private mutating func skipSpace() {
            while let byte = peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                index += 1
            }
        }

        private mutating func skipString() throws {
            try expect(UInt8(ascii: "\""))
            while let byte = peek() {
                index += 1
                if byte == UInt8(ascii: "\\") {
                    index += 1
                } else if byte == UInt8(ascii: "\"") {
                    return
                }
            }
            throw PortableDataError.malformedRow
        }

        /// One value of any kind: a string, a nested object or array, or a bare literal.
        private mutating func skipValue() throws {
            guard let first = peek() else { throw PortableDataError.malformedRow }
            if first == UInt8(ascii: "\"") {
                return try skipString()
            }
            if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
                var depth = 0
                while let byte = peek() {
                    if byte == UInt8(ascii: "\"") {
                        try skipString()
                        continue
                    }
                    index += 1
                    if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                        depth += 1
                    } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                        depth -= 1
                        if depth == 0 { return }
                    }
                }
                throw PortableDataError.malformedRow
            }
            let start = index
            while let byte = peek(), byte != UInt8(ascii: ","), byte != UInt8(ascii: "}"),
                  byte != 0x20, byte != 0x0A, byte != 0x0D, byte != 0x09 {
                index += 1
            }
            if index == start { throw PortableDataError.malformedRow }
        }
    }
}
