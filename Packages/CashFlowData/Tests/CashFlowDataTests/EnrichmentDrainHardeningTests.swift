import Foundation
import os
import SwiftData
import Testing
import CashFlowKit
@testable import CashFlowData

@Suite("Enrichment drain hardening")
struct EnrichmentDrainHardeningTests {
    @Test("A row whose skip write fails is abandoned instead of refetched forever")
    func failedSkipDoesNotLoop() async {
        let enricher = CountingEmptyEnricher()
        let txs = StuckSkipRepository(
            needing: [Self.transaction(id: "1", description: "SQ *UNPARSEABLE 4471")]
        )
        let coordinator = TransactionEnrichmentCoordinator(
            availability: DrainAvailability(.available),
            descriptionEnricher: enricher,
            categoryEnricher: NoCategoryEnricher(),
            transactionRepository: txs,
            accountRepository: EmptyAccountRepository(),
            ruleRepository: NoRuleRepository(),
            workCoordinator: FoundationModelsWorkCoordinator()
        )

        let outcome = await coordinator.drainAllNeedingEnrichment(
            shouldContinue: { true },
            onProgress: nil
        )

        #expect(outcome == .completed)
        // The row stays in the backlog because the write failed, but the drain must not
        // hand it to the model again on the next batch.
        #expect(await enricher.callCount == 1)
        #expect(await txs.skipAttempts == 1)
    }

