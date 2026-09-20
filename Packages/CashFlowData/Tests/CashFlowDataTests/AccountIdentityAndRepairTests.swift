import Foundation
import SwiftData
import Testing
import CashFlowKit
@testable import CashFlowData

@Suite("AccountDuplicateRepairer")
struct AccountDuplicateRepairerTests {
    @Test("Repair adopts provider identity and preserves retained account id")
    func repairPreservesLocalID() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let syncedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let historicalKey = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "conn-old",
            accountID: "old-id"
        )
        let currentKey = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "conn-new",
            accountID: "new-id"
        )

        let historical = AccountEntity(
            id: "keep-me",
            identityKey: historicalKey,
            source: .simpleFIN,
            linkNamespace: "ns",
            providerConnectionID: "conn-old",
            providerAccountID: "old-id",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 10,
            balanceDate: syncedAt,
            providerLastSeenAt: syncedAt.addingTimeInterval(-86_400),
            providerState: .historical
        )
        let current = AccountEntity(
            id: "drop-me",
            identityKey: currentKey,
            source: .simpleFIN,
            linkNamespace: "ns",
            providerConnectionID: "conn-new",
            providerAccountID: "new-id",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 50,
            balanceDate: syncedAt,
            providerLastSeenAt: syncedAt,
            providerState: .current
        )
        context.insert(historical)
        context.insert(current)
        context.insert(
            ConnectionEntity(
                providerName: "SimpleFIN",
                lastSuccessfulSyncAt: syncedAt,
                source: .simpleFIN,
                linkNamespace: "ns",
                inventoryCompleteness: .complete
            )
        )

        let retainedTxKey = ProviderIdentityEncoding.transactionKey(
            source: .simpleFIN,
            localAccountID: historical.id,
            sourceTransactionID: "t1"
        )
        let providerTxKey = ProviderIdentityEncoding.transactionKey(
            source: .simpleFIN,
            localAccountID: current.id,
            sourceTransactionID: "t1"
        )
        context.insert(
            TransactionEntity(
                id: "tx-keep",
                externalID: "t1",
                accountID: historical.id,
                amount: -20,
                postedDate: Date(timeIntervalSince1970: 1),
                transactionDescription: "Coffee",
                categoryID: SystemCategory.dining.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: true,
                isPending: false,
                identityKey: retainedTxKey,
                account: historical,
                categoryLocked: true,
                categorySourceRaw: CategorySource.user.rawValue
            )
        )
        context.insert(
            TransactionEntity(
                id: "tx-drop",
                externalID: "t1",
                accountID: current.id,
                amount: -20,
                postedDate: Date(timeIntervalSince1970: 1),
                transactionDescription: "Coffee",
                categoryID: SystemCategory.groceries.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: false,
                isPending: false,
                identityKey: providerTxKey,
                account: current
            )
        )
        try context.save()

        let repairer = SwiftDataAccountDuplicateRepairer(modelContainer: container)
        let preview = try await repairer.preview(
            retaining: AccountID("keep-me"),
            adoptingProviderIdentityFrom: AccountID("drop-me"),
            mergeLikelyDuplicates: true
        )
        #expect(preview.exactDuplicateCount == 1)

        let result = try await repairer.repair(
            DuplicateAccountRepairCommand(
                retainedAccountID: AccountID("keep-me"),
                providerAccountID: AccountID("drop-me"),
                expectedPreviewID: preview.id,
                mergeLikelyDuplicates: true
            )
        )
        #expect(result.retainedAccountID.rawValue == "keep-me")
        #expect(result.removedAccountID.rawValue == "drop-me")
        #expect(result.deduplicatedCount == 1)

        let accounts = try context.fetch(FetchDescriptor<AccountEntity>())
        #expect(accounts.count == 1)
        #expect(accounts.first?.id == "keep-me")
        #expect(accounts.first?.identityKey == currentKey)
        #expect(accounts.first?.providerAccountID == "new-id")
        #expect(accounts.first?.balance == 50)

        let txs = try context.fetch(FetchDescriptor<TransactionEntity>())
        #expect(txs.count == 1)
        #expect(txs.first?.id == "tx-keep")
        #expect(txs.first?.categoryLocked == true)
        #expect(txs.first?.categoryID == SystemCategory.dining.id.rawValue)
        #expect(!accounts.contains(where: { $0.identityKey.contains("staging:") }))
    }

    @Test("Likely fingerprint matches stay separate when merge is off")
    func likelyMatchesSurviveWhenDisabled() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let posted = Date(timeIntervalSince1970: 1_700_000_000)
        let historicalKey = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "old",
            accountID: "old-id"
        )
        let currentKey = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "new",
            accountID: "new-id"
        )
        let historical = AccountEntity(
            id: "keep-me",
            identityKey: historicalKey,
            source: .simpleFIN,
            linkNamespace: "ns",
            providerConnectionID: "old",
            providerAccountID: "old-id",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 10,
            balanceDate: posted,
            providerState: .historical
        )
        let current = AccountEntity(
            id: "drop-me",
            identityKey: currentKey,
            source: .simpleFIN,
            linkNamespace: "ns",
            providerConnectionID: "new",
            providerAccountID: "new-id",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 50,
            balanceDate: posted,
            providerState: .current
        )
        context.insert(historical)
        context.insert(current)
        context.insert(
            TransactionEntity(
                id: "tx-keep",
                externalID: "csv-1",
                accountID: historical.id,
                amount: -20,
                postedDate: posted,
                transactionDescription: "Coffee",
                categoryID: SystemCategory.dining.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: false,
                isPending: false,
                identityKey: ProviderIdentityEncoding.transactionKey(
                    source: .simpleFIN,
                    localAccountID: historical.id,
                    sourceTransactionID: "csv-1"
                ),
                account: historical
            )
        )
        context.insert(
            TransactionEntity(
                id: "tx-drop",
                externalID: "bank-1",
                accountID: current.id,
                amount: -20,
                postedDate: posted,
                transactionDescription: "Coffee",
                categoryID: SystemCategory.undefined.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: false,
                isPending: false,
                identityKey: ProviderIdentityEncoding.transactionKey(
                    source: .simpleFIN,
                    localAccountID: current.id,
                    sourceTransactionID: "bank-1"
                ),
                account: current
            )
        )
        try context.save()

        let repairer = SwiftDataAccountDuplicateRepairer(modelContainer: container)
        let preview = try await repairer.preview(
            retaining: AccountID("keep-me"),
            adoptingProviderIdentityFrom: AccountID("drop-me"),
            mergeLikelyDuplicates: false
        )
        #expect(preview.likelyDuplicateCount == 1)
        #expect(preview.movedCount == 1)

        _ = try await repairer.repair(
            DuplicateAccountRepairCommand(
                retainedAccountID: AccountID("keep-me"),
                providerAccountID: AccountID("drop-me"),
                expectedPreviewID: preview.id,
                mergeLikelyDuplicates: false
            )
        )
        let txs = try context.fetch(FetchDescriptor<TransactionEntity>())
        #expect(txs.count == 2)
    }

    @Test("Repair remaps account-scoped categorization rules")
    func remapsAccountRules() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let historicalKey = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "old",
            accountID: "old-id"
        )
        let currentKey = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "new",
            accountID: "new-id"
        )
        let historical = AccountEntity(
            id: "keep-me",
            identityKey: historicalKey,
            source: .simpleFIN,
            linkNamespace: "ns",
            providerConnectionID: "old",
            providerAccountID: "old-id",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 10,
            balanceDate: .now,
            providerState: .historical
        )
        let current = AccountEntity(
            id: "drop-me",
            identityKey: currentKey,
            source: .simpleFIN,
            linkNamespace: "ns",
            providerConnectionID: "new",
            providerAccountID: "new-id",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 50,
            balanceDate: .now,
            providerState: .current
        )
        context.insert(historical)
        context.insert(current)
        context.insert(
            CategorizationRuleEntity(
                id: "rule-1",
                categoryID: SystemCategory.dining.id.rawValue,
                priority: 0,
                conditionsData: try EntityMappers.encodeConditions([
                    .accountID(AccountID("drop-me")),
                ])
            )
        )
        try context.save()

        let repairer = SwiftDataAccountDuplicateRepairer(modelContainer: container)
        let preview = try await repairer.preview(
            retaining: AccountID("keep-me"),
            adoptingProviderIdentityFrom: AccountID("drop-me")
        )
        _ = try await repairer.repair(
            DuplicateAccountRepairCommand(
                retainedAccountID: AccountID("keep-me"),
                providerAccountID: AccountID("drop-me"),
                expectedPreviewID: preview.id
            )
        )
        let rule = try #require(try context.fetch(FetchDescriptor<CategorizationRuleEntity>()).first)
        let conditions = try JSONDecoder().decode([CategorizationCondition].self, from: rule.conditionsData)
        #expect(conditions == [.accountID(AccountID("keep-me"))])
    }

    @Test("Two current accounts can donate identity")
    func twoCurrentCandidates() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let first = AccountEntity(
            id: "keep-me",
            identityKey: ProviderIdentityEncoding.accountKey(
                source: .simpleFIN,
                linkNamespace: "ns",
                connectionID: "c1",
                accountID: "old"
            ),
            source: .simpleFIN,
            linkNamespace: "ns",
            providerConnectionID: "c1",
            providerAccountID: "old",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 10,
            balanceDate: .now,
            providerState: .current
        )
        let second = AccountEntity(
            id: "drop-me",
            identityKey: ProviderIdentityEncoding.accountKey(
                source: .simpleFIN,
                linkNamespace: "ns",
                connectionID: "c1",
                accountID: "new"
            ),
            source: .simpleFIN,
            linkNamespace: "ns",
            providerConnectionID: "c1",
            providerAccountID: "new",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 50,
            balanceDate: .now,
            providerState: .current
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        let repairer = SwiftDataAccountDuplicateRepairer(modelContainer: container)
        let candidates = try await repairer.currentProviderCandidates(retaining: AccountID("keep-me"))
        #expect(candidates.map(\.id.rawValue) == ["drop-me"])
    }
}

