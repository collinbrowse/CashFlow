import Foundation
import Testing
import CashFlowKit

@Suite("TitleCleanupLiveActivity")
struct TitleCleanupLiveActivityTests {
    @Test("Copy uses AirDrop-style headline, counts, and phase status")
    func copy() {
        let running = TitleCleanupLiveActivityContent(
            completed: 142,
            total: 1_280,
            phase: .running
        )
        #expect(running.headline == "Cleaning titles")
        #expect(running.countLine == "142 of 1280")
        #expect(running.statusLine == "Improving transactions")
        #expect(running.fractionCompleted == Double(142) / Double(1_280))

        let cooling = TitleCleanupLiveActivityContent(
            completed: 142,
            total: 1_280,
            phase: .coolingDown
        )
        #expect(cooling.statusLine == "Waiting for Apple Intelligence")
        #expect(cooling.fractionCompleted == running.fractionCompleted)

        let done = TitleCleanupLiveActivityContent(
            completed: 1_280,
            total: 1_280,
            phase: .running,
            isComplete: true
        )
        #expect(done.statusLine == "Done")
        #expect(done.fractionCompleted == 1)

        let paused = running.paused()
        #expect(paused.statusLine == "Paused")
        #expect(paused.isPaused)
        #expect(paused.secondaryLine == "142 of 1280  ·  Paused")
        #expect(paused.fractionCompleted == running.fractionCompleted)

        let pausedOverCooling = cooling.paused()
        #expect(pausedOverCooling.statusLine == "Paused")

        let doneFromHalfway = running.markedComplete()
        #expect(doneFromHalfway.statusLine == "Done")
        #expect(doneFromHalfway.isComplete)
        #expect(!doneFromHalfway.isPaused)
        #expect(doneFromHalfway.completed == 1_280)
        #expect(doneFromHalfway.fractionCompleted == 1)
    }

    @Test("fractionCompleted is 0 when total is zero and clamps to 1")
    func fractionEdgeCases() {
        let unknown = TitleCleanupLiveActivityContent(completed: 0, total: 0, phase: .running)
        #expect(unknown.fractionCompleted == 0)

        let over = TitleCleanupLiveActivityContent(completed: 5, total: 4, phase: .running)
        #expect(over.fractionCompleted == 1)
    }

    @Test("First progress requests; later counts update")
    func requestThenUpdate() {
        var machine = TitleCleanupLiveActivityMachine()
        let first = EnrichmentProgress(isRunning: true, completed: 0, total: 100)
        #expect(machine.handle(first) == .request(TitleCleanupLiveActivityContent(progress: first)))

        let next = EnrichmentProgress(isRunning: true, completed: 12, total: 100)
        #expect(machine.handle(next) == .update(TitleCleanupLiveActivityContent(progress: next)))
    }

    @Test("Cooling down keeps the same counts so the ring freezes")
    func coolingDownFreezesRing() {
        var machine = TitleCleanupLiveActivityMachine()
        let running = EnrichmentProgress(
            isRunning: true,
            phase: .running,
            completed: 40,
            total: 80
        )
        _ = machine.handle(running)

        let cooling = EnrichmentProgress(
            isRunning: true,
            phase: .coolingDown,
            completed: 40,
            total: 80
        )
        guard case .update(let content) = machine.handle(cooling) else {
            Issue.record("Expected an update while cooling down")
            return
        }
        #expect(content.phase == .coolingDown)
        #expect(content.completed == 40)
        #expect(content.total == 80)
        #expect(content.fractionCompleted == 0.5)
        #expect(content.isComplete == false)
    }

    @Test("nil after finishing counts ends as complete")
    func completeEnd() {
        var machine = TitleCleanupLiveActivityMachine()
        _ = machine.handle(EnrichmentProgress(isRunning: true, completed: 0, total: 10))
        _ = machine.handle(EnrichmentProgress(isRunning: true, completed: 10, total: 10))

        guard case .end(let content) = machine.handle(nil) else {
            Issue.record("Expected an end command")
            return
        }
        #expect(content.isComplete)
        #expect(content.completed == 10)
        #expect(content.total == 10)
        #expect(content.statusLine == "Done")
    }