    @Test("A concurrent post-sync pass never overlaps a full drain")
    func drainsDoNotOverlap() async {
        let enricher = ConcurrencyTrackingEnricher()
        let txs = StuckSkipRepository(
            needing: (1...6).map { Self.transaction(id: "\($0)", description: "MERCHANT \($0)") },
            failSkips: false
        )
        let coordinator = TransactionEnrichmentCoordinator(
            // Suspending inside the availability check opens the reentrancy window that
            // let two drains claim the runner at once.
            availability: SlowAvailability(),
            descriptionEnricher: enricher,
            categoryEnricher: NoCategoryEnricher(),
            transactionRepository: txs,
            accountRepository: EmptyAccountRepository(),
            ruleRepository: NoRuleRepository(),
            workCoordinator: FoundationModelsWorkCoordinator()
        )

        // Start the post-sync pass first and let it suspend inside the availability check,
        // then start the Settings drain so it arrives while the first has not yet claimed
        // the runner. `fullDrainRunning` does not cover this order.
        let incremental = Task {
            await coordinator.enrichAfterSync(skipIfLargeBacklog: false, onProgress: nil)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let full = Task {
            await coordinator.drainAllNeedingEnrichment(
                shouldContinue: { true },
                onProgress: nil
            )
        }
        _ = await incremental.value
        let fullOutcome = await full.value

        #expect(await enricher.maxConcurrent == 1)
        #expect(fullOutcome == .completed)
        #expect((try? await txs.countNeedingEnrichment()) == 0)
    }

    @Test("Stopping a full drain then resuming processes remaining rows")
    func stopThenResumeDrainsRemaining() async {
        let enricher = GatedEnricher()
        let txs = StuckSkipRepository(
            needing: (1...4).map { Self.transaction(id: "\($0)", description: "MERCHANT \($0)") },
            failSkips: false
        )
        let coordinator = TransactionEnrichmentCoordinator(
            availability: DrainAvailability(.available),
            descriptionEnricher: enricher,
            categoryEnricher: NoCategoryEnricher(),
            transactionRepository: txs,
            accountRepository: EmptyAccountRepository(),
            ruleRepository: NoRuleRepository(),
            workCoordinator: FoundationModelsWorkCoordinator()
        )
        let continueFlag = OSAllocatedUnfairLock(initialState: true)

        let first = Task {
            await coordinator.drainAllNeedingEnrichment(
                shouldContinue: { continueFlag.withLock { $0 } },
                onProgress: nil
            )
        }
        await enricher.waitForFirstCall()
        continueFlag.withLock { $0 = false }
        await enricher.allowCurrentCall()
        let firstOutcome = await first.value
        #expect(firstOutcome == .interrupted)
        let processedBeforeResume = await enricher.callCount
        #expect(processedBeforeResume >= 1)
        #expect((try? await txs.countNeedingEnrichment()) ?? 0 > 0)

        continueFlag.withLock { $0 = true }
        await enricher.stopBlocking()
        let second = await coordinator.drainAllNeedingEnrichment(
            shouldContinue: { continueFlag.withLock { $0 } },
            onProgress: nil
        )
        #expect(second == .completed)
        #expect((try? await txs.countNeedingEnrichment()) == 0)
    }

    @Test("A second full drain waits for the first instead of returning interrupted")
    func overlappingFullDrainsBothCompleteWork() async {
        let enricher = ConcurrencyTrackingEnricher()
        let txs = StuckSkipRepository(
            needing: (1...6).map { Self.transaction(id: "\($0)", description: "MERCHANT \($0)") },
            failSkips: false
        )
        let coordinator = TransactionEnrichmentCoordinator(
            availability: DrainAvailability(.available),
            descriptionEnricher: enricher,
            categoryEnricher: NoCategoryEnricher(),
            transactionRepository: txs,
            accountRepository: EmptyAccountRepository(),
            ruleRepository: NoRuleRepository(),
            workCoordinator: FoundationModelsWorkCoordinator()
        )

        let first = Task {
            await coordinator.drainAllNeedingEnrichment(
                shouldContinue: { true },
                onProgress: nil
            )
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let second = await coordinator.drainAllNeedingEnrichment(
            shouldContinue: { true },
            onProgress: nil
        )
        let firstOutcome = await first.value
        #expect(firstOutcome == .completed)
        #expect(second == .completed)
        #expect(await enricher.maxConcurrent == 1)
        #expect((try? await txs.countNeedingEnrichment()) == 0)
    }

    @Test("Category pass stops when shouldContinue becomes false")
    func categoryPassHonorsStop() async {
        let continueFlag = OSAllocatedUnfairLock(initialState: true)
        let enricher = GatedCategoryEnricher()
        let txs = StuckSkipRepository(
            needing: [],
            failSkips: false,
            undefined: (1...6).map {
                Self.transaction(
                    id: "c\($0)",
                    description: "STORE \($0)",
                    categoryID: SystemCategory.undefined.id
                )
            }
        )
        let coordinator = TransactionEnrichmentCoordinator(
            availability: DrainAvailability(.available),
            descriptionEnricher: FixedEnricher(title: "Merchant"),
            categoryEnricher: enricher,
            transactionRepository: txs,
            accountRepository: EmptyAccountRepository(),
            ruleRepository: NoRuleRepository(),
            workCoordinator: FoundationModelsWorkCoordinator()
        )

        let drain = Task {
            await coordinator.drainAllNeedingEnrichment(
                shouldContinue: { continueFlag.withLock { $0 } },
                onProgress: nil
            )
        }
        await enricher.waitForFirstCall()
        continueFlag.withLock { $0 = false }
        await enricher.allowCurrentCall()
        let outcome = await drain.value
        #expect(outcome == .interrupted)
        #expect((try? await txs.countNeedingCategorySuggestion()) ?? 0 > 0)
    }

    @Test("Backlog is counted per batch, not per row")
    func countsBacklogOncePerBatch() async {
        // One batch worth of rows, so a per-batch count is a single query.
        let rowCount = TransactionEnrichmentCoordinator.descriptionBatchLimit
        let txs = StuckSkipRepository(
            needing: (1...rowCount).map {
                Self.transaction(id: "\($0)", description: "MERCHANT \($0)")
            },
            failSkips: false
        )
        let coordinator = TransactionEnrichmentCoordinator(
            availability: DrainAvailability(.available),
            descriptionEnricher: FixedEnricher(title: "Merchant"),
            categoryEnricher: NoCategoryEnricher(),
            transactionRepository: txs,
            accountRepository: EmptyAccountRepository(),
            ruleRepository: NoRuleRepository(),
            workCoordinator: FoundationModelsWorkCoordinator()
        )

        let totals = TotalsRecorder()
        _ = await coordinator.drainAllNeedingEnrichment(
            shouldContinue: { true },
            onProgress: { _, total in totals.record(total) },
            onPhase: nil
        )

        // Counting inside the row loop made this a full-table scan per transaction.
        #expect(await txs.countCalls <= 2)
        #expect(totals.values.allSatisfy { $0 == rowCount })
    }

    private static func transaction(
        id: String,
        description: String,
        categoryID: CategoryID = SystemCategory.other.id
    ) -> Transaction {
        Transaction(
            id: TransactionID(id),
            accountID: AccountID("a"),
            externalID: "e\(id)",
            amount: -9,
            postedDate: .now,
            description: description,
            categoryID: categoryID
        )
    }
}

@Suite("Enrichment skip reviver")
struct EnrichmentSkipReviverTests {
    @Test("Skipped rows return to the backlog when the generation bumps")
    func revivesSkippedRows() async throws {
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
                transactionDescription: "SQ *4471",
                categoryID: SystemCategory.other.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: false,
                isPending: false,
                syncKey: "ext|u1",
                account: account,
                titleSourceRaw: TitleSource.skipped.rawValue
            )
        )
        try context.save()

        let repository = SwiftDataTransactionRepository(modelContainer: container)
        #expect(try await repository.countNeedingEnrichment() == 0)

        let revived = try EnrichmentSkipReviver.revive(modelContainer: container)

        #expect(revived == 1)
        #expect(try await repository.countNeedingEnrichment() == 1)
    }
}