@Suite("SyncMergeEngine identity")
struct SyncMergeEngineIdentityTests {
    @Test("Same raw account id under two connections stays two accounts")
    func distinctConnections() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let link = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "ns")
        let payload = RemoteSyncPayload(
            source: link,
            accounts: [
                RemoteAccountSnapshot(
                    identity: RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "same"),
                    name: "Checking",
                    institutionName: "Bank",
                    currencyCode: "USD",
                    balance: 1,
                    balanceDate: .now,
                    transactions: []
                ),
                RemoteAccountSnapshot(
                    identity: RemoteAccountIdentity(link: link, connectionID: "c2", accountID: "same"),
                    name: "Checking",
                    institutionName: "Bank",
                    currencyCode: "USD",
                    balance: 2,
                    balanceDate: .now,
                    transactions: []
                ),
            ],
            inventoryCompleteness: .complete
        )
        try SyncMergeEngine.merge(payload: payload, into: context)
        let accounts = try context.fetch(FetchDescriptor<AccountEntity>())
        #expect(accounts.count == 2)
    }

    @Test("Complete inventory marks unseen accounts historical without deleting")
    func marksHistorical() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let link = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "ns")
        let first = RemoteSyncPayload(
            source: link,
            accounts: [
                RemoteAccountSnapshot(
                    identity: RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "a1"),
                    name: "Checking",
                    institutionName: "Bank",
                    currencyCode: "USD",
                    balance: 1,
                    balanceDate: .now,
                    transactions: []
                ),
            ],
            inventoryCompleteness: .complete
        )
        try SyncMergeEngine.merge(payload: first, into: context)

        let second = RemoteSyncPayload(
            source: link,
            accounts: [
                RemoteAccountSnapshot(
                    identity: RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "a2"),
                    name: "Savings",
                    institutionName: "Bank",
                    currencyCode: "USD",
                    balance: 2,
                    balanceDate: .now,
                    transactions: []
                ),
            ],
            inventoryCompleteness: .complete
        )
        try SyncMergeEngine.merge(payload: second, into: context)
        let accounts = try context.fetch(FetchDescriptor<AccountEntity>())
        #expect(accounts.count == 2)
        let historical = accounts.first { $0.providerAccountID == "a1" }
        let current = accounts.first { $0.providerAccountID == "a2" }
        #expect(historical?.providerState == .historical)
        #expect(current?.providerState == .current)
    }

    @Test("Incomplete inventory does not mark accounts historical")
    func incompleteKeepsCurrent() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let link = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "ns")
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "a1"),
                        name: "Checking",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: 1,
                        balanceDate: .now,
                        transactions: []
                    ),
                ],
                inventoryCompleteness: .complete
            ),
            into: context
        )
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [],
                issues: [
                    RemoteProviderIssue(code: "con.auth", message: "Auth failed", scope: .connection("c1")),
                ],
                inventoryCompleteness: .incomplete
            ),
            into: context
        )
        let accounts = try context.fetch(FetchDescriptor<AccountEntity>())
        #expect(accounts.count == 1)
        #expect(accounts.first?.providerState == .current)
    }

    @Test("Incomplete transaction payload does not prune pending")
    func incompleteDoesNotPrunePending() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let link = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "ns")
        let identity = RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "a1")
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: identity,
                        name: "Card",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: -10,
                        balanceDate: .now,
                        transactions: [
                            RemoteTransactionSnapshot(
                                externalID: "pending-1",
                                amount: -10,
                                postedDate: .now,
                                description: "TEMP",
                                isPending: true
                            ),
                        ]
                    ),
                ]
            ),
            into: context
        )
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: identity,
                        name: "Card",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: -10,
                        balanceDate: .now,
                        transactions: [],
                        transactionCompleteness: .incomplete
                    ),
                ]
            ),
            into: context,
            pruneStalePending: true
        )
        #expect(try context.fetch(FetchDescriptor<TransactionEntity>()).count == 1)
    }

    @Test("Backfill window does not prune live pending")
    func backfillDoesNotPrunePending() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let link = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "ns")
        let identity = RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "a1")
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: identity,
                        name: "Card",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: -10,
                        balanceDate: .now,
                        transactions: [
                            RemoteTransactionSnapshot(
                                externalID: "pending-1",
                                amount: -10,
                                postedDate: .now,
                                description: "TEMP",
                                isPending: true
                            ),
                        ]
                    ),
                ]
            ),
            into: context
        )
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: identity,
                        name: "Card",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: -10,
                        balanceDate: .now,
                        transactions: []
                    ),
                ]
            ),
            into: context,
            pruneStalePending: false
        )
        #expect(try context.fetch(FetchDescriptor<TransactionEntity>()).count == 1)
    }

    @Test("Keep-local new namespace marks prior SimpleFIN rows historical")
    func foreignNamespaceBecomesHistorical() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let oldLink = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "old-ns")
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: oldLink,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: RemoteAccountIdentity(link: oldLink, connectionID: "c1", accountID: "a1"),
                        name: "Checking",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: 1,
                        balanceDate: .now,
                        transactions: []
                    ),
                ],
                inventoryCompleteness: .complete
            ),
            into: context
        )
        context.insert(
            AccountEntity(
                id: UUID().uuidString,
                externalID: "csv:keep",
                name: "Cash",
                institutionName: "CSV Import",
                currencyCode: "USD",
                balance: 0,
                balanceDate: .now,
                createdByImportBatchID: "batch-1"
            )
        )
        try context.save()

        let newLink = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "new-ns")
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: newLink,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: RemoteAccountIdentity(link: newLink, connectionID: "c1", accountID: "a2"),
                        name: "Checking",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: 2,
                        balanceDate: .now,
                        transactions: []
                    ),
                ],
                inventoryCompleteness: .complete
            ),
            into: context
        )
        let accounts = try context.fetch(FetchDescriptor<AccountEntity>())
        let old = accounts.first { $0.providerAccountID == "a1" }
        let csv = accounts.first { $0.createdByImportBatchID == "batch-1" }
        let current = accounts.first { $0.providerAccountID == "a2" }
        #expect(old?.providerState == .historical)
        #expect(csv?.providerState == .current)
        #expect(current?.providerState == .current)
    }

    @Test("Kept-locally accounts stay kept across a later complete inventory")
    func keptLocallySurvivesLaterSync() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let link = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "ns")
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "old"),
                        name: "Checking",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: 1,
                        balanceDate: .now,
                        transactions: []
                    ),
                ],
                inventoryCompleteness: .complete
            ),
            into: context
        )
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "new"),
                        name: "Checking",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: 2,
                        balanceDate: .now,
                        transactions: []
                    ),
                ],
                inventoryCompleteness: .complete
            ),
            into: context
        )
        let historical = try #require(
            try context.fetch(FetchDescriptor<AccountEntity>()).first { $0.providerAccountID == "old" }
        )
        historical.providerState = .keptLocally
        try context.save()

        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "new"),
                        name: "Checking",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: 3,
                        balanceDate: .now,
                        transactions: []
                    ),
                ],
                inventoryCompleteness: .complete
            ),
            into: context
        )
        let kept = try #require(
            try context.fetch(FetchDescriptor<AccountEntity>()).first { $0.providerAccountID == "old" }
        )
        #expect(kept.providerState == .keptLocally)
    }

    @Test("Provider returning a kept-locally account makes it current again")
    func keptLocallyRevivesWhenProviderReturnsIt() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let link = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "ns")
        let identity = RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "a1")
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: identity,
                        name: "Checking",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: 1,
                        balanceDate: .now,
                        transactions: []
                    ),
                ],
                inventoryCompleteness: .complete
            ),
            into: context
        )
        let local = try #require(try context.fetch(FetchDescriptor<AccountEntity>()).first)
        local.providerState = .keptLocally
        try context.save()

        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: identity,
                        name: "Checking",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: 9,
                        balanceDate: .now,
                        transactions: []
                    ),
                ],
                inventoryCompleteness: .complete
            ),
            into: context
        )
        let revived = try #require(try context.fetch(FetchDescriptor<AccountEntity>()).first)
        #expect(revived.providerState == .current)
        #expect(revived.balance == 9)
    }

    @Test("Keep locally rejects current accounts and persists historical ones")
    func keepLocallyPersistsOnlyHistorical() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let historicalKey = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "c1",
            accountID: "old"
        )
        let currentKey = ProviderIdentityEncoding.accountKey(
            source: .simpleFIN,
            linkNamespace: "ns",
            connectionID: "c1",
            accountID: "new"
        )
        context.insert(
            AccountEntity(
                id: "hist",
                identityKey: historicalKey,
                source: .simpleFIN,
                linkNamespace: "ns",
                providerConnectionID: "c1",
                providerAccountID: "old",
                name: "Checking",
                institutionName: "Bank",
                currencyCode: "USD",
                balance: 1,
                balanceDate: .now,
                providerState: .historical
            )
        )
        context.insert(
            AccountEntity(
                id: "cur",
                identityKey: currentKey,
                source: .simpleFIN,
                linkNamespace: "ns",
                providerConnectionID: "c1",
                providerAccountID: "new",
                name: "Checking",
                institutionName: "Bank",
                currencyCode: "USD",
                balance: 2,
                balanceDate: .now,
                providerState: .current
            )
        )
        try context.save()

        let repo = SwiftDataAccountRepository(modelContainer: container)
        try await repo.keepLocally(accountID: AccountID("hist"))
        let kept = try await repo.fetchAll().first { $0.id.rawValue == "hist" }
        #expect(kept?.providerState == .keptLocally)

        await #expect(throws: CashFlowError.self) {
            try await repo.keepLocally(accountID: AccountID("cur"))
        }
    }

    @Test("One failing connection does not archive another connection's inventory")
    func perConnectionArchive() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let link = ProviderLinkIdentity(source: .simpleFIN, linkNamespace: "ns")
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: RemoteAccountIdentity(link: link, connectionID: "c1", accountID: "a1"),
                        name: "Checking",
                        institutionName: "Bank",
                        currencyCode: "USD",
                        balance: 1,
                        balanceDate: .now,
                        transactions: []
                    ),
                    RemoteAccountSnapshot(
                        identity: RemoteAccountIdentity(link: link, connectionID: "c2", accountID: "a2"),
                        name: "Card",
                        institutionName: "Card Co",
                        currencyCode: "USD",
                        balance: 2,
                        balanceDate: .now,
                        transactions: []
                    ),
                ],
                connections: [
                    RemoteProviderConnection(id: "c1", name: "Bank", organization: RemoteOrganization()),
                    RemoteProviderConnection(id: "c2", name: "Card Co", organization: RemoteOrganization()),
                ],
                inventoryCompleteness: .complete
            ),
            into: context
        )
        try SyncMergeEngine.merge(
            payload: RemoteSyncPayload(
                source: link,
                accounts: [
                    RemoteAccountSnapshot(
                        identity: RemoteAccountIdentity(link: link, connectionID: "c2", accountID: "a2-new"),
                        name: "Card",
                        institutionName: "Card Co",
                        currencyCode: "USD",
                        balance: 3,
                        balanceDate: .now,
                        transactions: []
                    ),
                ],
                connections: [
                    RemoteProviderConnection(id: "c1", name: "Bank", organization: RemoteOrganization()),
                    RemoteProviderConnection(id: "c2", name: "Card Co", organization: RemoteOrganization()),
                ],
                issues: [
                    RemoteProviderIssue(code: "con.auth", message: "Bank failed", scope: .connection("c1")),
                ],
                inventoryCompleteness: .incomplete
            ),
            into: context
        )
        let accounts = try context.fetch(FetchDescriptor<AccountEntity>())
        let checking = accounts.first { $0.providerAccountID == "a1" }
        let oldCard = accounts.first { $0.providerAccountID == "a2" }
        let newCard = accounts.first { $0.providerAccountID == "a2-new" }
        #expect(checking?.providerState == .current)
        #expect(oldCard?.providerState == .historical)
        #expect(newCard?.providerState == .current)
    }
}

