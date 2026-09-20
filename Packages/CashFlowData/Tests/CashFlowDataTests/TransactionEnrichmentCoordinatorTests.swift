import Testing
import Foundation
@testable import CashFlowData
import CashFlowKit

@Suite("TransactionEnrichmentCoordinator")
struct TransactionEnrichmentCoordinatorTests {
    @Test("Skips LLM titles when model unavailable; still keyword-categorizes Undefined")
    func skipsWhenUnavailable() async {
        let txs = MockEnrichmentTransactionRepository(
            needing: [
                Transaction(
                    id: TransactionID("1"),
                    accountID: AccountID("a"),
                    externalID: "e",
                    amount: -9,
                    postedDate: .now,
                    description: "STARBUCKS BANGKOK TH",
                    categoryID: SystemCategory.undefined.id
                ),
            ],
            undefined: [
                Transaction(
                    id: TransactionID("1"),
                    accountID: AccountID("a"),
                    externalID: "e",
                    amount: -9,
                    postedDate: .now,
                    description: "STARBUCKS BANGKOK TH",
                    categoryID: SystemCategory.undefined.id
                ),
            ]
        )
        let coordinator = TransactionEnrichmentCoordinator(
            availability: FixedAvailability(.deviceNotEligible),
            descriptionEnricher: StubDescriptionEnricher(
                result: ParsedTransactionDescription(
                    title: "Starbucks",
                    location: "Bangkok",
                    raw: "STARBUCKS BANGKOK TH"
                )
            ),
            categoryEnricher: StubCategoryEnricher(id: SystemCategory.dining.id),
            transactionRepository: txs,
            accountRepository: EmptyAccountRepository(),
            ruleRepository: EmptyRuleRepository(),
            workCoordinator: FoundationModelsWorkCoordinator()
        )
        await coordinator.enrichAfterSync()
        #expect(txs.enrichmentUpdates.isEmpty)
        #expect(txs.categoryAssignments.count == 1)
        #expect(txs.categoryAssignments[0].categorySource == .keyword)
    }

    @Test("Writes description enrichment and Undefined→LLM category")
    func enrichesDescriptionAndCategory() async {
        let txs = MockEnrichmentTransactionRepository(
            needing: [
                Transaction(
                    id: TransactionID("1"),
                    accountID: AccountID("a"),
                    externalID: "e",
                    amount: -9,
                    postedDate: .now,
                    description: "STARBUCKS BANGKOK TH",
                    categoryID: SystemCategory.undefined.id
                ),
            ],
            undefined: [
                Transaction(
                    id: TransactionID("1"),
                    accountID: AccountID("a"),
                    externalID: "e",
                    amount: -9,
                    postedDate: .now,
                    description: "STARBUCKS BANGKOK TH",
                    categoryID: SystemCategory.undefined.id
                ),
            ]
        )
        let coordinator = TransactionEnrichmentCoordinator(
            availability: FixedAvailability(.available),
            descriptionEnricher: StubDescriptionEnricher(
                result: ParsedTransactionDescription(
                    title: "Starbucks",
                    location: "Bangkok",
                    raw: "STARBUCKS BANGKOK TH"
                )
            ),
            categoryEnricher: StubCategoryEnricher(id: SystemCategory.dining.id),
            transactionRepository: txs,
            accountRepository: EmptyAccountRepository(),
            ruleRepository: EmptyRuleRepository(),
            workCoordinator: FoundationModelsWorkCoordinator()
        )
        await coordinator.enrichAfterSync()
        #expect(txs.enrichmentUpdates.count == 1)
        #expect(txs.enrichmentUpdates[0].title == "Starbucks")
        #expect(txs.enrichmentUpdates[0].location == "Bangkok")
        #expect(txs.categoryAssignments.count == 1)
        #expect(txs.categoryAssignments[0].categoryID == SystemCategory.dining.id)
        #expect(txs.categoryAssignments[0].userEditedCategory == false)
        #expect(txs.categoryAssignments[0].categorySource == .llm)
    }
}

private struct FixedAvailability: OnDeviceModelAvailabilityChecking {
    let value: OnDeviceModelAvailability
    init(_ value: OnDeviceModelAvailability) { self.value = value }
    func availability() async -> OnDeviceModelAvailability { value }
}

private struct StubDescriptionEnricher: TransactionDescriptionEnriching {
    let result: ParsedTransactionDescription
    func enrich(rawDescription: String) async -> ParsedTransactionDescription { result }
}

private struct StubCategoryEnricher: TransactionCategoryEnriching {
    let id: CategoryID?
    func suggestCategory(_ request: CategorySuggestionRequest) async -> CategoryID? { id }
}

private struct EmptyRuleRepository: CategorizationRuleRepository {
    func fetchAll() async throws -> [CategorizationRule] { [] }
    func upsert(_ rule: CategorizationRule) async throws {}
    func delete(id: CategorizationRuleID) async throws {}
    func reorder(ids: [CategorizationRuleID]) async throws {}
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

private final class MockEnrichmentTransactionRepository: TransactionRepository, @unchecked Sendable {
    var needing: [Transaction]
    var undefined: [Transaction]
    var enrichmentUpdates: [(id: TransactionID, title: String, location: String?)] = []
    var categoryAssignments: [CategoryAssignment] = []

    init(needing: [Transaction], undefined: [Transaction]? = nil, all: [Transaction]? = nil) {
        self.needing = needing
        self.undefined = undefined ?? needing.filter { $0.categoryID == SystemCategory.undefined.id }
        _ = all
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
    func applyCategoryAssignments(_ assignments: [CategoryAssignment]) async throws {
        categoryAssignments.append(contentsOf: assignments)
        let assigned = Set(assignments.map(\.transactionID))
        undefined.removeAll { assigned.contains($0.id) }
    }
    func applyTagAssignments(_ assignments: [TagAssignment]) async throws {}
    func updateEnrichment(
        transactionID: TransactionID,
        title: String,
        location: String?,
        source: TitleSource,
        clearLocation: Bool
    ) async throws {
        enrichmentUpdates.append((transactionID, title, location))
        needing.removeAll { $0.id == transactionID }
    }
    func markEnrichmentSkipped(transactionID: TransactionID) async throws {
        needing.removeAll { $0.id == transactionID }
    }
    func fetchAllForCategorization() async throws -> [Transaction] { undefined }
    func fetchNeedingCategorySuggestion(limit: Int) async throws -> [Transaction] {
        Array(undefined.prefix(limit))
    }
    func countNeedingCategorySuggestion() async throws -> Int { undefined.count }

    func applyTitleLocationAssignments(_ assignments: [TitleLocationAssignment]) async throws {}
    func countNeedingEnrichment() async throws -> Int { needing.count }
    func countDistinctDescriptionsNeedingEnrichment() async throws -> Int { needing.count }

    func fetchNeedingEnrichment(limit: Int) async throws -> [Transaction] {
        Array(needing.prefix(limit))
    }
}