@Suite("Foundation Models pacing")
struct FoundationModelsPacingTests {
    @Test("Waiting out a rate limit returns promptly once cancelled")
    func cancelledWaitDoesNotSpin() async {
        let coordinator = FoundationModelsWorkCoordinator()
        await coordinator.noteRateLimited()
        #expect(await coordinator.isRateLimitPaused)

        let started = Date()
        let task = Task { await coordinator.waitOutRateLimitPauseIfNeeded() }
        task.cancel()
        _ = await task.value

        // The pause itself is 45s; a cancelled wait must not burn the clock down.
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await coordinator.isRateLimitPaused)
    }

    @Test("Waiting out a rate limit returns promptly once shouldContinue is false")
    func rateLimitWaitHonorsStop() async {
        let coordinator = FoundationModelsWorkCoordinator()
        await coordinator.noteRateLimited()
        #expect(await coordinator.isRateLimitPaused)

        let continueFlag = OSAllocatedUnfairLock(initialState: true)
        let started = Date()
        let task = Task {
            await coordinator.waitOutRateLimitPauseIfNeeded(
                shouldContinue: { continueFlag.withLock { $0 } }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        continueFlag.withLock { $0 = false }
        _ = await task.value

        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await coordinator.isRateLimitPaused)
    }

    @Test("Cancelling a queued caller releases it instead of hanging")
    func cancelledWaiterIsReleased() async throws {
        let coordinator = FoundationModelsWorkCoordinator()
        let occupied = AsyncSemaphore()
        let release = AsyncSemaphore()

        // Occupy the mutex so the next caller has to queue.
        let holder = Task {
            try await coordinator.runExclusive {
                occupied.signal()
                await release.wait()
                return 0
            }
        }
        await occupied.wait()

        let queued = Task {
            try await coordinator.runExclusive { 1 }
        }
        // Give the queued task time to park itself in the waiter list.
        try await Task.sleep(nanoseconds: 50_000_000)
        queued.cancel()

        // Without cancellation handling this continuation is never resumed and the
        // `await` below hangs forever.
        await #expect(throws: CancellationError.self) {
            try await queued.value
        }

        release.signal()
        _ = try await holder.value
    }
}

/// One-shot signal for ordering steps in the mutex test.
private final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isSignalled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private struct DrainAvailability: OnDeviceModelAvailabilityChecking {
    let value: OnDeviceModelAvailability
    init(_ value: OnDeviceModelAvailability) { self.value = value }
    func availability() async -> OnDeviceModelAvailability { value }
}

private struct SlowAvailability: OnDeviceModelAvailabilityChecking {
    func availability() async -> OnDeviceModelAvailability {
        try? await Task.sleep(nanoseconds: 20_000_000)
        return .available
    }
}

private struct FixedEnricher: TransactionDescriptionEnriching {
    let title: String
    func enrich(rawDescription: String) async -> ParsedTransactionDescription {
        ParsedTransactionDescription(title: title, location: nil, raw: rawDescription)
    }
}

