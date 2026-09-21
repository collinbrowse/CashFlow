import Foundation

/// Live progress for a user-initiated title cleanup drain.
public struct EnrichmentProgress: Equatable, Sendable {
    public enum Phase: String, Sendable, Equatable, Codable {
        /// Actively parsing titles.
        case running
        /// Waiting out Apple’s on-device model rate limit before continuing.
        case coolingDown
    }

    public var isRunning: Bool
    public var phase: Phase
    public var completed: Int
    public var total: Int
    public var detail: String?
    /// Set when the drain has stopped. In-flight snapshots leave this `nil`.
    public var outcome: EnrichmentDrainOutcome?

    public init(
        isRunning: Bool,
        phase: Phase = .running,
        completed: Int,
        total: Int,
        detail: String? = nil,
        outcome: EnrichmentDrainOutcome? = nil
    ) {
        self.isRunning = isRunning
        self.phase = phase
        self.completed = completed
        self.total = total
        self.detail = detail
        self.outcome = outcome
    }

    public var fractionCompleted: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}
