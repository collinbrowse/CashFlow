import Foundation

/// Glanceable title-cleanup progress for a Live Activity (counts and phase only).
public struct TitleCleanupLiveActivityContent: Codable, Hashable, Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var phase: EnrichmentProgress.Phase
    public var isComplete: Bool
    public var isPaused: Bool

    public init(
        completed: Int,
        total: Int,
        phase: EnrichmentProgress.Phase,
        isComplete: Bool = false,
        isPaused: Bool = false
    ) {
        self.completed = completed
        self.total = total
        self.phase = phase
        self.isComplete = isComplete
        self.isPaused = isPaused
    }

    public init(progress: EnrichmentProgress, isComplete: Bool = false) {
        self.init(
            completed: progress.completed,
            total: progress.total,
            phase: progress.phase,
            isComplete: isComplete
        )
    }

    /// Frozen leftover work — the drain stopped with rows still to do.
    public func paused() -> TitleCleanupLiveActivityContent {
        var copy = self
        copy.isPaused = true
        copy.isComplete = false
        return copy
    }

    /// Drain walked the backlog. Fill the ring even if the last in-flight counts lagged.
    public func markedComplete() -> TitleCleanupLiveActivityContent {
        var copy = self
        copy.isComplete = true
        copy.isPaused = false
        copy.phase = .running
        if copy.total > 0 {
            copy.completed = copy.total
        }
        return copy
    }

    public var headline: String { "Cleaning titles" }

    public var countLine: String { "\(completed) of \(total)" }

    public var statusLine: String {
        if isComplete {
            return "Done"
        }
        if isPaused {
            return "Paused"
        }
        switch phase {
        case .running:
            return "Improving transactions"
        case .coolingDown:
            return "Waiting for Apple Intelligence"
        }
    }

    /// Single subtitle used when only one detail line fits.
    public var secondaryLine: String { "\(countLine)  ·  \(statusLine)" }

    /// Ring fill at the view edge. Zero when `total` is unknown.
    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completed = try container.decode(Int.self, forKey: .completed)
        total = try container.decode(Int.self, forKey: .total)
        phase = try container.decode(EnrichmentProgress.Phase.self, forKey: .phase)
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
    }
}
