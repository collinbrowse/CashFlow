import Foundation
import SwiftData
import CashFlowKit

/// Synchronous Demo ledger for UITest launches — avoids async `loadDemo` / WidgetKit /
/// Foundation Models paths that hang under unsigned CI simulators.
public enum UITestDemoSeeder {
    public static func seedStandardDemo(
        into modelContainer: ModelContainer,
        now: Date = .now
    ) throws {
        let context = ModelContext(modelContainer)
        let remoteAccounts = DemoBankLinkingService.makeAccounts(
            count: DemoBankLinkingService.SeedSize.standard.transactionCount,
            now: now
        )
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: ProviderLinkIdentity(source: .demo, linkNamespace: "demo"),
                accounts: remoteAccounts
            ),
            into: context
        )

        let earliest = remoteAccounts
            .flatMap(\.transactions)
            .map(\.postedDate)
            .min()

        context.insert(
            ConnectionEntity(
                providerName: "Demo",
                needsReauth: false,
                lastSuccessfulSyncAt: now,
                isDemo: true,
                source: .demo,
                linkNamespace: DemoBankLinkingService.linkNamespace,
                inventoryCompleteness: .complete,
                earliestFetchedDate: earliest,
                historyComplete: true,
                historyBackfillComplete: true
            )
        )
        try context.save()
    }
}
