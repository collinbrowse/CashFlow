import Foundation
import SwiftData
import Testing
import CashFlowKit
@testable import CashFlowData

@Suite("Merchant parse memo")
struct MerchantParseMemoStoreTests {
    @Test("Memo hit skips a second enricher call")
    func memoHitSkipsEnricher() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let memo = MerchantParseMemoStore(modelContainer: container)
        let enricher = CountingDescriptionEnricher(
            result: ParsedTransactionDescription(
                title: "Starbucks",
                location: "Denver",
                raw: "STARBUCKS DENVER CO"
            )
        )
        let txs = MockMemoTransactionRepository(
            needing: [
                Transaction(
                    id: TransactionID("1"),
                    accountID: AccountID("a"),
                    externalID: "e1",
                    amount: -9,
                    postedDate: .now,
                    description: "STARBUCKS DENVER CO",
                    categoryID: SystemCategory.other.id
                ),
                Transaction(
                    id: TransactionID("2"),
                    accountID: AccountID("a"),
                    externalID: "e2",
                    amount: -4,
                    postedDate: .now,
                    description: "STARBUCKS  DENVER CO",
                    categoryID: SystemCategory.other.id
                ),
            ]
        )
        let coordinator = TransactionEnrichmentCoordinator(
            availability: FixedMemoAvailability(.available),
            descriptionEnricher: enricher,
            categoryEnricher: StubMemoCategoryEnricher(),
            transactionRepository: txs,
            accountRepository: EmptyAccountRepository(),
            ruleRepository: EmptyMemoRuleRepository(),
            memoStore: memo,
            workCoordinator: FoundationModelsWorkCoordinator()
        )
        _ = await coordinator.enrichAfterSync(skipIfLargeBacklog: false, onProgress: nil)
        #expect(await enricher.callCount == 1)
        #expect(txs.enrichmentUpdates.count == 2)
    }
}

@Suite("Enrichment sanitizer")
struct EnrichmentSanitizerTests {
    @Test("Clears leaked titles and rule apply snapshots")
    func clearsLeaksAndSnapshots() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let account = AccountEntity(
            id: "acct",
            externalID: "ext",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 1,
            balanceDate: .now
        )
        context.insert(account)
        context.insert(
            TransactionEntity(
                id: "t1",
                externalID: "u1",
                accountID: account.id,
                amount: -5,
                postedDate: .now,
                transactionDescription: "MOBILE DEPOSIT",
                categoryID: SystemCategory.other.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: false,
                isPending: false,
                syncKey: "ext|u1",
                account: account,
                enrichedTitle: "GenerableMerchantParse",
                enrichedLocation: nil,
                titleSourceRaw: TitleSource.llm.rawValue
            )
        )
        context.insert(
            CategorizationRuleEntity(
                id: "r1",
                categoryID: SystemCategory.dining.id.rawValue,
                priority: 0,
                isEnabled: true,
                conditionsData: Data(),
                renameTitle: nil,
                renameLocation: nil,
                appliesCategory: true,
                applySnapshotData: Data([1, 2, 3])
            )
        )
        try context.save()

        try EnrichmentSanitizer.run(modelContainer: container)

        let tx = try #require(
            try ModelContext(container).fetch(FetchDescriptor<TransactionEntity>()).first
        )
        #expect(tx.enrichedTitle == nil)
        let rule = try #require(
            try ModelContext(container).fetch(FetchDescriptor<CategorizationRuleEntity>()).first
        )
        #expect(rule.applySnapshotData == nil)
    }

    @Test("Strips location left in lazy LLM titles")
    func stripsLazyLocationFromTitle() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let account = AccountEntity(
            id: "acct",
            externalID: "ext",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 1,
            balanceDate: .now
        )
        context.insert(account)
        context.insert(
            TransactionEntity(
                id: "t1",
                externalID: "u1",
                accountID: account.id,
                amount: -42.54,
                postedDate: .now,
                transactionDescription: "TEQUILAS       DURANGO      CO",
                categoryID: SystemCategory.other.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: false,
                isPending: false,
                syncKey: "ext|u1",
                account: account,
                enrichedTitle: "TEQUILAS DURANGO CO",
                enrichedLocation: "DURANGO CO",
                titleSourceRaw: TitleSource.llm.rawValue
            )
        )
        try context.save()

        try EnrichmentSanitizer.run(modelContainer: container)

        let tx = try #require(
            try ModelContext(container).fetch(FetchDescriptor<TransactionEntity>()).first
        )
        #expect(tx.enrichedTitle == "TEQUILAS")
        #expect(tx.enrichedLocation == "DURANGO CO")
    }
}

