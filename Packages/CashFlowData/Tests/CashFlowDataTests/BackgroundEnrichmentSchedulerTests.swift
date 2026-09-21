import Foundation
import os
import SwiftData
import Testing
import CashFlowKit
@testable import CashFlowData

@Suite("Background enrichment scheduler")
struct BackgroundEnrichmentSchedulerTests {
    @Test("Stop then Resume starts a new drain instead of joining the interrupted one")
    func stopThenResumeStartsNewDrain() async throws {
        let runner = BlockingEnrichmentRunner()
        let scheduler = try await makeScheduler(runner: runner)

        let first = Task {
            await scheduler.runFullEnrichmentDrain(expectedTotal: 8)
        }
        await runner.waitUntilStarted(1)
        await scheduler.stopFullEnrichmentDrain()
        #expect(await first.value == .interrupted)
        #expect(await runner.startCount == 1)

        await runner.completeNextPass()
        let resumed = await scheduler.runFullEnrichmentDrain(expectedTotal: 8)
        #expect(resumed == .completed)
        #expect(await runner.startCount == 2)
    }

    @Test("Resume while a drain is still running reattaches instead of interrupting")
    func resumeWhileRunningJoinsLiveDrain() async throws {
        let runner = BlockingEnrichmentRunner()
        let scheduler = try await makeScheduler(runner: runner)

        let first = Task {
            await scheduler.runFullEnrichmentDrain(expectedTotal: 8)
        }
        await runner.waitUntilStarted(1)

        let join = Task {
            await scheduler.runFullEnrichmentDrain(expectedTotal: 8)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await runner.startCount == 1)

        await runner.completeNextPass()
        let firstOutcome = await first.value
        let joinOutcome = await join.value
        #expect(firstOutcome == .completed)
        #expect(joinOutcome == .completed)
        #expect(await runner.startCount == 1)
    }

    @Test("Completed drain publishes a finished snapshot even if last counts lagged")
    func completedDrainEmitsFinishedProgress() async throws {
        let runner = ProgressReportingRunner(events: [(4, 10)], outcome: .completed)
        let hub = EnrichmentProgressHub()
        let scheduler = try await makeScheduler(runner: runner, progressHub: hub)
        let recorder = ProgressEventRecorder()
        let stream = hub.subscribe()
        let listen = Task {
            for await progress in stream {
                recorder.append(progress)
            }
        }
        let outcome = await scheduler.runFullEnrichmentDrain(expectedTotal: 10)
        #expect(outcome == .completed)
        try await Task.sleep(nanoseconds: 20_000_000)
        listen.cancel()

        let events = recorder.events
        #expect(events.contains { $0?.isRunning == true && $0?.completed == 4 && $0?.total == 10 })
        #expect(events.contains {
            $0?.outcome == .completed && $0?.completed == 10 && $0?.total == 10 && $0?.isRunning == false
        })
        #expect(events.contains { $0 == nil })
        #expect(await scheduler.hasRemainingCleanupWork() == false)
    }

    @Test("Interrupted drain publishes leftover counts, not a fake 100%")
    func interruptedDrainEmitsInterruptedProgress() async throws {
        let runner = ProgressReportingRunner(events: [(4, 10)], outcome: .interrupted)
        let hub = EnrichmentProgressHub()
        let scheduler = try await makeScheduler(runner: runner, progressHub: hub)
        let recorder = ProgressEventRecorder()
        let stream = hub.subscribe()
        let listen = Task {
            for await progress in stream {
                recorder.append(progress)
            }
        }
        let outcome = await scheduler.runFullEnrichmentDrain(expectedTotal: 10)
        #expect(outcome == .interrupted)
        try await Task.sleep(nanoseconds: 20_000_000)
        listen.cancel()

        let events = recorder.events
        #expect(events.contains {
            $0?.outcome == .interrupted && $0?.completed == 4 && $0?.total == 10
        })
        #expect(!events.contains { $0?.outcome == .completed })
    }

    private func makeScheduler(
        runner: some TransactionEnrichmentRunning,
        progressHub: EnrichmentProgressHub = EnrichmentProgressHub()
    ) async throws -> BackgroundEnrichmentScheduler {
        let linking = CompositeBankLinkingService(
            demo: DemoBankLinkingService(seedSize: .standard),
            simpleFIN: SimpleFINBankLinkingService(
                accessURLStore: InMemoryAccessURLStore()
            ),
            initialMode: .none
        )
        let container = try ModelContainerFactory.make(inMemory: true)
        let sync = SyncCoordinator(
            modelContainer: container,
            bankLinking: linking,
            enrichment: runner
        )
        return BackgroundEnrichmentScheduler(
            enrichment: runner,
            sync: sync,
            progressHub: progressHub,
            workCoordinator: FoundationModelsWorkCoordinator()
        )
    }
}

private actor BlockingEnrichmentRunner: TransactionEnrichmentRunning {
    private(set) var startCount = 0
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var hold = true

    var isFullDrainRunning: Bool { hold && startCount > 0 }

    func waitUntilStarted(_ count: Int) async {
        if startCount >= count { return }
        await withCheckedContinuation { continuation in
            if startCount >= count {
                continuation.resume()
            } else {
                startedContinuations.append(continuation)
            }
        }
    }

    func completeNextPass() {
        hold = false
    }

    func enrichAfterSync(
        skipIfLargeBacklog: Bool,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async -> EnrichmentWorkEstimate? {
        _ = skipIfLargeBacklog
        _ = onProgress
        return nil
    }

    func drainAllNeedingEnrichment(
        shouldContinue: @escaping @Sendable () -> Bool,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async -> EnrichmentDrainOutcome {
        _ = onProgress
        startCount += 1
        let started = startedContinuations
        startedContinuations.removeAll()
        started.forEach { $0.resume() }

        while shouldContinue(), hold {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let interrupted = !shouldContinue()
        hold = true
        return interrupted ? .interrupted : .completed
    }
}

private actor ProgressReportingRunner: TransactionEnrichmentRunning {
    let events: [(Int, Int)]
    let outcome: EnrichmentDrainOutcome

    init(events: [(Int, Int)], outcome: EnrichmentDrainOutcome) {
        self.events = events
        self.outcome = outcome
    }

    var isFullDrainRunning: Bool { false }

    func enrichAfterSync(
        skipIfLargeBacklog: Bool,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async -> EnrichmentWorkEstimate? {
        _ = skipIfLargeBacklog
        _ = onProgress
        return nil
    }

    func drainAllNeedingEnrichment(
        shouldContinue: @escaping @Sendable () -> Bool,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async -> EnrichmentDrainOutcome {
        _ = shouldContinue
        for event in events {
            onProgress?(event.0, event.1)
        }
        return outcome
    }
}

private final class ProgressEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EnrichmentProgress?] = []

    var events: [EnrichmentProgress?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: EnrichmentProgress?) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
