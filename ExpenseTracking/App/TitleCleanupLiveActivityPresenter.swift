import Foundation
import CashFlowKit

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Mirrors user-initiated title-cleanup progress into an AirDrop-style Live Activity.
///
/// Constructed only from `DependencyContainer`. UITests pass `enabled: false` so ActivityKit
/// is never touched on CI.
///
/// Status follows the drain, not scene phase. Incoming progress is always running.
/// Paused is leftover work after an interrupt. Finished drains end Done even when
/// the last in-flight counts lagged (title pass looking like 50% of titles+categories).
@MainActor
final class TitleCleanupLiveActivityPresenter {
    private let enabled: Bool
    private let backgroundEnrichment: any BackgroundEnrichmentScheduling
    private var machine = TitleCleanupLiveActivityMachine()
    private var observation: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var pendingUpdate: TitleCleanupLiveActivityContent?
    private var lastFlushedPhase: EnrichmentProgress.Phase?
    private var lastFlushDate: Date?

    private static let debounceSeconds: TimeInterval = 1
    private static let runningStaleInterval: TimeInterval = 90
    private static let pausedStaleInterval: TimeInterval = 24 * 60 * 60

    init(enabled: Bool, backgroundEnrichment: any BackgroundEnrichmentScheduling) {
        self.enabled = enabled
        self.backgroundEnrichment = backgroundEnrichment
    }

    func startObserving() {
        guard enabled else { return }
        observation?.cancel()
        debounceTask?.cancel()
        pendingUpdate = nil
        observation = Task { [weak self] in
            guard let self else { return }
            await self.reconcileLeftoverActivitiesIfIdle()
            for await progress in self.backgroundEnrichment.enrichmentProgressUpdates() {
                guard !Task.isCancelled else { return }
                await self.apply(progress)
            }
        }
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
        debounceTask?.cancel()
        debounceTask = nil
        pendingUpdate = nil
    }

    private func apply(_ progress: EnrichmentProgress?) async {
        guard let command = machine.handle(progress) else {
            if progress == nil {
                await reconcileLeftoverActivitiesIfIdle()
            }
            return
        }
        switch command {
        case .request(let content):
            debounceTask?.cancel()
            pendingUpdate = nil
            lastFlushedPhase = content.phase
            lastFlushDate = Date()
            await request(content)
        case .update(let content):
            await scheduleUpdate(content)
        case .end(let content):
            debounceTask?.cancel()
            pendingUpdate = nil
            lastFlushedPhase = nil
            lastFlushDate = nil
            if content.isComplete {
                await end(content)
            } else {
                await update(content)
            }
        }
    }

    private func scheduleUpdate(_ content: TitleCleanupLiveActivityContent) async {
        let phaseChanged = content.phase != lastFlushedPhase
        let elapsed = Date().timeIntervalSince(lastFlushDate ?? .distantPast)
        if phaseChanged || elapsed >= Self.debounceSeconds {
            debounceTask?.cancel()
            pendingUpdate = nil
            lastFlushedPhase = content.phase
            lastFlushDate = Date()
            await update(content)
            return
        }

        pendingUpdate = content
        debounceTask?.cancel()
        let remaining = Self.debounceSeconds - elapsed
        debounceTask = Task { [weak self] in
            let nanos = UInt64(max(remaining, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            guard let self, let pending = self.pendingUpdate else { return }
            self.pendingUpdate = nil
            self.lastFlushedPhase = pending.phase
            self.lastFlushDate = Date()
            await self.update(pending)
        }
    }

#if canImport(ActivityKit)
    private func request(_ content: TitleCleanupLiveActivityContent) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await dismissExisting()
        do {
            _ = try Activity.request(
                attributes: TitleCleanupActivityAttributes(),
                content: makeContent(content),
                pushType: nil
            )
        } catch {
            // Live Activities can be disabled or unavailable on CI / unsigned sims.
        }
    }

    private func update(_ content: TitleCleanupLiveActivityContent) async {
        let activities = Activity<TitleCleanupActivityAttributes>.activities
        guard let activity = activities.first else {
            await request(content)
            return
        }
        await activity.update(makeContent(content))
    }

    private func end(_ content: TitleCleanupLiveActivityContent) async {
        let policy: ActivityUIDismissalPolicy = content.isComplete ? .default : .immediate
        let payload = makeContent(content, staleDate: nil)
        for activity in Activity<TitleCleanupActivityAttributes>.activities {
            await activity.end(payload, dismissalPolicy: policy)
        }
    }

    private func dismissExisting() async {
        for activity in Activity<TitleCleanupActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func reconcileLeftoverActivitiesIfIdle() async {
        let drainRunning = await backgroundEnrichment.isFullDrainRunning
        let remaining = drainRunning
            ? true
            : await backgroundEnrichment.hasRemainingCleanupWork()
        var didFinishLeftover = false
        for activity in Activity<TitleCleanupActivityAttributes>.activities {
            let state = activity.content.state
            let decision = TitleCleanupLiveActivityMachine.leftoverDecision(
                drainRunning: drainRunning,
                hasRemainingWork: remaining,
                activityIsComplete: state.isComplete,
                activityIsPaused: state.isPaused
            )
            switch decision {
            case .none:
                break
            case .pause:
                await activity.update(makeContent(state.paused()))
            case .complete:
                await activity.end(
                    makeContent(state.markedComplete(), staleDate: nil),
                    dismissalPolicy: .default
                )
                didFinishLeftover = true
            }
        }
        if !drainRunning {
            machine = TitleCleanupLiveActivityMachine()
            if didFinishLeftover {
                lastFlushedPhase = nil
                lastFlushDate = nil
            }
        }
    }

    private func makeContent(
        _ state: TitleCleanupLiveActivityContent,
        staleDate: Date? = nil
    ) -> ActivityContent<TitleCleanupLiveActivityContent> {
        let resolvedStale = staleDate ?? Date().addingTimeInterval(
            state.isPaused ? Self.pausedStaleInterval : Self.runningStaleInterval
        )
        return ActivityContent(state: state, staleDate: resolvedStale)
    }
#else
    private func request(_: TitleCleanupLiveActivityContent) async {}
    private func update(_: TitleCleanupLiveActivityContent) async {}
    private func end(_: TitleCleanupLiveActivityContent) async {}
    private func reconcileLeftoverActivitiesIfIdle() async {}
#endif
}
