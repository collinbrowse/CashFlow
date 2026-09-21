import Foundation
import CashFlowKit

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Serializes on-device model work so enrichment and the assistant never contend,
/// even across `await` suspension points (Swift actors are reentrant).
public actor FoundationModelsWorkCoordinator {
    /// How long to treat the model catalog as missing after a hard assets failure.
    public static let assetsCooldownSeconds: TimeInterval = 15 * 60
    /// Retries for Apple’s temporary FM client rate limit during bulk enrichment.
    public static let rateLimitMaxAttemptsForeground = 8
    public static let rateLimitMaxAttemptsBackground = 12
    public static let rateLimitBaseBackoffNanoseconds: UInt64 = 2_000_000_000
    public static let foregroundPaceNanoseconds: UInt64 = 400_000_000
    public static let backgroundPaceNanoseconds: UInt64 = 1_500_000_000
    public static let foregroundRateLimitPauseSeconds: TimeInterval = 45
    public static let backgroundRateLimitPauseSeconds: TimeInterval = 180

    private struct Waiter {
        let id: UUID
        /// `true` means the waiter was cancelled rather than handed its turn.
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var assistantPriorityCount = 0
    private var isBusy = false
    private var waiters: [Waiter] = []
    private var assetsUnavailableUntil: Date?
    private var appIsForeground = true
    private var backgroundWorkClaims = 0
    private var rateLimitPauseUntil: Date?
    private var adaptivePaceNanoseconds: UInt64 = FoundationModelsWorkCoordinator.foregroundPaceNanoseconds

    public init() {}

    public func beginAssistantPriority() {
        assistantPriorityCount += 1
    }

    public func endAssistantPriority() {
        assistantPriorityCount = max(0, assistantPriorityCount - 1)
    }

    public var isAssistantPriorityActive: Bool {
        assistantPriorityCount > 0
    }

    /// Apple throttles far harder outside the foreground, so pace conservatively whenever
    /// the app is backgrounded *or* a background task is still draining. Tracking these
    /// separately keeps a running `BGProcessingTask` from being sped up to foreground
    /// pacing just because the user happened to open the app.
    private var prefersBackgroundPacing: Bool {
        !appIsForeground || backgroundWorkClaims > 0
    }

    public var isPrefersBackgroundPacing: Bool { prefersBackgroundPacing }

    public func setAppForeground(_ isForeground: Bool) {
        appIsForeground = isForeground
        reconcilePacingFloor()
    }

    /// Held for the lifetime of a background task so foregrounding cannot relax its pacing.
    public func beginBackgroundWork() {
        backgroundWorkClaims += 1
        reconcilePacingFloor()
    }

    public func endBackgroundWork() {
        backgroundWorkClaims = max(0, backgroundWorkClaims - 1)
        reconcilePacingFloor()
    }

    private func reconcilePacingFloor() {
        if prefersBackgroundPacing {
            adaptivePaceNanoseconds = max(adaptivePaceNanoseconds, Self.backgroundPaceNanoseconds)
        } else {
            // Back in the foreground with no background work: drop the extreme delays but
            // keep a mild backoff so we don't immediately re-trip the throttle.
            adaptivePaceNanoseconds = min(
                max(adaptivePaceNanoseconds, Self.foregroundPaceNanoseconds),
                Self.foregroundPaceNanoseconds * 2
            )
        }
    }

    /// True after a Model Catalog / assets failure until the cooldown expires.
    public var isAssetsUnavailable: Bool {
        guard let until = assetsUnavailableUntil else { return false }
        if Date() >= until {
            assetsUnavailableUntil = nil
            return false
        }
        return true
    }

    public var isRateLimitPaused: Bool {
        guard let until = rateLimitPauseUntil else { return false }
        if Date() >= until {
            rateLimitPauseUntil = nil
            return false
        }
        return true
    }

    public var rateLimitPauseRemaining: TimeInterval {
        guard let until = rateLimitPauseUntil else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    public func noteAssetsUnavailable() {
        assetsUnavailableUntil = Date().addingTimeInterval(Self.assetsCooldownSeconds)
    }

    /// Clears a prior catalog failure so a user-initiated cleanup can retry.
    /// Does not clear an active rate-limit pause — wait that out instead of hammering FM.
    public func clearAssetsUnavailableCooldown() {
        assetsUnavailableUntil = nil
    }

    public func clearRateLimitPause() {
        rateLimitPauseUntil = nil
    }

    public func noteRateLimited() {
        let pause = prefersBackgroundPacing
            ? Self.backgroundRateLimitPauseSeconds
            : Self.foregroundRateLimitPauseSeconds
        let proposed = Date().addingTimeInterval(pause)
        if let existing = rateLimitPauseUntil {
            rateLimitPauseUntil = max(existing, proposed)
        } else {
            rateLimitPauseUntil = proposed
        }
        // Back off pacing after any throttle so the next stretch is gentler.
        let cap: UInt64 = prefersBackgroundPacing ? 4_000_000_000 : 2_000_000_000
        adaptivePaceNanoseconds = min(adaptivePaceNanoseconds * 2, cap)
    }

    /// Waits out a rate-limit pause. Returns `false` when there was nothing to wait for.
    /// Sleeps in slices so callers observe an early `clearRateLimitPause()`; a cancelled
    /// `Task.sleep` returns immediately, so bail out instead of spinning on the clock.
    /// `shouldContinue` becoming false also returns promptly so Stop isn't stuck on the pause.
    @discardableResult
    public func waitOutRateLimitPauseIfNeeded(
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async -> Bool {
        guard isRateLimitPaused else { return false }
        while isRateLimitPaused, shouldContinue() {
            let remaining = rateLimitPauseRemaining
            guard remaining > 0 else { break }
            let slice = min(remaining, 1.0)
            do {
                try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            } catch {
                return true
            }
        }
        return true
    }

    /// Call before each model invocation (after memo miss).
    public func paceBeforeModelRequest(
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async {
        await waitOutRateLimitPauseIfNeeded(shouldContinue: shouldContinue)
        guard shouldContinue(), !Task.isCancelled else { return }
        try? await Task.sleep(nanoseconds: adaptivePaceNanoseconds)
    }

    /// Queues behind any in-flight generation. Cancelling the calling task removes the
    /// waiter and throws — a plain `withCheckedContinuation` would never be resumed,
    /// hanging the caller and leaking the continuation for the process lifetime.
    private func waitForTurn() async throws {
        while isBusy {
            let id = UUID()
            let wasCancelled = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    if Task.isCancelled {
                        continuation.resume(returning: true)
                    } else {
                        waiters.append(Waiter(id: id, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
            if wasCancelled {
                throw CancellationError()
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: true)
    }

    private func resumeNextWaiter() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume(returning: false)
    }

    /// Runs a single generation unit with a non-reentrant mutex.
    /// Retries automatically when Apple returns a temporary client rate limit.
    public func runExclusive<T: Sendable>(
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        if isAssetsUnavailable {
            throw CashFlowError.intelligenceUnavailable
        }
        try await waitForTurn()
        isBusy = true
        defer {
            isBusy = false
            resumeNextWaiter()
        }

        let maxAttempts = prefersBackgroundPacing
            ? Self.rateLimitMaxAttemptsBackground
            : Self.rateLimitMaxAttemptsForeground
        var attempt = 0
        while true {
            do {
                return try await work()
            } catch {
                if Self.isAssetsUnavailableError(error) {
                    noteAssetsUnavailable()
                    throw error
                }
                if Self.isRateLimitedError(error), attempt + 1 < maxAttempts {
                    attempt += 1
                    noteRateLimited()
                    let delay = Self.rateLimitBaseBackoffNanoseconds << UInt64(min(attempt - 1, 4))
                    let backgroundMultiplier: UInt64 = prefersBackgroundPacing ? 2 : 1
                    do {
                        try await Task.sleep(
                            nanoseconds: min(delay * backgroundMultiplier, 45_000_000_000)
                        )
                    } catch {
                        // Cancelled: retrying now would skip the backoff entirely.
                        throw error
                    }
                    continue
                }
                if Self.isRateLimitedError(error) {
                    noteRateLimited()
                }
                throw error
            }
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    public static func contentTransformationModel() -> SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// Maps Foundation Models errors into user-facing copy. Always prefer throwing
    /// `CashFlowError.intelligence(message:)` at the port boundary afterward.
    @available(iOS 26, macOS 26, *)
    public static func userFacingMessage(for error: Error) -> String {
        if isRateLimitedError(error) {
            return "Apple Intelligence is busy. Wait a moment and try again."
        }
        if isAssetsUnavailableError(error) {
            return "Apple Intelligence isn’t ready on this device yet."
        }
        if CashFlowError.fromBridgedError(error) != nil {
            return CashFlowError.userFacingMessage(
                for: error,
                fallback: "On-device generation failed."
            )
        }
        if let generation = error as? LanguageModelSession.GenerationError {
            if let recovery = generation.recoverySuggestion, !recovery.isEmpty {
                return recovery
            }
            if let reason = generation.failureReason, !reason.isEmpty {
                return reason
            }
            if let description = generation.errorDescription, !description.isEmpty {
                return description
            }
            switch generation {
            case .exceededContextWindowSize:
                return "The conversation got too long. Tap Reset and try again."
            case .assetsUnavailable:
                return "Apple Intelligence assets aren’t ready. Try again in a moment."
            case .guardrailViolation:
                return "Apple Intelligence couldn’t process that request. Try rephrasing."
            case .unsupportedGuide:
                return "On-device generation hit an unsupported constraint."
            case .unsupportedLanguageOrLocale:
                return "That language isn’t supported by Apple Intelligence on this device."
            case .decodingFailure:
                return "The model returned an unexpected shape. Try again."
            case .rateLimited:
                return "Apple Intelligence is busy. Wait a moment and try again."
            case .concurrentRequests:
                return "Another on-device request is still running. Try again."
            case .refusal:
                return "The model declined that request. Try a more specific prompt."
            @unknown default:
                return "On-device generation failed. Try again."
            }
        }
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return userFacingMessage(for: toolError.underlyingError)
        }
        return CashFlowError.userFacingMessage(
            for: error,
            fallback: "On-device generation failed. Try Reset, then ask again with a shorter request."
        )
    }
    #endif

    /// Temporary Apple FM throttle — safe to retry after a short wait.
    public static func isRateLimitedError(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            if let generation = error as? LanguageModelSession.GenerationError,
               case .rateLimited = generation
            {
                return true
            }
        }
        #endif
        return nsErrorTreeMatches(
            error as NSError,
            domainHints: [],
            textHints: ["rate limit", "rate_limit", "try again later"]
        )
    }

    /// Detects Model Catalog / missing Neural Engine asset failures (including nested NSErrors).
    public static func isAssetsUnavailableError(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            if let generation = error as? LanguageModelSession.GenerationError,
               case .assetsUnavailable = generation
            {
                return true
            }
        }
        #endif
        if case CashFlowError.intelligenceUnavailable = error {
            return true
        }
        // Do not treat all ModelManager errors as missing assets — rate limits also
        // arrive via that domain and must remain retryable.
        return nsErrorTreeMatches(
            error as NSError,
            domainHints: ["UnifiedAssetFramework", "SensitiveContentAnalysis"],
            textHints: [
                "model catalog",
                "no underlying assets",
                "asset set com.apple.modelcatalog",
                "failed model manager query",
            ]
        )
    }

    private static func nsErrorTreeMatches(
        _ error: NSError,
        domainHints: [String],
        textHints: [String]
    ) -> Bool {
        var stack: [NSError] = [error]
        var seen = Set<ObjectIdentifier>()
        while let current = stack.popLast() {
            let id = ObjectIdentifier(current)
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            let domain = current.domain
            let blob = [
                domain,
                current.localizedDescription,
                current.localizedFailureReason ?? "",
                String(describing: current),
            ].joined(separator: " ").lowercased()

            if domainHints.contains(where: { domain.localizedCaseInsensitiveContains($0) }) {
                return true
            }
            if textHints.contains(where: { blob.contains($0.lowercased()) }) {
                return true
            }

            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                stack.append(underlying)
            }
        }
        return false
    }
}
