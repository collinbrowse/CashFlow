import Foundation
import CashFlowKit

enum RemoteSyncTestFixtures {
    static let demoLink = ProviderLinkIdentity(source: .demo, linkNamespace: "demo")
    static let simpleFINLink = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "test-ns")

    static func demoIdentity(accountID: String, connectionID: String = "conn-1") -> RemoteAccountIdentity {
        RemoteAccountIdentity(
            link: demoLink,
            connectionID: connectionID,
            accountID: accountID
        )
    }

    static func simpleFINIdentity(accountID: String, connectionID: String) -> RemoteAccountIdentity {
        RemoteAccountIdentity(
            link: simpleFINLink,
            connectionID: connectionID,
            accountID: accountID
        )
    }

    static func account(
        identity: RemoteAccountIdentity,
        name: String,
        institutionName: String = "Bank",
        currencyCode: String = "USD",
        balance: Decimal,
        balanceDate: Date = .now,
        transactions: [RemoteTransactionSnapshot] = [],
        syncIssue: String? = nil
    ) -> RemoteAccountSnapshot {
        RemoteAccountSnapshot(
            identity: identity,
            name: name,
            institutionName: institutionName,
            currencyCode: currencyCode,
            balance: balance,
            balanceDate: balanceDate,
            transactions: transactions,
            syncIssue: syncIssue
        )
    }

    static func demoPayload(accounts: [RemoteAccountSnapshot]) -> RemoteSyncPayload {
        RemoteSyncPayload(source: demoLink, accounts: accounts)
    }
}
