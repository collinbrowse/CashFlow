import Foundation
import SwiftData
import Testing
import CashFlowKit
@testable import CashFlowData

@Suite("Sync progress")
struct SyncProgressEmissionTests {
    @Test("Demo sync emits preparing, downloading units, saving, then clears")
    func demoSyncEmitsPhases() async throws {
        let linking = CompositeBankLinkingService(
            demo: DemoBankLinkingService(seedSize: .standard),
            simpleFIN: SimpleFINBankLinkingService(
                accessURLStore: InMemoryAccessURLStore()
            ),
            initialMode: .none
        )
        try await linking.link(withSetupToken: "demo")
        let container = try ModelContainerFactory.make(inMemory: true)
        let hub = SyncProgressHub()
        let sync = SyncCoordinator(
            modelContainer: container,
            bankLinking: linking,
            enrichment: NoOpTransactionEnrichmentRunner(),
            progressHub: hub
        )

        let collector = ProgressCollector()
        let stream = hub.subscribe()
        let collectTask = Task {
            for await value in stream {
                await collector.append(value)
            }
        }

        _ = try await sync.syncNow()
        // Allow the terminal nil from defer to land.
        try await Task.sleep(for: .milliseconds(50))
        collectTask.cancel()

        let values = await collector.values
        #expect(values.contains { $0?.phase == .preparing })
        #expect(values.contains {
            ($0?.phase == .downloading || $0?.phase == .backfillingHistory)
                && $0?.completedUnits == 0 && $0?.totalUnits == 1
        })
        #expect(values.contains {
            ($0?.phase == .downloading || $0?.phase == .backfillingHistory)
                && $0?.completedUnits == 1 && $0?.totalUnits == 1
        })
        #expect(values.contains { $0?.phase == .saving })
        #expect(values.contains { $0 == nil })
    }

    @Test("SimpleFIN window progress reports completed/total for each chunk")
    func windowProgressCallbacks() async throws {
        let recorder = LockedProgressUnitRecorder()
        let http = ProgressMockHTTPClient { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let end = Int(items.first(where: { $0.name == "end-date" })?.value ?? "0")!
            let start = Int(items.first(where: { $0.name == "start-date" })?.value ?? "0")!
            let json = """
            {"errors":[],"accounts":[{"id":"a1","name":"Checking","currency":"USD","balance":"10.00","balance-date":\(end),"org":{"name":"Bank"},"transactions":[{"id":"t-\(start)","posted":\(start),"amount":"-1.00","description":"Coffee"}]}]}
            """
            return (
                Data(json.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let client = SimpleFINClient(http: http)
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let start = Calendar.current.date(byAdding: .day, value: -180, to: end)!
        _ = try await client.fetchAccounts(
            accessURL: "https://user:pass@beta-bridge.simplefin.org/simplefin",
            link: RemoteSyncTestFixtures.simpleFINLink,
            startDate: start,
            endDate: end,
            onWindowProgress: { completed, total in
                recorder.append(completed: completed, total: total)
            }
        )

        let events = recorder.events
        #expect(events.count >= 2)
        #expect(events.first?.completed == 0)
        #expect(events.last?.completed == events.last?.total)
        #expect(Set(events.map(\.total)).count == 1)
        #expect(events.last!.total >= 2)
    }
}

@Suite("Enrichment progress")
struct EnrichmentProgressTests {
    @Test("Reports completed/total across description and category work")
    func reportsUnits() async throws {
        let txs = MockEnrichmentProgressRepository(
            needing: [
                Transaction(
                    id: TransactionID("1"),
                    accountID: AccountID("a"),
                    externalID: "e",
                    amount: -9,
                    postedDate: .now,
                    description: "STARBUCKS",
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
                    description: "STARBUCKS",
                    categoryID: SystemCategory.undefined.id
                ),
            ]
        )
        let coordinator = TransactionEnrichmentCoordinator(
            availability: FixedProgressAvailability(.available),
            descriptionEnricher: StubProgressDescriptionEnricher(
                result: ParsedTransactionDescription(
                    title: "Starbucks",
                    location: nil,
                    raw: "STARBUCKS"
                )
            ),
            categoryEnricher: StubProgressCategoryEnricher(id: SystemCategory.dining.id),
            transactionRepository: txs,
            accountRepository: EmptyAccountRepository(),
            ruleRepository: EmptyProgressRuleRepository(),
            workCoordinator: FoundationModelsWorkCoordinator()
        )

        let recorder = LockedProgressUnitRecorder()
        await coordinator.enrichAfterSync { completed, total in
            recorder.append(completed: completed, total: total)
        }
        let events = recorder.events
        #expect(events.contains { $0.completed == 0 && $0.total >= 1 })
        #expect(events.contains { $0.completed >= 1 && $0.total >= $0.completed })
        #expect(events.contains { $0.completed == 2 && $0.total == 2 })
    }
}

// MARK: - Helpers

private actor ProgressCollector {
    private(set) var values: [SyncProgress?] = []
    func append(_ value: SyncProgress?) { values.append(value) }
}

private final class LockedProgressUnitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(completed: Int, total: Int)] = []

    var events: [(completed: Int, total: Int)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(completed: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        storage.append((completed, total))
    }
}

private actor ProgressMockHTTPClient: HTTPClient {
    private let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}

private struct FixedProgressAvailability: OnDeviceModelAvailabilityChecking {
    let value: OnDeviceModelAvailability
    init(_ value: OnDeviceModelAvailability) { self.value = value }
    func availability() async -> OnDeviceModelAvailability { value }
}

private struct StubProgressDescriptionEnricher: TransactionDescriptionEnriching {
    let result: ParsedTransactionDescription
    func enrich(rawDescription: String) async -> ParsedTransactionDescription { result }
}

private struct StubProgressCategoryEnricher: TransactionCategoryEnriching {
    let id: CategoryID
    func suggestCategory(_ request: CategorySuggestionRequest) async -> CategoryID? { id }
}

private struct EmptyProgressRuleRepository: CategorizationRuleRepository {
    func fetchAll() async throws -> [CategorizationRule] { [] }
    func upsert(_ rule: CategorizationRule) async throws {}
    func delete(id: CategorizationRuleID) async throws {}
    func reorder(ids: [CategorizationRuleID]) async throws {}
}

private final class MockEnrichmentProgressRepository: TransactionRepository, @unchecked Sendable {
    var needing: [Transaction]
    var undefined: [Transaction]
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
        needing = needing.filter { $0.id != transactionID }
    }
    func markEnrichmentSkipped(transactionID: TransactionID) async throws {
        needing = needing.filter { $0.id != transactionID }
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