private struct FixedMemoAvailability: OnDeviceModelAvailabilityChecking {
    let value: OnDeviceModelAvailability
    init(_ value: OnDeviceModelAvailability) { self.value = value }
    func availability() async -> OnDeviceModelAvailability { value }
}

private actor CountingDescriptionEnricher: TransactionDescriptionEnriching {
    let result: ParsedTransactionDescription
    private(set) var callCount = 0
    init(result: ParsedTransactionDescription) { self.result = result }
    func enrich(rawDescription: String) async -> ParsedTransactionDescription {
        callCount += 1
        return result
    }
}

private struct StubMemoCategoryEnricher: TransactionCategoryEnriching {
    func suggestCategory(_ request: CategorySuggestionRequest) async -> CategoryID? { nil }
}

private struct EmptyMemoRuleRepository: CategorizationRuleRepository {
    func fetchAll() async throws -> [CategorizationRule] { [] }
    func upsert(_ rule: CategorizationRule) async throws {}
    func delete(id: CategorizationRuleID) async throws {}
    func reorder(ids: [CategorizationRuleID]) async throws {}
}

private final class MockMemoTransactionRepository: TransactionRepository, @unchecked Sendable {
    var needing: [Transaction]
    var enrichmentUpdates: [(TransactionID, String)] = []

    init(needing: [Transaction]) {
        self.needing = needing
    }

    func fetchPage(
        filter: TransactionFilter,
        cursor: TransactionCursor?,
        limit: Int
    ) async throws -> TransactionPage {
        TransactionPage(items: [], nextCursor: nil)
    }

    func fetchPosted(in range: CashFlowDateRange, now: Date) async throws -> [Transaction] { [] }
    func earliestPostedDate() async throws -> Date? { nil }
    func updateCategory(
        transactionID: TransactionID,
        categoryID: CategoryID,
        categoryLocked: Bool
    ) async throws {}
    func updateTags(transactionID: TransactionID, tagIDs: [TagID]) async throws {}
    func applyCategoryAssignments(_ assignments: [CategoryAssignment]) async throws {}
    func applyTagAssignments(_ assignments: [TagAssignment]) async throws {}
    func updateEnrichment(
        transactionID: TransactionID,
        title: String,
        location: String?,
        source: TitleSource,
        clearLocation: Bool
    ) async throws {
        enrichmentUpdates.append((transactionID, title))
        needing.removeAll { $0.id == transactionID }
    }
    func markEnrichmentSkipped(transactionID: TransactionID) async throws {
        needing.removeAll { $0.id == transactionID }
    }
    func fetchAllForCategorization() async throws -> [Transaction] { needing }
    func fetchNeedingCategorySuggestion(limit: Int) async throws -> [Transaction] { [] }
    func countNeedingCategorySuggestion() async throws -> Int { 0 }
    func applyTitleLocationAssignments(_ assignments: [TitleLocationAssignment]) async throws {}
    func countNeedingEnrichment() async throws -> Int { needing.count }
    func countDistinctDescriptionsNeedingEnrichment() async throws -> Int {
        Set(needing.map { TransactionDescriptionMatcher.normalize($0.description) }).count
    }
    func fetchNeedingEnrichment(limit: Int) async throws -> [Transaction] {
        Array(needing.prefix(limit))
    }
}

private struct EmptyAccountRepository: AccountRepository {
    func fetchAll() async throws -> [Account] { [] }
    func updateName(accountID: AccountID, name: String) async throws {}
    func keepLocally(accountID: AccountID) async throws {}
    func create(
        name: String,
        institutionName: String,
        currencyCode: String,
        createdByImportBatchID: ImportBatchID?
    ) async throws -> Account {
        Account(
            id: AccountID(UUID().uuidString),
            externalID: "csv:stub",
            name: name,
            institutionName: institutionName,
            currencyCode: currencyCode,
            balance: 0,
            balanceDate: .now
        )
    }
}

