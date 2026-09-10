import Foundation
import Testing
@testable import CashFlowKit

@Suite("ProviderIdentityEncoding")
struct ProviderIdentityEncodingTests {
    @Test("Same raw account id under two connections yields distinct keys")
    func distinctConnections() {
        let a = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "conn-1",
            accountID: "2930002"
        )
        let b = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "conn-2",
            accountID: "2930002"
        )
        #expect(a != b)
    }

    @Test("Delimiter-containing ids cannot collide")
    func delimiterSafe() {
        let a = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "a|b",
            accountID: "c"
        )
        let b = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "a",
            accountID: "b|c"
        )
        #expect(a != b)
    }

    @Test("Transaction keys are scoped to local account uuid")
    func transactionScoped() {
        let a = ProviderIdentityEncoding.transactionKey(
            source: .simpleFIN,
            localAccountID: "local-1",
            sourceTransactionID: "tx-1"
        )
        let b = ProviderIdentityEncoding.transactionKey(
            source: .simpleFIN,
            localAccountID: "local-2",
            sourceTransactionID: "tx-1"
        )
        #expect(a != b)
    }

    @Test("CSV and SimpleFIN namespaces never collide")
    func sourceNamespaces() {
        let csv = ProviderIdentityEncoding.csvAccountKey(localAccountID: "same")
        let bank = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "c",
            accountID: "same"
        )
        #expect(csv != bank)
    }
}

@Suite("Remote inventory authority")
struct RemoteInventoryAuthorityTests {
    @Test("Connection-scoped issues drop only that connection")
    func dropsFailedConnectionOnly() {
        let ids = RemoteSyncPayload.derivedAuthoritativeConnectionIDs(
            connections: [
                RemoteProviderConnection(id: "c1", name: "Bank", organization: RemoteOrganization()),
                RemoteProviderConnection(id: "c2", name: "Card", organization: RemoteOrganization()),
            ],
            accounts: [],
            issues: [
                RemoteProviderIssue(code: "con.auth", message: "fail", scope: .connection("c1")),
            ],
            inventoryCompleteness: .incomplete
        )
        #expect(ids == ["c2"])
    }

    @Test("Global issues authorize no connections")
    func globalIssueAuthorizesNone() {
        let ids = RemoteSyncPayload.derivedAuthoritativeConnectionIDs(
            connections: [
                RemoteProviderConnection(id: "c1", name: "Bank", organization: RemoteOrganization()),
            ],
            accounts: [],
            issues: [
                RemoteProviderIssue(code: "gen.", message: "down", scope: .global),
            ],
            inventoryCompleteness: .incomplete
        )
        #expect(ids.isEmpty)
    }
}

@Suite("MergeDuplicateTransactionMetadataPolicy")
struct MergeDuplicateTransactionMetadataPolicyTests {
    @Test("Locked category wins and tags union with suppressions")
    func lockedAndTags() {
        let retained = Transaction(
            id: TransactionID("r"),
            accountID: AccountID("a"),
            externalID: "t1",
            amount: -10,
            postedDate: Date(timeIntervalSince1970: 1),
            description: "Coffee",
            categoryID: SystemCategory.dining.id,
            categoryLocked: true,
            tagIDs: [TagID("keep")],
            suppressedTagIDs: [TagID("gone")],
            categorySource: .user
        )
        let discarded = Transaction(
            id: TransactionID("d"),
            accountID: AccountID("b"),
            externalID: "t1",
            amount: -10,
            postedDate: Date(timeIntervalSince1970: 1),
            description: "Coffee",
            categoryID: SystemCategory.groceries.id,
            tagIDs: [TagID("gone"), TagID("extra")],
            categorySource: .llm
        )
        let merged = MergeDuplicateTransactionMetadataPolicy.merge(
            retained: retained,
            discarded: discarded
        )
        #expect(merged.categoryID == SystemCategory.dining.id)
        #expect(merged.categoryLocked == true)
        #expect(Set(merged.tagIDs.map(\.rawValue)) == Set(["keep", "extra"]))
        #expect(merged.suppressedTagIDs.map(\.rawValue) == ["gone"])
    }
}
