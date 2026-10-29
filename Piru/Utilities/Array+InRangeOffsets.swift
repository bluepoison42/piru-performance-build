import SwiftUI

extension Array {
    /// Removes the elements at `offsets` that are still in range, skipping the
    /// rest. A List's `onDelete` hands these in, and on Android a swipe can
    /// report its delete twice: the second offset points into a list already
    /// one shorter, where `remove(atOffsets:)` traps.
    mutating func remove(inRangeOffsets offsets: IndexSet) {
        let valid = IndexSet(offsets.filter { indices.contains($0) })
        guard !valid.isEmpty else { return }
        remove(atOffsets: valid)
    }
}