    @Test("nil with leftover work ends paused, not 100%")
    func interruptedEnd() {
        var machine = TitleCleanupLiveActivityMachine()
        _ = machine.handle(EnrichmentProgress(isRunning: true, completed: 3, total: 10))

        guard case .end(let content) = machine.handle(nil) else {
            Issue.record("Expected an end command")
            return
        }
        #expect(!content.isComplete)
        #expect(content.isPaused)
        #expect(content.statusLine == "Paused")
        #expect(content.completed == 3)
        #expect(content.total == 10)
        #expect(content.fractionCompleted == 0.3)
    }

    @Test("Idle nil is a no-op")
    func idleNil() {
        var machine = TitleCleanupLiveActivityMachine()
        #expect(machine.handle(nil) == nil)
    }

    @Test("Can request again after an end")
    func requestAfterEnd() {
        var machine = TitleCleanupLiveActivityMachine()
        let first = EnrichmentProgress(isRunning: true, completed: 1, total: 4)
        _ = machine.handle(first)
        _ = machine.handle(nil)

        let again = EnrichmentProgress(isRunning: true, completed: 0, total: 8)
        #expect(machine.handle(again) == .request(TitleCleanupLiveActivityContent(progress: again)))
    }

    @Test("Completed outcome ends Done even when last counts are halfway")
    func completedOutcomeIgnoresLaggingCounts() {
        var machine = TitleCleanupLiveActivityMachine()
        _ = machine.handle(EnrichmentProgress(isRunning: true, completed: 5, total: 10))

        let finished = EnrichmentProgress(
            isRunning: false,
            completed: 5,
            total: 10,
            outcome: .completed
        )
        guard case .end(let content) = machine.handle(finished) else {
            Issue.record("Expected an end command")
            return
        }
        #expect(content.isComplete)
        #expect(!content.isPaused)
        #expect(content.completed == 10)
        #expect(content.total == 10)
        #expect(content.statusLine == "Done")
    }

    @Test("Interrupted outcome stays paused at the real counts")
    func interruptedOutcomeStaysPaused() {
        var machine = TitleCleanupLiveActivityMachine()
        _ = machine.handle(EnrichmentProgress(isRunning: true, completed: 5, total: 10))

        let stopped = EnrichmentProgress(
            isRunning: false,
            completed: 5,
            total: 10,
            outcome: .interrupted
        )
        guard case .end(let content) = machine.handle(stopped) else {
            Issue.record("Expected an end command")
            return
        }
        #expect(!content.isComplete)
        #expect(content.isPaused)
        #expect(content.completed == 5)
        #expect(content.total == 10)
        #expect(content.statusLine == "Paused")
    }

    @Test("Leftover activity with an empty backlog completes instead of pausing")
    func leftoverEmptyBacklogCompletes() {
        #expect(
            TitleCleanupLiveActivityMachine.leftoverDecision(
                drainRunning: false,
                hasRemainingWork: false,
                activityIsComplete: false,
                activityIsPaused: true
            ) == .complete
        )
        #expect(
            TitleCleanupLiveActivityMachine.leftoverDecision(
                drainRunning: false,
                hasRemainingWork: true,
                activityIsComplete: false,
                activityIsPaused: false
            ) == .pause
        )
        #expect(
            TitleCleanupLiveActivityMachine.leftoverDecision(
                drainRunning: true,
                hasRemainingWork: false,
                activityIsComplete: false,
                activityIsPaused: false
            ) == .none
        )
        #expect(
            TitleCleanupLiveActivityMachine.leftoverDecision(
                drainRunning: false,
                hasRemainingWork: true,
                activityIsComplete: false,
                activityIsPaused: true
            ) == .none
        )
    }
}
