import Foundation
import Synchronization
import PortableData
import Testing

private enum QuerySortProbe {
    static let comparisons = Mutex(0)
    static let direction = Mutex(1)
    static func reset() { comparisons.withLock { $0 = 0 } }
    static var count: Int { comparisons.withLock { $0 } }
}

private struct CountedRank: Codable, Comparable, Sendable {
    var value: Int
    static func < (lhs: Self, rhs: Self) -> Bool {
        QuerySortProbe.comparisons.withLock { $0 += 1 }
        return lhs.value < rhs.value
    }
}

@Model
private final class QueryCacheRow {
    var id: UUID = UUID()
    var rank: CountedRank
    var notes: String?
    var computedRank: CountedRank {
        CountedRank(value: rank.value * QuerySortProbe.direction.withLock { $0 })
    }
    init(_ rank: Int) { self.rank = CountedRank(value: rank); notes = "alias: \"fixture\"" }
}

@Model
private final class UntrackedQueryCacheRow {
    var id: UUID = UUID()
    var rank: CountedRank { didSet {} }
    init(_ rank: Int) { self.rank = CountedRank(value: rank) }
}

// Observation's onChange is Sendable but executes synchronously on the writing thread.
private final class ReentrantQueryProbe: @unchecked Sendable {
    let context: ModelContext
    var values: [Int]?
    init(_ context: ModelContext) { self.context = context }
    func fetch() {
        values = try? context.fetch(FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)])).map(\.rank.value)
    }
}

@Suite(.serialized)
struct QueryResultCacheTests {
    private func fixture(_ count: Int = 8) throws -> (ModelContainer, ModelContext, [QueryCacheRow]) {
        let url = FileManager.default.temporaryDirectory.appending(path: "query-cache-\(UUID()).sqlite")
        let container = try ModelContainer(for: QueryCacheRow.self, configurations: ModelConfiguration(url: url))
        let context = ModelContext(container)
        let rows = (0..<count).reversed().map { QueryCacheRow($0) }
        rows.forEach { context.insert($0) }
        try context.save()
        return (container, context, rows)
    }

    @Test func repeatedRequestsReuseAnUnchangedSort() throws {
        let (_, context, _) = try fixture(1794)
        _ = try context.fetch(FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)]))
        QuerySortProbe.reset()
        for _ in 0..<5 {
            let rows = try context.fetch(FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)]))
            #expect(rows.first?.rank.value == 0)
            #expect(rows.last?.rank.value == 1793)
        }
        #expect(QuerySortProbe.count == 0, "Repeated fetch unexpectedly sorted unchanged rows")
    }

    @Test func orderAndPagingAreIndependent() throws {
        let (_, context, _) = try fixture()
        _ = try context.fetch(FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)]))
        var page = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)])
        page.fetchOffset = 2; page.fetchLimit = 3
        QuerySortProbe.reset()
        #expect(try context.fetch(page).map(\.rank.value) == [2,3,4])
        #expect(QuerySortProbe.count == 0)
        let reverse = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank, order: .reverse)])
        #expect(try context.fetch(reverse).map(\.rank.value) == Array((0..<8).reversed()))
        #expect(QuerySortProbe.count > 0)
        _ = try context.fetch(FetchDescriptor<QueryCacheRow>())
        QuerySortProbe.reset()
        #expect(try context.fetch(page).map(\.rank.value) == [2,3,4])
        #expect(try context.fetch(reverse).first?.rank.value == 7)
        #expect(QuerySortProbe.count == 0, "Chronological and unsorted tab queries evicted each other")
    }

    @Test func mutationsInsertionsDeletionsAndRollbackRefreshTheSort() throws {
        let (_, context, rows) = try fixture()
        let query = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)])
        _ = try context.fetch(query)
        rows[0].rank = CountedRank(value: -1)
        #expect(try context.fetch(query).first === rows[0])
        context.rollback()
        #expect(try context.fetch(query).first?.rank.value == 0)
        let added = QueryCacheRow(-2)
        context.insert(added)
        #expect(try context.fetch(query).first === added)
        context.delete(added)
        #expect(try context.fetch(query).count == 8)
        #expect(try context.fetch(query).first?.notes == "alias: \"fixture\"")
    }

    @Test func synchronousWillSetFetchCannotCacheThePreAssignmentOrder() throws {
        let (_, context, rows) = try fixture(2)
        let query = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)])
        #expect(!context.autosaveEnabled)
        #expect(try context.fetch(query).map(\.rank.value) == [0, 1])
        let probe = ReentrantQueryProbe(context)
        withObservationTracking {
            _ = rows[0].rank
        } onChange: {
            probe.fetch()
        }
        rows[0].rank = CountedRank(value: -1)
        #expect(probe.values == [0, 1], "The synchronous observer must see the old values")
        #expect(try context.fetch(query).map(\.rank.value) == [-1, 0])
        QuerySortProbe.reset()
        #expect(try context.fetch(query).first === rows[0])
        #expect(QuerySortProbe.count == 0, "The corrected order should still be cached")
    }

    @Test func otherContainersSavesAreVisible() throws {
        let (container, context, _) = try fixture()
        let query = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)])
        _ = try context.fetch(query)
        let other = try ModelContext(ModelContainer(for: Schema([QueryCacheRow.self]), configurations: container.configurations))
        let row = try #require(other.fetch(query).last)
        row.rank = CountedRank(value: -3)
        try other.save()
        #expect(try context.fetch(query).first?.id == row.id)
        #expect(try context.fetch(query).first?.rank.value == -3)
    }

    @Test func predicatesNeverReuseAnUnfilteredResult() throws {
        let (_, context, _) = try fixture()
        _ = try context.fetch(FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)]))
        let filter = FetchDescriptor<QueryCacheRow>(predicate: #Predicate { $0.rank.value >= 4 }, sortBy: [SortDescriptor(\.rank)])
        #expect(try context.fetch(filter).map(\.rank.value) == [4,5,6,7])
        QuerySortProbe.reset()
        #expect(try context.fetch(filter).count == 4)
        #expect(QuerySortProbe.count > 0)
    }

    @Test func computedSortKeysAreNotCached() throws {
        let (_, context, _) = try fixture()
        let query = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.computedRank)])
        #expect(try context.fetch(query).first?.rank.value == 0)
        QuerySortProbe.direction.withLock { $0 = -1 }
        defer { QuerySortProbe.direction.withLock { $0 = 1 } }
        #expect(try context.fetch(query).first?.rank.value == 7)
    }

    @Test func unreportedWritesAreNotCached() throws {
        let container = try ModelContainer(for: UntrackedQueryCacheRow.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let a = UntrackedQueryCacheRow(0), b = UntrackedQueryCacheRow(1)
        context.insert(a); context.insert(b)
        let query = FetchDescriptor<UntrackedQueryCacheRow>(sortBy: [SortDescriptor(\.rank)])
        #expect(context.currentRevision() == nil)
        #expect(try context.fetch(query).first === a)
        b.rank = CountedRank(value: -1)
        #expect(try context.fetch(query).first === b)
    }
}
