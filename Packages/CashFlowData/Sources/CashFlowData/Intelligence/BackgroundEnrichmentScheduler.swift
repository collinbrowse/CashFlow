import Foundation
import CashFlowKit
import os

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

/// Runs user-initiated full enrichment drains in-process, with overnight BG continuation.
public final class BackgroundEnrichmentScheduler: BackgroundEnrichmentScheduling, @unchecked Sendable {
    public static let unattendedProcessingIdentifier =
        "com.collinbrowse.expensetracking.app.enrichment.unattended"

    /// Retry window after Apple rate-limits a drain (sooner than the overnight schedule).
    public static let soonContinuationSeconds: TimeInterval = 15 * 60

    private let enrichment: any TransactionEnrichmentRunning
    private let sync: SyncCoordinator
    private let progressHub: EnrichmentProgressHub
    private let workCoordinator: FoundationModelsWorkCoordinator
    private let logger = Logger(subsystem: "com.expensetracking", category: "bg-enrichment")
    private let userDrain = UserDrainSession()

    public init(
        enrichment: any TransactionEnrichmentRunning,
        sync: SyncCoordinator,
        progressHub: EnrichmentProgressHub = EnrichmentProgressHub(),
        workCoordinator: FoundationModelsWorkCoordinator
    ) {
        self.enrichment = enrichment
        self.sync = sync
        self.progressHub = progressHub
        self.workCoordinator = workCoordinator
    }