/// Always refuses to parse, and counts how many times the drain asks.
private actor CountingEmptyEnricher: TransactionDescriptionEnriching {
    private(set) var callCount = 0
    func enrich(rawDescription: String) async -> ParsedTransactionDescription {
        callCount += 1
        return ParsedTransactionDescription(title: "", location: nil, raw: rawDescription)
    }
}

private actor GatedEnricher: TransactionDescriptionEnriching {
    private let started = AsyncSemaphore()
    private let proceed = AsyncSemaphore()
    private var blockFurther = true
    private(set) var callCount = 0

    func waitForFirstCall() async {
        await started.wait()
    }

    func allowCurrentCall() {
        proceed.signal()
    }

    func stopBlocking() {
        blockFurther = false
        proceed.signal()
    }

    func enrich(rawDescription: String) async -> ParsedTransactionDescription {
        callCount += 1
        if callCount == 1 {
            started.signal()
            await proceed.wait()
        } else if blockFurther {
            await proceed.wait()
        }
        return ParsedTransactionDescription(title: "Merchant", location: nil, raw: rawDescription)
    }
}

private actor GatedCategoryEnricher: TransactionCategoryEnriching {
    private let started = AsyncSemaphore()
    private let proceed = AsyncSemaphore()
    private(set) var callCount = 0

    func waitForFirstCall() async {
        await started.wait()
    }

    func allowCurrentCall() {
        proceed.signal()
    }

    func suggestCategory(_ request: CategorySuggestionRequest) async -> CategoryID? {
        _ = request
        callCount += 1
        if callCount == 1 {
            started.signal()
            await proceed.wait()
        }
        return SystemCategory.dining.id
    }
}

private actor ConcurrencyTrackingEnricher: TransactionDescriptionEnriching {
    private var active = 0
    private(set) var maxConcurrent = 0

    func enrich(rawDescription: String) async -> ParsedTransactionDescription {
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        defer { active -= 1 }
        try? await Task.sleep(nanoseconds: 5_000_000)
        return ParsedTransactionDescription(title: "Merchant", location: nil, raw: rawDescription)
    }
}

private final class TotalsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ total: Int) {
        lock.lock()
        storage.append(total)
        lock.unlock()
    }
}

private struct NoCategoryEnricher: TransactionCategoryEnriching {
    func suggestCategory(_ request: CategorySuggestionRequest) async -> CategoryID? { nil }
}

private struct NoRuleRepository: CategorizationRuleRepository {
    func fetchAll() async throws -> [CategorizationRule] { [] }
    func upsert(_ rule: CategorizationRule) async throws {}
    func delete(id: CategorizationRuleID) async throws {}
    func reorder(ids: [CategorizationRuleID]) async throws {}
}

/// Repository whose `markEnrichmentSkipped` fails, leaving the row in the backlog.
private actor StuckSkipRepository: TransactionRepository {
    private var needing: [Transaction]
    private var undefined: [Transaction]
    private let failSkips: Bool
    private(set) var skipAttempts = 0
    private(set) var countCalls = 0

    init(needing: [Transaction], failSkips: Bool = true, undefined: [Transaction] = []) {
        self.needing = needing
        self.failSkips = failSkips
        self.undefined = undefined
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
    func applyTitleLocationAssignments(_ assignments: [TitleLocationAssignment]) async throws {}

    func updateEnrichment(
        transactionID: TransactionID,
        title: String,
        location: String?,
        source: TitleSource,
        clearLocation: Bool
    ) async throws {
        needing.removeAll { $0.id == transactionID }
    }

    func markEnrichmentSkipped(transactionID: TransactionID) async throws {
        skipAttempts += 1
        guard !failSkips else {
            throw CashFlowError.persistence(message: "Transaction not found")
        }
        needing.removeAll { $0.id == transactionID }
    }

    func fetchAllForCategorization() async throws -> [Transaction] { [] }
    func fetchNeedingCategorySuggestion(limit: Int) async throws -> [Transaction] {
        Array(undefined.prefix(limit))
    }
    func countNeedingCategorySuggestion() async throws -> Int { undefined.count }

    func countNeedingEnrichment() async throws -> Int {
        countCalls += 1
        return needing.count
    }

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

