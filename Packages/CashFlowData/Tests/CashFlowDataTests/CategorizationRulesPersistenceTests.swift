import Foundation
import SwiftData
import Testing
import CashFlowKit
@testable import CashFlowData

@Suite("Categorization rules persistence")
struct CategorizationRulesPersistenceTests {
    @Test("Rule CRUD and reorder")
    func ruleCRUD() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let repo = SwiftDataCategorizationRuleRepository(modelContainer: container)

        let rule = CategorizationRule(
            id: CategorizationRuleID("r1"),
            categoryID: SystemCategory.dining.id,
            priority: 0,
            conditions: [.titleContains("Coffee")]
        )
        try await repo.upsert(rule)
        var all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.conditions == [.titleContains("Coffee")])

        let second = CategorizationRule(
            id: CategorizationRuleID("r2"),
            categoryID: SystemCategory.shopping.id,
            priority: 1,
            conditions: [.titleEquals("Amazon")]
        )
        try await repo.upsert(second)
        try await repo.reorder(ids: [CategorizationRuleID("r2"), CategorizationRuleID("r1")])
        all = try await repo.fetchAll()
        #expect(all.map(\.id.rawValue) == ["r2", "r1"])
        #expect(all[0].priority == 0)
        #expect(all[1].priority == 1)

        try await repo.delete(id: CategorizationRuleID("r2"))
        all = try await repo.fetchAll()
        #expect(all.map(\.id.rawValue) == ["r1"])
    }

    @Test("Reapply overwrites unlocked user-edited; skips locked")
    func reapplyRespectsLock() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let account = AccountEntity(
            id: "acct",
            externalID: "ext-a",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 100,
            balanceDate: .now
        )
        context.insert(account)

        let unlocked = TransactionEntity(
            id: "t-unlocked",
            externalID: "u1",
            accountID: account.id,
            amount: -5,
            postedDate: Date(timeIntervalSince1970: 1_700_000_000),
            transactionDescription: "Coffee Place",
            categoryID: SystemCategory.hidden.id.rawValue,
            currencyCode: "USD",
            userEditedCategory: true,
            isPending: false,
            syncKey: "ext-a|u1",
            account: account,
            categoryLocked: false
        )
        let locked = TransactionEntity(
            id: "t-locked",
            externalID: "u2",
            accountID: account.id,
            amount: -5,
            postedDate: Date(timeIntervalSince1970: 1_700_000_100),
            transactionDescription: "Coffee Place",
            categoryID: SystemCategory.hidden.id.rawValue,
            currencyCode: "USD",
            userEditedCategory: true,
            isPending: false,
            syncKey: "ext-a|u2",
            account: account,
            categoryLocked: true
        )
        context.insert(unlocked)
        context.insert(locked)
        try context.save()

        let rules = SwiftDataCategorizationRuleRepository(modelContainer: container)
        try await rules.upsert(
            CategorizationRule(
                id: CategorizationRuleID("r1"),
                categoryID: SystemCategory.dining.id,
                priority: 0,
                conditions: [.titleContains("Coffee")]
            )
        )

        let reapplier = CategorizationRuleReapplier(modelContainer: container)
        let changed = try await reapplier.reapplyAllRules()
        #expect(changed == 1)

        let refreshed = try ModelContext(container).fetch(FetchDescriptor<TransactionEntity>())
        let unlockedAfter = try #require(refreshed.first { $0.id == "t-unlocked" })
        let lockedAfter = try #require(refreshed.first { $0.id == "t-locked" })
        #expect(unlockedAfter.categoryID == SystemCategory.dining.id.rawValue)
        #expect(unlockedAfter.userEditedCategory == true)
        #expect(unlockedAfter.categorySourceRaw == CategorySource.rule.rawValue)
        #expect(lockedAfter.categoryID == SystemCategory.hidden.id.rawValue)
    }

    @Test("Reapply leaves manual categories alone when no rule matches")
    func reapplyPreservesUnrelatedManualEdits() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let account = AccountEntity(
            id: "acct",
            externalID: "ext-a",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 100,
            balanceDate: .now
        )
        context.insert(account)

        // Matches the new rule.
        context.insert(
            TransactionEntity(
                id: "t-match",
                externalID: "u1",
                accountID: account.id,
                amount: -5,
                postedDate: Date(timeIntervalSince1970: 1_700_000_000),
                transactionDescription: "STARBUCKS #1",
                categoryID: SystemCategory.other.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: false,
                isPending: false,
                syncKey: "ext-a|u1",
                account: account
            )
        )
        // Unrelated manual edit — must survive reapply of a Starbucks rule.
        // Description would otherwise suggest Dining if the suggester re-ran.
        context.insert(
            TransactionEntity(
                id: "t-manual",
                externalID: "u2",
                accountID: account.id,
                amount: -12,
                postedDate: Date(timeIntervalSince1970: 1_700_000_100),
                transactionDescription: "LOCAL COFFEE ROASTERS",
                categoryID: SystemCategory.shopping.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: true,
                isPending: false,
                syncKey: "ext-a|u2",
                account: account
            )
        )
        try context.save()

        let rules = SwiftDataCategorizationRuleRepository(modelContainer: container)
        try await rules.upsert(
            CategorizationRule(
                id: CategorizationRuleID("r1"),
                categoryID: SystemCategory.dining.id,
                priority: 0,
                conditions: [.titleContains("Starbucks")],
                appliesCategory: true
            )
        )

        _ = try await CategorizationRuleReapplier(modelContainer: container).reapplyAllRules()
        let refreshed = try ModelContext(container).fetch(FetchDescriptor<TransactionEntity>())
        let matched = try #require(refreshed.first { $0.id == "t-match" })
        let manual = try #require(refreshed.first { $0.id == "t-manual" })
        #expect(matched.categoryID == SystemCategory.dining.id.rawValue)
        #expect(manual.categoryID == SystemCategory.shopping.id.rawValue)
        #expect(manual.userEditedCategory == true)
    }

    @Test("Reapply renames locked transactions but leaves category alone")
    func reapplyRenamesLocked() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let account = AccountEntity(
            id: "acct",
            externalID: "ext-a",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 100,
            balanceDate: .now
        )
        context.insert(account)
        context.insert(
            TransactionEntity(
                id: "t-locked",
                externalID: "u1",
                accountID: account.id,
                amount: -5,
                postedDate: Date(timeIntervalSince1970: 1_700_000_000),
                transactionDescription: "STARBUCKS #99  Denver CO",
                categoryID: SystemCategory.shopping.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: true,
                isPending: false,
                syncKey: "ext-a|u1",
                account: account,
                categoryLocked: true
            )
        )
        try context.save()

        let rules = SwiftDataCategorizationRuleRepository(modelContainer: container)
        try await rules.upsert(
            CategorizationRule(
                id: CategorizationRuleID("cat"),
                categoryID: SystemCategory.dining.id,
                priority: 0,
                conditions: [.titleContains("Starbucks")],
                appliesCategory: true
            )
        )
        try await rules.upsert(
            CategorizationRule(
                id: CategorizationRuleID("ren"),
                categoryID: SystemCategory.other.id,
                priority: 1,
                conditions: [.titleContains("Starbucks")],
                renameTitle: "Starbucks",
                appliesCategory: false
            )
        )

        let changed = try await CategorizationRuleReapplier(modelContainer: container).reapplyAllRules()
        #expect(changed == 1)
        let tx = try #require(
            try ModelContext(container).fetch(FetchDescriptor<TransactionEntity>()).first
        )
        #expect(tx.categoryID == SystemCategory.shopping.id.rawValue)
        #expect(tx.enrichedTitle == "Starbucks")
        #expect(tx.enrichedLocation == nil)
        #expect(tx.transactionDescription == "STARBUCKS #99  Denver CO")
    }

    @Test("Ingest applies user rules before remote suggestion")
    func ingestAppliesRules() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let rules = SwiftDataCategorizationRuleRepository(modelContainer: container)
        try await rules.upsert(
            CategorizationRule(
                id: CategorizationRuleID("r1"),
                categoryID: SystemCategory.businessServices.id,
                priority: 0,
                conditions: [.titleContains("Cursor")],
                renameTitle: "Cursor"
            )
        )

        let context = ModelContext(container)
        let payload = RemoteSyncTestFixtures.demoPayload(accounts: [
            RemoteSyncTestFixtures.account(
                identity: RemoteSyncTestFixtures.demoIdentity(accountID: "a1"),
                name: "Checking",
                balance: 100,
                transactions: [
                    RemoteTransactionSnapshot(
                        externalID: "t1",
                        amount: -20,
                        postedDate: Date(timeIntervalSince1970: 1_700_000_000),
                        description: "Cursor Subscription",
                        suggestedCategoryID: SystemCategory.shopping.id
                    ),
                ]
            ),
        ])
        try SyncMergeEngine.merge(payload: payload, into: context)

        let txs = try context.fetch(FetchDescriptor<TransactionEntity>())
        #expect(txs.count == 1)
        #expect(txs.first?.categoryID == SystemCategory.businessServices.id.rawValue)
        #expect(txs.first?.userEditedCategory == true)
        #expect(txs.first?.transactionDescription == "Cursor Subscription")
        #expect(txs.first?.enrichedTitle == "Cursor")
    }

    @Test("Reapply renames unlocked matching transactions")
    func reapplyRenames() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let account = AccountEntity(
            id: "acct",
            externalID: "ext-a",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 100,
            balanceDate: .now
        )
        context.insert(account)
        context.insert(
            TransactionEntity(
                id: "t1",
                externalID: "u1",
                accountID: account.id,
                amount: -5,
                postedDate: Date(timeIntervalSince1970: 1_700_000_000),
                transactionDescription: "STARBUCKS #99  Denver CO",
                categoryID: SystemCategory.other.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: false,
                isPending: false,
                syncKey: "ext-a|u1",
                account: account
            )
        )
        try context.save()

        let rules = SwiftDataCategorizationRuleRepository(modelContainer: container)
        try await rules.upsert(
            CategorizationRule(
                id: CategorizationRuleID("r1"),
                categoryID: SystemCategory.dining.id,
                priority: 0,
                conditions: [.titleContains("Starbucks")],
                renameTitle: "Starbucks"
            )
        )

        let changed = try await CategorizationRuleReapplier(modelContainer: container).reapplyAllRules()
        #expect(changed == 1)
        let refreshed = try ModelContext(container).fetch(FetchDescriptor<TransactionEntity>())
        let tx = try #require(refreshed.first)
        #expect(tx.categoryID == SystemCategory.dining.id.rawValue)
        #expect(tx.enrichedTitle == "Starbucks")
        #expect(tx.enrichedLocation == nil)
        #expect(tx.transactionDescription == "STARBUCKS #99  Denver CO")
    }

    @Test("Reapply renames with rename-only rule")
    func reapplyRenameOnly() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let account = AccountEntity(
            id: "acct",
            externalID: "ext-a",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 100,
            balanceDate: .now
        )
        context.insert(account)
        context.insert(
            TransactionEntity(
                id: "t1",
                externalID: "u1",
                accountID: account.id,
                amount: -5,
                postedDate: Date(timeIntervalSince1970: 1_700_000_000),
                transactionDescription: "STARBUCKS #99  Denver CO",
                categoryID: SystemCategory.shopping.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: false,
                isPending: false,
                syncKey: "ext-a|u1",
                account: account
            )
        )
        try context.save()

        let rules = SwiftDataCategorizationRuleRepository(modelContainer: container)
        try await rules.upsert(
            CategorizationRule(
                id: CategorizationRuleID("r1"),
                categoryID: SystemCategory.dining.id,
                priority: 0,
                conditions: [.titleContains("Starbucks")],
                renameTitle: "Starbucks",
                appliesCategory: false
            )
        )

        let changed = try await CategorizationRuleReapplier(modelContainer: container).reapplyAllRules()
        #expect(changed == 1)
        let refreshed = try ModelContext(container).fetch(FetchDescriptor<TransactionEntity>())
        let tx = try #require(refreshed.first)
        #expect(tx.categoryID == SystemCategory.shopping.id.rawValue)
        // Rename-only must not sticky-mark the category as user-edited.
        #expect(tx.userEditedCategory == false)
        #expect(tx.enrichedTitle == "Starbucks")
        #expect(tx.enrichedLocation == nil)
        #expect(tx.transactionDescription == "STARBUCKS #99  Denver CO")
    }

    @Test("Reapply applies categorize and rename rules together")
    func reapplyCategorizeAndRename() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let account = AccountEntity(
            id: "acct",
            externalID: "ext-a",
            name: "Checking",
            institutionName: "Bank",
            currencyCode: "USD",
            balance: 100,
            balanceDate: .now
        )
        context.insert(account)
        context.insert(
            TransactionEntity(
                id: "t1",
                externalID: "u1",
                accountID: account.id,
                amount: -5,
                postedDate: Date(timeIntervalSince1970: 1_700_000_000),
                transactionDescription: "STARBUCKS #99",
                categoryID: SystemCategory.other.id.rawValue,
                currencyCode: "USD",
                userEditedCategory: false,
                isPending: false,
                syncKey: "ext-a|u1",
                account: account
            )
        )
        try context.save()

        let rules = SwiftDataCategorizationRuleRepository(modelContainer: container)
        try await rules.upsert(
            CategorizationRule(
                id: CategorizationRuleID("cat"),
                categoryID: SystemCategory.dining.id,
                priority: 0,
                conditions: [.titleContains("Starbucks")],
                appliesCategory: true
            )
        )
        try await rules.upsert(
            CategorizationRule(
                id: CategorizationRuleID("ren"),
                categoryID: SystemCategory.other.id,
                priority: 1,
                conditions: [.titleContains("Starbucks")],
                renameTitle: "Starbucks",
                appliesCategory: false
            )
        )

        _ = try await CategorizationRuleReapplier(modelContainer: container).reapplyAllRules()
        let tx = try #require(
            try ModelContext(container).fetch(FetchDescriptor<TransactionEntity>()).first
        )
        #expect(tx.categoryID == SystemCategory.dining.id.rawValue)
        #expect(tx.enrichedTitle == "Starbucks")
        #expect(tx.transactionDescription == "STARBUCKS #99")
    }

    @Test("resetAll keeps rules; erase deletes rules")
    func wipePolicy() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let rules = SwiftDataCategorizationRuleRepository(modelContainer: container)
        try await rules.upsert(
            CategorizationRule(
                id: CategorizationRuleID("r1"),
                categoryID: SystemCategory.dining.id,
                priority: 0,
                conditions: [.titleContains("x")]
            )
        )

        let resetter = LocalDataResetter(modelContainer: container)
        try await resetter.resetAll()
        var remaining = try await rules.fetchAll()
        #expect(remaining.count == 1)

        try await resetter.deleteAllCategorizationRules()
        remaining = try await rules.fetchAll()
        #expect(remaining.isEmpty)
    }
}