@Suite("Keychain credential envelope")
struct KeychainCredentialEnvelopeTests {
    @Test("In-memory store round-trips envelope")
    func envelopeRoundTrip() throws {
        let store = InMemoryAccessURLStore()
        try store.save(
            SimpleFINCredentialEnvelope(
                accessURL: "https://user:pass@example.com/simplefin",
                linkNamespace: "ns-1"
            )
        )
        let loaded = try #require(try store.loadEnvelope())
        #expect(loaded.accessURL.contains("example.com"))
        #expect(loaded.linkNamespace == "ns-1")
    }

    @Test("Legacy UTF-8 Access URL upgrades to an envelope")
    func legacyPlainStringUpgrades() {
        let data = Data("https://user:pass@example.com/simplefin".utf8)
        let parsed = SimpleFINCredentialEnvelope.parse(
            fromStored: data,
            mintedLinkNamespace: "upgraded-ns"
        )
        #expect(parsed?.upgradedFromLegacy == true)
        #expect(parsed?.envelope.accessURL == "https://user:pass@example.com/simplefin")
        #expect(parsed?.envelope.linkNamespace == "upgraded-ns")
    }

    @Test("JSON envelope is not treated as legacy")
    func jsonEnvelopeIsCurrent() throws {
        let original = SimpleFINCredentialEnvelope(
            accessURL: "https://user:pass@example.com/simplefin",
            linkNamespace: "ns-json"
        )
        let data = try JSONEncoder().encode(original)
        let parsed = try #require(SimpleFINCredentialEnvelope.parse(fromStored: data))
        #expect(!parsed.upgradedFromLegacy)
        #expect(parsed.envelope == original)
    }
}

@Suite("V3 store epoch")
struct V3StoreEpochTests {
    @Test("Marked epoch skips ledger reset and leaves credentials alone")
    func markedEpochIsNoOp() throws {
        let suite = "cashflow.tests.epoch.\(UUID().uuidString)"
        let store = InMemoryAccessURLStore()
        try store.save(
            SimpleFINCredentialEnvelope(
                accessURL: "https://user:pass@example.com/simplefin",
                linkNamespace: "keep"
            )
        )
        ModelContainerFactory.markV3StoreReady(appGroupID: suite)
        ModelContainerFactory.performOneTimeV3LedgerResetIfNeeded(appGroupID: suite)
        #expect(ModelContainerFactory.isV3StoreReady(appGroupID: suite))
        #expect(try store.loadEnvelope()?.linkNamespace == "keep")
        ModelContainerFactory.clearV3StoreEpochMarker(appGroupID: suite)
    }
}
