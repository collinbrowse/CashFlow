import Foundation
import SwiftData
import Testing
import CashFlowKit
@testable import CashFlowData

@Suite("Enrichment persistence")
struct EnrichmentPersistenceTests {
    @Test("updateEnrichment and applyTagAssignments persist")
    func enrichmentAndBulkTags() async throws {
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
                        description: "STARBUCKS BANGKOK TH",
                        suggestedCategoryID: SystemCategory.other.id
                    ),
                ]
            ),
        ])
        try SyncMergeEngine.merge(payload: payload, into: context)

        let page = try await txs.fetchPage(filter: .all, cursor: nil, limit: 10)
        let coffee = try #require(page.items.first)
        #expect(coffee.enrichedTitle == nil)

        try await txs.updateEnrichment(
            transactionID: coffee.id,
            title: "Starbucks",
            location: "Bangkok",
            source: .llm,
            clearLocation: false
        )
        let enriched = try await txs.fetchPage(filter: .all, cursor: nil, limit: 10)
        #expect(enriched.items.first?.enrichedTitle == "Starbucks")
        #expect(enriched.items.first?.enrichedLocation == "Bangkok")
        #expect(enriched.items.first?.titleSource == .llm)
        #expect(enriched.items.first?.displayTitle == "Starbucks")
        #expect(enriched.items.first?.displayLocation == "Bangkok")

        let trip = try await tags.create(name: "Southeast Asia")
        try await txs.applyTagAssignments([
            TagAssignment(transactionID: coffee.id, tagIDs: [trip.id]),
        ])
        let tagged = try await txs.fetchPage(filter: .all, cursor: nil, limit: 10)
        #expect(tagged.items.first?.tagIDs == [trip.id])
    }
}