    public func registerHandlers() {
        #if canImport(BackgroundTasks) && os(iOS)
        let enrichment = self.enrichment
        let sync = self.sync
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.unattendedProcessingIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.runUnattended(task: task, enrichment: enrichment, sync: sync)
        }
        #endif
    }

    public func enrichmentProgressUpdates() -> AsyncStream<EnrichmentProgress?> {
        progressHub.subscribe()
    }

    public func setAppForeground(_ isForeground: Bool) async {
        await workCoordinator.setAppForeground(isForeground)
    }

    public func runFullEnrichmentDrain(
        expectedTotal: Int,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async -> EnrichmentDrainOutcome {
        let outcome = await userDrain.run { [progressHub, enrichment] shouldContinue in
            let initialTotal = max(expectedTotal, 0)
            let snapshot = DrainProgressSnapshot(completed: 0, total: initialTotal)

            progressHub.emit(
                EnrichmentProgress(
                    isRunning: true,
                    phase: .running,
                    completed: 0,
                    total: initialTotal
                )
            )

            // Cooperative `shouldContinue` is owned here so Settings Stop can cancel.
            // Foreground drains must not share a flag with `BGContinuedProcessingTask`
            // (that caused vibrate → instant pause).
            let outcome = await enrichment.drainAllNeedingEnrichment(
                shouldContinue: shouldContinue,
                onProgress: { [progressHub] completed, total in
                    let resolvedTotal = max(total, initialTotal, completed)
                    let phase = snapshot.updateCounts(completed: completed, total: resolvedTotal)
                    progressHub.emit(
                        EnrichmentProgress(
                            isRunning: true,
                            phase: phase.phase,
                            completed: completed,
                            total: resolvedTotal,
                            detail: phase.detail
                        )
                    )
                    onProgress?(completed, resolvedTotal)
                },
                onPhase: { [progressHub] phase, detail in
                    let counts = snapshot.updatePhase(phase, detail: detail)
                    progressHub.emit(
                        EnrichmentProgress(
                            isRunning: true,
                            phase: phase,
                            completed: counts.completed,
                            total: max(counts.total, initialTotal, 1),
                            detail: detail
                        )
                    )
                }
            )

            progressHub.emit(snapshot.terminalProgress(outcome: outcome, initialTotal: initialTotal))
            progressHub.emit(nil)
            return outcome
        }
        if outcome.wasRateLimited {
            scheduleUnattendedContinuationSoon()
        } else {
            scheduleUnattendedContinuation()
        }
        return outcome
    }

    public func stopFullEnrichmentDrain() async {
        await userDrain.stop()
    }

    public func scheduleUnattendedContinuation() {
        scheduleUnattended(earliestBegin: Date(timeIntervalSinceNow: 24 * 60 * 60))
    }

    public func scheduleUnattendedContinuationSoon() {
        scheduleUnattended(earliestBegin: Date(timeIntervalSinceNow: Self.soonContinuationSeconds))
    }

    private func scheduleUnattended(earliestBegin: Date) {
        #if canImport(BackgroundTasks) && os(iOS)
        let request = BGProcessingTaskRequest(identifier: Self.unattendedProcessingIdentifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = earliestBegin
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Failed to schedule unattended enrichment: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    public var isFullDrainRunning: Bool {
        get async {
            if await userDrain.hasInFlight { return true }
            return await enrichment.isFullDrainRunning
        }
    }

    public func hasRemainingCleanupWork() async -> Bool {
        await sync.historyImportStatus()?.needsCleanup == true
    }

    #if canImport(BackgroundTasks) && os(iOS)
    private func runUnattended(
        task: BGTask,
        enrichment: any TransactionEnrichmentRunning,
        sync: SyncCoordinator
    ) {
        let continueFlag = OSAllocatedUnfairLock(initialState: true)
        task.expirationHandler = {
            continueFlag.withLock { $0 = false }
        }
        let shouldContinue: @Sendable () -> Bool = { continueFlag.withLock { $0 } }

        let completion = TaskCompletionBox(task: task)
        let scheduler = self
        let workCoordinator = self.workCoordinator

        Task {
            // Held for the whole task so foregrounding mid-run cannot relax our pacing.
            await workCoordinator.beginBackgroundWork()
            defer { Task { await workCoordinator.endBackgroundWork() } }

            if let status = await sync.historyImportStatus(), !status.historyComplete {
                _ = try? await sync.syncNow()
            }
            // Drain the whole backlog under the task's expiration flag. The incremental
            // path caps at `incrementalRowBudget` rows, which would need weeks of nightly
            // runs to clear a multi-year import.
            let outcome = await enrichment.drainAllNeedingEnrichment(
                shouldContinue: shouldContinue,
                onProgress: nil
            )
            let stillPaused = await workCoordinator.isRateLimitPaused
            if outcome.wasRateLimited || stillPaused {
                scheduler.scheduleUnattendedContinuationSoon()
            } else if outcome == .completed {
                scheduler.scheduleUnattendedContinuation()
            } else {
                // Expired or otherwise cut short with work left — come back sooner.
                scheduler.scheduleUnattendedContinuationSoon()
            }
            completion.complete(success: shouldContinue())
        }
    }
    #endif
}

#if canImport(BackgroundTasks) && os(iOS)
private final class TaskCompletionBox: @unchecked Sendable {
    private let task: BGTask

    init(task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}
#endif

/// Serializes user start / stop / resume.
///
/// - Start while a live drain is running: join it (reattach after a UI desync).
/// - Start while a drain is stopping: wait for it, then start a new pass.
/// - Stop: flip the cooperative flag and wait until the current pass exits.
private actor UserDrainSession {
    private let continueFlag = OSAllocatedUnfairLock(initialState: true)
    private var inFlight: Task<EnrichmentDrainOutcome, Never>?

    var hasInFlight: Bool { inFlight != nil }

    func run(
        _ work: @escaping @Sendable (
            _ shouldContinue: @escaping @Sendable () -> Bool
        ) async -> EnrichmentDrainOutcome
    ) async -> EnrichmentDrainOutcome {
        while true {
            if let current = inFlight {
                let joiningLive = continueFlag.withLock { $0 }
                let outcome = await current.value
                if joiningLive {
                    return outcome
                }
                // Owner of the stopping pass still has to nil `inFlight`. Yield so
                // we don't spin on the completed task.
                while inFlight != nil {
                    await Task.yield()
                }
                continue
            }

            continueFlag.withLock { $0 = true }
            let flag = continueFlag
            let shouldContinue: @Sendable () -> Bool = {
                flag.withLock { $0 }
            }
            let task = Task {
                await work(shouldContinue)
            }
            inFlight = task
            let outcome = await task.value
            inFlight = nil
            return outcome
        }
    }

    func stop() async {
        continueFlag.withLock { $0 = false }
        if let inFlight {
            _ = await inFlight.value
        }
    }
}

private final class DrainProgressSnapshot: @unchecked Sendable {
    private struct State {
        var completed: Int
        var total: Int
        var phase: EnrichmentProgress.Phase
        var detail: String?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State(
        completed: 0,
        total: 0,
        phase: .running,
        detail: nil
    ))

    init(completed: Int, total: Int) {
        lock.withLock {
            $0.completed = completed
            $0.total = total
        }
    }

    @discardableResult
    func updateCounts(completed: Int, total: Int) -> (phase: EnrichmentProgress.Phase, detail: String?) {
        lock.withLock {
            $0.completed = completed
            $0.total = total
            return ($0.phase, $0.detail)
        }
    }

    func updatePhase(
        _ phase: EnrichmentProgress.Phase,
        detail: String?
    ) -> (completed: Int, total: Int) {
        lock.withLock {
            $0.phase = phase
            $0.detail = detail
            return ($0.completed, $0.total)
        }
    }

    func terminalProgress(
        outcome: EnrichmentDrainOutcome,
        initialTotal: Int
    ) -> EnrichmentProgress {
        lock.withLock {
            let total = max($0.total, $0.completed, initialTotal)
            switch outcome {
            case .completed:
                let doneTotal = max(total, 1)
                return EnrichmentProgress(
                    isRunning: false,
                    phase: .running,
                    completed: doneTotal,
                    total: doneTotal,
                    outcome: .completed
                )
            case .interrupted, .interruptedByRateLimit:
                return EnrichmentProgress(
                    isRunning: false,
                    phase: $0.phase,
                    completed: $0.completed,
                    total: max(total, 1),
                    detail: $0.detail,
                    outcome: outcome
                )
            }
        }
    }
}