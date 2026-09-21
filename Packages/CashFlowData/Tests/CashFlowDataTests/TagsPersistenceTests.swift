import Foundation
import SwiftData
import Testing
import CashFlowKit
@testable import CashFlowData

@Suite("Tags persistence")
struct TagsPersistenceTests {
    @Test("Create, assign, filter, and delete tags")
    func createAssignFilterDelete() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let tags = SwiftDataTagRepository(modelContainer: container)
        let txs = SwiftDataTransactionRepository(modelContainer: container)
        let context = ModelContext(container)

        let payload = RemoteSyncTestFixtures.demoPayload(accounts: [
            RemoteSyncTestFixtures.account(
                identity: RemoteSyncTestFixtures.demoIdentity(accountID: "a1"),
                name: "Checking",
                balance: 100,
                transactions: [
                    RemoteTransactionSnapshot(
                        externalID: "t1",
                        amount: -20,
                        postedDate: Date(timeIntervalSince1970: 1_700_000_000),
                        description: "Coffee",
                        suggestedCategoryID: SystemCategory.dining.id
                    ),
                    RemoteTransactionSnapshot(
                        externalID: "t2",
                        amount: -40,
                        postedDate: Date(timeIntervalSince1970: 1_700_000_100),
                        description: "Groceries",
                        suggestedCategoryID: SystemCategory.groceries.id
                    ),
                ]
            ),
        ])
        try SyncMergeEngine.merge(payload: payload, into: context)

        let trip = try await tags.create(name: "  Japan Trip  ")
        #expect(trip.name == "Japan Trip")
        let all = try await tags.fetchAll()
        #expect(all.map(\.name) == ["Japan Trip"])

        let page = try await txs.fetchPage(filter: .all, cursor: nil, limit: 50)
        let coffee = try #require(page.items.first(where: { $0.externalID == "t1" }))
        try await txs.updateTags(transactionID: coffee.id, tagIDs: [trip.id])

        let tagged = try await txs.fetchPage(
            filter: TransactionFilter(tagID: trip.id),
            cursor: nil,
            limit: 50
        )
        #expect(tagged.items.count == 1)
        #expect(tagged.items.first?.tagIDs == [trip.id])

        try await tags.rename(id: trip.id, name: "Tokyo Trip")
        #expect(try await tags.fetchAll().first?.name == "Tokyo Trip")

        try await tags.delete(id: trip.id)
        #expect(try await tags.fetchAll().isEmpty)
        let afterDelete = try await txs.fetchPage(filter: .all, cursor: nil, limit: 50)
        #expect(afterDelete.items.allSatisfy { $0.tagIDs.isEmpty })
    }

    @Test("resetAll deletes tags")
    func wipeClearsTags() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let tags = SwiftDataTagRepository(modelContainer: container)
        _ = try await tags.create(name: "Concert")

        let resetter = LocalDataResetter(modelContainer: container)
        try await resetter.resetAll()
        #expect(try await tags.fetchAll().isEmpty)
    }
}
