extension Sequence {
    /// The elements in order, keeping only the first for each distinct key —
    /// so a `ForEach` keyed on that value can never see a duplicate id.
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
