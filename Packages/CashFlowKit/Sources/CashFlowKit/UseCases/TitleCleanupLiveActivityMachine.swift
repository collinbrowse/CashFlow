import Foundation

/// Turns enrichment-hub events into Live Activity request / update / end commands.
///
/// A snapshot with `outcome` is authoritative: `.completed` always ends Done (even when
/// last counts lagged), interrupted work stays paused at the real counts. Bare `nil`
/// is idle / a missed terminal — complete only when counts already look finished.
public struct TitleCleanupLiveActivityMachine: Sendable {
    public enum Command: Equatable, Sendable {
        case request(TitleCleanupLiveActivityContent)
        case update(TitleCleanupLiveActivityContent)
        case end(TitleCleanupLiveActivityContent)
    }

    /// What to do with a leftover ActivityKit activity when no drain is in flight.
    public enum LeftoverDecision: Equatable, Sendable {
        case none
        case pause
        case complete
    }

    private var isPresented = false
    private var lastContent: TitleCleanupLiveActivityContent?

    public init() {}

    public mutating func handle(_ progress: EnrichmentProgress?) -> Command? {
        if let progress {
            let content = TitleCleanupLiveActivityContent(progress: progress)
            if let outcome = progress.outcome {
                return finish(with: content, outcome: outcome)
            }
            lastContent = content
            if isPresented {
                return .update(content)
            }
            isPresented = true
            return .request(content)
        }

        guard isPresented else { return nil }
        return finish(with: lastContent, outcome: nil)
    }

    /// Leftover lock-screen activities after launch or a missed terminal event.
    /// Empty backlog means the drain already finished — never freeze that as Paused.
    public static func leftoverDecision(
        drainRunning: Bool,
        hasRemainingWork: Bool,
        activityIsComplete: Bool,
        activityIsPaused: Bool
    ) -> LeftoverDecision {
        if drainRunning { return .none }
        if activityIsComplete { return .none }
        if hasRemainingWork {
            return activityIsPaused ? .none : .pause
        }
        return .complete
    }

    private mutating func finish(
        with content: TitleCleanupLiveActivityContent?,
        outcome: EnrichmentDrainOutcome?
    ) -> Command {
        isPresented = false
        lastContent = nil
        let source = content ?? TitleCleanupLiveActivityContent(
            completed: 0,
            total: 0,
            phase: .running
        )
        switch outcome {
        case .completed:
            return .end(source.markedComplete())
        case .interrupted, .interruptedByRateLimit:
            return .end(source.paused())
        case nil:
            return .end(Self.endingContent(from: source))
        }
    }

    private static func endingContent(
        from last: TitleCleanupLiveActivityContent
    ) -> TitleCleanupLiveActivityContent {
        let finished = last.total > 0 && last.completed >= last.total
        return finished ? last.markedComplete() : last.paused()
    }
}
