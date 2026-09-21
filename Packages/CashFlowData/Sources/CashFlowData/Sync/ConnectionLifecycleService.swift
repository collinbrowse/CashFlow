import Foundation
import CashFlowKit

/// Atomic link / disconnect / erase / reset. Composes sync + resetter + bank linking (SRP).
public actor ConnectionLifecycleService: ConnectionLifecycleServing {
    private let bankLinking: CompositeBankLinkingService
    private let sync: SyncCoordinator
    private let resetter: LocalDataResetter

    public init(
        bankLinking: CompositeBankLinkingService,
        sync: SyncCoordinator,
        resetter: LocalDataResetter
    ) {
        self.bankLinking = bankLinking
        self.sync = sync
        self.resetter = resetter
    }

    public func replaceAndLink(
        withSetupToken token: String,
        deleteLocalData: Bool,
        preservingLinkNamespace: Bool
    ) async throws -> LinkedConnection {
        await sync.cancel()
        let priorNamespace = await bankLinking.connectionStatus().linkNamespace
        if deleteLocalData {
            try await resetter.resetAll()
        }
        try? await bankLinking.unlink(removeLocalData: false)
        let reusedNamespace = preservingLinkNamespace ? priorNamespace : nil
        let receipt = try await bankLinking.link(
            withSetupToken: token,
            preservingLinkNamespace: reusedNamespace
        )
        // Persist secret-free lineage before the first sync (even if sync fails).
        try await resetter.upsertConnectionPlaceholder(
            providerName: receipt.providerName,
            isDemo: receipt.link.source == .demo,
            source: receipt.link.source,
            linkNamespace: receipt.link.linkNamespace
        )
        return try await sync.syncNow()
    }

    public func disconnect(deleteLocalData: Bool) async throws -> LinkedConnection {
        await sync.cancel()
        if deleteLocalData {
            try await resetter.resetAll()
            try await bankLinking.unlink(removeLocalData: false)
        } else {
            try await bankLinking.unlink(removeLocalData: false)
            try await resetter.clearConnection()
        }
        return await sync.connectionStatus()
    }

    public func eraseEverything() async throws {
        await sync.cancel()
        try? await bankLinking.unlink(removeLocalData: false)
        try await resetter.resetAll()
        try await resetter.deleteAllCategorizationRules()
        try await resetter.deleteAllTags()
    }

    public func resetLocalDataKeepingLink() async throws -> LinkedConnection {
        await sync.cancel()
        let prior = await sync.connectionStatus()
        let priorEntity = await sync.storedConnectionMetadata()
        try await resetter.resetAll()
        if prior.isLinked {
            try await resetter.upsertConnectionPlaceholder(
                providerName: prior.providerName,
                isDemo: prior.providerName == "Demo",
                source: priorEntity?.source ?? (prior.providerName == "Demo" ? .demo : .simpleFIN),
                linkNamespace: prior.linkNamespace ?? priorEntity?.linkNamespace
            )
            if prior.providerName == "Demo" {
                await bankLinking.adoptDurableDemoLink()
            }
        }
        return await sync.connectionStatus()
    }
}
