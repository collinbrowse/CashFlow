import Foundation
import Network
import SwiftData
import os
import CashFlowKit

public actor SyncCoordinator: SyncServing {
    /// After history backfill, re-fetch this many days before the watermark so
    /// pending→posted updates with older `posted` dates still arrive.
    public static let incrementalLookbackDays = 30
    /// Cap SimpleFIN `/accounts` windows per sync to stay under daily quota.
    public static let maxBackfillWindowsPerSync = 8
    /// Stop walking older history when the bank returns this many empty windows in a row.
    public static let consecutiveEmptyWindowsToStop = 2

    private let modelContainer: ModelContainer
    private let bankLinking: CompositeBankLinkingService
    private let widgetTimelineReloader: any WidgetTimelineReloading
    private let enrichment: (any TransactionEnrichmentRunning)?
    nonisolated private let progressHub: SyncProgressHub
    private let logger = Logger(subsystem: "com.expensetracking", category: "sync")

    private var inFlight: Task<LinkedConnection, Error>?
    private var pendingEnrichmentPrompt: EnrichmentWorkEstimate?

    public init(
        modelContainer: ModelContainer,
        bankLinking: CompositeBankLinkingService,
        widgetTimelineReloader: any WidgetTimelineReloading = NoOpWidgetTimelineReloader(),
        enrichment: (any TransactionEnrichmentRunning)? = nil,
        progressHub: SyncProgressHub = SyncProgressHub()
    ) {
        self.modelContainer = modelContainer
        self.bankLinking = bankLinking
        self.widgetTimelineReloader = widgetTimelineReloader
        self.enrichment = enrichment
        self.progressHub = progressHub
    }

    /// Assembles UI status from credentials (Keychain / Demo session) + durable `ConnectionEntity`.
    public func connectionStatus() async -> LinkedConnection {
        let context = ModelContext(modelContainer)
        let entity = try? fetchConnection(context: context)

        // Durable Demo survives process death via ConnectionEntity.isDemo.
        if entity?.isDemo == true {
            let simpleLinked = await bankLinking.connectionStatus()
            // Prefer SimpleFIN credentials if both somehow exist.
            if simpleLinked.isLinked, simpleLinked.providerName == "SimpleFIN" {
                return LinkedConnection(
                    isLinked: true,
                    providerName: "SimpleFIN",
                    needsReauth: entity?.needsReauth ?? false,
                    lastSuccessfulSyncAt: entity?.lastSuccessfulSyncAt,
                    linkNamespace: entity?.linkNamespace ?? simpleLinked.linkNamespace
                )
            }
            await bankLinking.adoptDurableDemoLink()
            return LinkedConnection(
                isLinked: true,
                providerName: "Demo",
                needsReauth: entity?.needsReauth ?? false,
                lastSuccessfulSyncAt: entity?.lastSuccessfulSyncAt,
                linkNamespace: entity?.linkNamespace ?? DemoBankLinkingService.linkNamespace
            )
        }

        let credentials = await bankLinking.connectionStatus()
        guard credentials.isLinked else {
            return LinkedConnection(isLinked: false, providerName: "None")
        }

        return LinkedConnection(
            isLinked: true,
            providerName: credentials.providerName,
            needsReauth: entity?.needsReauth ?? credentials.needsReauth,
            lastSuccessfulSyncAt: entity?.lastSuccessfulSyncAt,
            linkNamespace: entity?.linkNamespace ?? credentials.linkNamespace
        )
    }

    /// Durable connection row for lifecycle / repair (secret-free).
    public func storedConnectionMetadata() async -> ConnectionEntitySnapshot? {
        let context = ModelContext(modelContainer)
        guard let entity = try? fetchConnection(context: context) else { return nil }
        return ConnectionEntitySnapshot(
            providerName: entity.providerName,
            isDemo: entity.isDemo,
            source: entity.source,
            linkNamespace: entity.linkNamespace
        )
    }

    nonisolated public func syncProgressUpdates() -> AsyncStream<SyncProgress?> {
        progressHub.subscribe()
    }

    public func consumePendingEnrichmentPrompt() async -> EnrichmentWorkEstimate? {
        defer { pendingEnrichmentPrompt = nil }
        return pendingEnrichmentPrompt
    }

    public func historyImportStatus() async -> HistoryImportStatus? {
        let context = ModelContext(modelContainer)
        guard let connection = try? fetchConnection(context: context) else { return nil }
        let untitled = (try? countNeedingEnrichment(context: context)) ?? 0
        let undefined = (try? countUndefined(context: context)) ?? 0
        let total = (try? countPosted(context: context)) ?? 0
        let distinct = (try? countDistinctNeedingEnrichment(context: context)) ?? 0
        let complete = connection.historyComplete || connection.historyBackfillComplete
        return HistoryImportStatusBuilding.build(
            lookback: connection.lookback,
            earliestFetchedDate: connection.earliestFetchedDate,
            historyComplete: complete,
            lastBackfillAdvanceAt: connection.lastBackfillAdvanceAt,
            untitledCount: untitled,
            undefinedCount: undefined,
            totalPostedCount: total,
            distinctMerchantLookupsRemaining: distinct
        )
    }

    public func setHistoryLookback(_ lookback: HistoryLookbackYears) async throws {
        let context = ModelContext(modelContainer)
        guard let connection = try fetchConnection(context: context) else { return }
        let previous = connection.lookback
        connection.lookbackYearsRaw = lookback.rawValue
        if lookback.startDate < previous.startDate {
            connection.historyComplete = false
            connection.historyBackfillComplete = false
        }
        try context.save()
    }

    public func syncNow() async throws -> LinkedConnection {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await performSync() }
        inFlight = task
        defer {
            inFlight = nil
            progressHub.emit(nil)
        }
        return try await task.value
    }

    /// Cancels the in-flight sync and waits until the slot is free (no overlapping syncNow).
    public func cancel() async {
        guard let task = inFlight else { return }
        task.cancel()
        _ = await task.result
    }

    private func emit(_ progress: SyncProgress) {
        progressHub.emit(progress)
    }

    private func performSync() async throws -> LinkedConnection {
        try Task.checkCancellation()
        emit(SyncProgress(phase: .preparing))

        _ = await connectionStatus()

        let context = ModelContext(modelContainer)
        let existing = try fetchConnection(context: context)
        let lookback = existing?.lookback ?? HistoryLookbackYears.default
        let targetStart = lookback.startDate
        let historyDone = existing.map { $0.historyComplete || $0.historyBackfillComplete } ?? false
        let providerNameHint = await bankLinking.activeProviderName()
        let isDemo = existing?.isDemo == true || providerNameHint == "Demo"

        let fetchStart: Date
        let fetchEnd: Date?
        let isBackfill: Bool
        let maxWindows: Int?
        let stopEmpty: Int?

        if historyDone, let watermark = existing?.lastSuccessfulSyncAt {
            fetchStart = Calendar.current.date(
                byAdding: .day,
                value: -Self.incrementalLookbackDays,
                to: watermark
            ) ?? watermark
            fetchEnd = nil
            isBackfill = false
            maxWindows = nil
            stopEmpty = nil
        } else if isDemo {
            // Demo seeds the full lookback in one shot.
            fetchStart = targetStart
            fetchEnd = nil
            isBackfill = true
            maxWindows = nil
            stopEmpty = nil
        } else {
            let chunkEnd = existing?.earliestFetchedDate ?? .now
            let stepDays = SimpleFINClient.maxAccountsRangeDays - SimpleFINClient.windowOverlapDays
            let maxSpanDays = Self.maxBackfillWindowsPerSync * stepDays
            let spanStart = Calendar.current.date(
                byAdding: .day,
                value: -maxSpanDays,
                to: chunkEnd
            ) ?? targetStart
            fetchStart = max(targetStart, spanStart)
            fetchEnd = chunkEnd
            isBackfill = true
            maxWindows = Self.maxBackfillWindowsPerSync
            stopEmpty = Self.consecutiveEmptyWindowsToStop
        }

        do {
            let phase: SyncProgress.Phase = isBackfill && !historyDone
                ? .backfillingHistory
                : .downloading
            let result = try await bankLinking.fetchAccountsWindowed(
                startDate: fetchStart,
                endDate: fetchEnd,
                maxWindows: maxWindows,
                stopAfterConsecutiveEmpty: stopEmpty,
                onWindowProgress: { [progressHub] completed, total in
                    progressHub.emit(
                        SyncProgress(
                            phase: phase,
                            completedUnits: completed,
                            totalUnits: total
                        )
                    )
                }
            )
            try Task.checkCancellation()
            emit(SyncProgress(phase: .saving))
            let syncedAt = Date.now
            let coversPresent = fetchEnd.map { $0.timeIntervalSinceNow > -300 } ?? true
            try SyncMergeEngine.merge(
                payload: result.payload,
                into: context,
                syncedAt: syncedAt,
                pruneStalePending: coversPresent,
                persist: false
            )

            let providerName = await bankLinking.activeProviderName()
            let connection = try upsertConnection(
                context: context,
                providerName: providerName,
                needsReauth: false,
                syncedAt: syncedAt,
                isDemo: providerName == "Demo",
                source: result.payload.source.source,
                linkNamespace: result.payload.source.linkNamespace,
                inventoryCompleteness: result.payload.inventoryCompleteness,
                historyBackfillComplete: existing?.historyBackfillComplete ?? false
            )
            connection.lastSyncIssuesData = result.payload.issues.isEmpty
                ? nil
                : try JSONEncoder().encode(result.payload.issues)

            if isBackfill {
                if result.payload.inventoryCompleteness == .complete {
                    let previousEarliest = connection.earliestFetchedDate
                    let newEarliest = previousEarliest.map { min($0, result.fetchedStart) } ?? result.fetchedStart
                    connection.earliestFetchedDate = newEarliest
                    connection.lastBackfillAdvanceAt = .now

                    let reachedTarget = newEarliest <= targetStart.addingTimeInterval(86_400)
                    let bankRanDry = result.consecutiveEmptyTrailing >= Self.consecutiveEmptyWindowsToStop
                    let demoDone = providerName == "Demo"
                    if demoDone || reachedTarget || bankRanDry {
                        connection.historyComplete = true
                        connection.historyBackfillComplete = true
                    } else {
                        connection.historyComplete = false
                        connection.historyBackfillComplete = false
                    }
                } else {
                    connection.historyComplete = false
                    connection.historyBackfillComplete = false
                }
            } else if connection.earliestFetchedDate == nil {
                connection.earliestFetchedDate = fetchStart
            }

            try context.save()
            widgetTimelineReloader.reloadCashFlowWidget()

            if let enrichment {
                let estimate = await enrichment.enrichAfterSync(skipIfLargeBacklog: true) {
                    [progressHub] completed, total in
                    progressHub.emit(
                        SyncProgress(
                            phase: .enriching,
                            completedUnits: completed,
                            totalUnits: total
                        )
                    )
                }
                if let estimate, estimate.shouldPrompt {
                    pendingEnrichmentPrompt = estimate
                }
            }

            return LinkedConnection(
                isLinked: true,
                providerName: providerName,
                needsReauth: false,
                lastSuccessfulSyncAt: connection.lastSuccessfulSyncAt,
                providerMessages: result.payload.providerMessages.map(Self.sanitize),
                linkNamespace: connection.linkNamespace
            )
        } catch let error as CashFlowError {
            if case .unauthorized = error {
                let providerName = await bankLinking.activeProviderName()
                _ = try? upsertConnection(
                    context: context,
                    providerName: providerName == "None" ? "SimpleFIN" : providerName,
                    needsReauth: true,
                    syncedAt: nil,
                    isDemo: false,
                    source: .simpleFIN,
                    linkNamespace: existing?.linkNamespace,
                    inventoryCompleteness: existing?.inventoryCompleteness ?? .incomplete,
                    historyBackfillComplete: existing?.historyBackfillComplete ?? false
                )
                try? context.save()
            }
            logger.error("Sync failed: \(String(describing: error), privacy: .public)")
            throw error
        } catch is CancellationError {
            throw CashFlowError.cancelled
        } catch {
            logger.error("Sync transport failure")
            throw CashFlowError.transport(message: error.localizedDescription)
        }
    }

    private func fetchConnection(context: ModelContext) throws -> ConnectionEntity? {
        let predicate = #Predicate<ConnectionEntity> { $0.id == "primary" }
        var descriptor = FetchDescriptor<ConnectionEntity>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @discardableResult
    private func upsertConnection(
        context: ModelContext,
        providerName: String,
        needsReauth: Bool,
        syncedAt: Date?,
        isDemo: Bool,
        source: ProviderSource,
        linkNamespace: String?,
        inventoryCompleteness: RemoteInventoryCompleteness,
        historyBackfillComplete: Bool
    ) throws -> ConnectionEntity {
        if let existing = try fetchConnection(context: context) {
            existing.providerName = providerName
            existing.needsReauth = needsReauth
            existing.isDemo = isDemo
            existing.source = source
            if let linkNamespace {
                existing.linkNamespace = linkNamespace
            }
            existing.inventoryCompleteness = inventoryCompleteness
            existing.historyBackfillComplete = historyBackfillComplete
            if let syncedAt {
                existing.lastSuccessfulSyncAt = syncedAt
            }
            return existing
        }
        let entity = ConnectionEntity(
            providerName: providerName,
            needsReauth: needsReauth,
            lastSuccessfulSyncAt: syncedAt,
            isDemo: isDemo,
            source: source,
            linkNamespace: linkNamespace,
            inventoryCompleteness: inventoryCompleteness,
            historyBackfillComplete: historyBackfillComplete
        )
        context.insert(entity)
        return entity
    }

    private func countNeedingEnrichment(context: ModelContext) throws -> Int {
        try EnrichmentBacklogQuery.count(context: context)
    }

    private func countUndefined(context: ModelContext) throws -> Int {
        let undefinedID = SystemCategory.undefined.id.rawValue
        let descriptor = FetchDescriptor<TransactionEntity>(
            predicate: #Predicate {
                !$0.isPending && $0.categoryID == undefinedID && !$0.categoryLocked
            }
        )
        return try context.fetchCount(descriptor)
    }

    private func countPosted(context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<TransactionEntity>(
            predicate: #Predicate { !$0.isPending }
        )
        return try context.fetchCount(descriptor)
    }

    private func countDistinctNeedingEnrichment(context: ModelContext) throws -> Int {
        try EnrichmentBacklogQuery.distinctDescriptionCount(context: context)
    }

    private static func sanitize(_ string: String) -> String {
        string.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
    }
}

/// Secret-free snapshot of durable connection lineage for lifecycle callers.
public struct ConnectionEntitySnapshot: Sendable, Equatable {
    public let providerName: String
    public let isDemo: Bool
    public let source: ProviderSource
    public let linkNamespace: String?

    public init(
        providerName: String,
        isDemo: Bool,
        source: ProviderSource,
        linkNamespace: String?
    ) {
        self.providerName = providerName
        self.isDemo = isDemo
        self.source = source
        self.linkNamespace = linkNamespace
    }
}

public final class ConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.expensetracking.connectivity")
    public private(set) var isOnline = true

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isOnline = path.status == .satisfied
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
