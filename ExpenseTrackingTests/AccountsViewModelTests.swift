import Foundation
import Testing
import CashFlowKit
@testable import ExpenseTracking

@Suite("AccountsViewModel")
@MainActor
struct AccountsViewModelTests {
    @Test("Connection status and reconnect reflect per-account sync issues")
    func syncIssuesSurfaceNeedsAttention() async {
        let account = Account(
            id: AccountID("a1"),
            externalID: "ext-1",
            name: "Checking",
            institutionName: "Chase",
            currencyCode: "USD",
            balance: 10,
            balanceDate: .now,
            syncIssue: "Authentication failed for Chase"
        )
        let sync = MockAccountsSyncServing(
            connection: LinkedConnection(
                isLinked: true,
                providerName: "SimpleFIN",
                needsReauth: false,
                lastSuccessfulSyncAt: .now
            )
        )
        let accounts = MockAccountRepository(accounts: [account])
        let vm = AccountsViewModel(
            connectionLifecycle: MockConnectionLifecycle(),
            syncServing: sync,
            accountRepository: accounts,
            accountDuplicateRepair: RepairDuplicateAccountUseCase(repairing: MockAccountDuplicateRepair()),
            useLargeDemoSeed: false
        )

        await vm.refreshStatus()

        #expect(vm.hasAccountSyncIssues)
        #expect(vm.connectionStatusLabel == "Needs attention")
        #expect(vm.showsReconnectAction)
        #expect(vm.syncDisplay(for: account) == .issue("Authentication failed for Chase"))
    }

    @Test("Healthy linked accounts stay Linked without reconnect")
    func healthyStaysLinked() async {
        let account = Account(
            id: AccountID("a1"),
            externalID: "ext-1",
            name: "Checking",
            institutionName: "Chase",
            currencyCode: "USD",
            balance: 10,
            balanceDate: .now
        )
        let sync = MockAccountsSyncServing(
            connection: LinkedConnection(
                isLinked: true,
                providerName: "SimpleFIN",
                needsReauth: false,
                lastSuccessfulSyncAt: .now
            )
        )
        let vm = AccountsViewModel(
            connectionLifecycle: MockConnectionLifecycle(),
            syncServing: sync,
            accountRepository: MockAccountRepository(accounts: [account]),
            accountDuplicateRepair: RepairDuplicateAccountUseCase(repairing: MockAccountDuplicateRepair()),
            useLargeDemoSeed: false
        )

        await vm.refreshStatus()

        #expect(!vm.hasAccountSyncIssues)
        #expect(vm.connectionStatusLabel == "Linked")
        #expect(!vm.showsReconnectAction)
        #expect(vm.syncDisplay(for: account) == .healthy)
    }

    @Test("Two current bank accounts can be repaired")
    func twoCurrentAccountsOfferRepair() async {
        let accounts = [
            Account(
                id: AccountID("a1"),
                externalID: "ext-1",
                name: "Checking",
                institutionName: "Chase",
                currencyCode: "USD",
                balance: 10,
                balanceDate: .now,
                providerState: .current
            ),
            Account(
                id: AccountID("a2"),
                externalID: "ext-2",
                name: "Checking",
                institutionName: "Chase",
                currencyCode: "USD",
                balance: 20,
                balanceDate: .now,
                providerState: .current
            ),
        ]
        let vm = AccountsViewModel(
            connectionLifecycle: MockConnectionLifecycle(),
            syncServing: MockAccountsSyncServing(
                connection: LinkedConnection(
                    isLinked: true,
                    providerName: "SimpleFIN",
                    lastSuccessfulSyncAt: .now
                )
            ),
            accountRepository: MockAccountRepository(accounts: accounts),
            accountDuplicateRepair: RepairDuplicateAccountUseCase(repairing: MockAccountDuplicateRepair()),
            useLargeDemoSeed: false
        )
        await vm.refreshStatus()
        #expect(vm.canRepairDuplicates)
        #expect(!vm.mergeLikelyDuplicates)
    }

    @Test("Historical accounts tell the user to swipe to repair")
    func historicalOffersSwipeToRepair() async {
        let historical = Account(
            id: AccountID("old"),
            externalID: "ext-old",
            name: "Checking",
            institutionName: "Chase",
            currencyCode: "USD",
            balance: 10,
            balanceDate: .now,
            providerState: .historical
        )
        let current = Account(
            id: AccountID("new"),
            externalID: "ext-new",
            name: "Checking",
            institutionName: "Chase",
            currencyCode: "USD",
            balance: 20,
            balanceDate: .now,
            providerState: .current
        )
        let vm = AccountsViewModel(
            connectionLifecycle: MockConnectionLifecycle(),
            syncServing: MockAccountsSyncServing(
                connection: LinkedConnection(
                    isLinked: true,
                    providerName: "SimpleFIN",
                    lastSuccessfulSyncAt: .now
                )
            ),
            accountRepository: MockAccountRepository(accounts: [historical, current]),
            accountDuplicateRepair: RepairDuplicateAccountUseCase(repairing: MockAccountDuplicateRepair()),
            useLargeDemoSeed: false
        )
        await vm.refreshStatus()
        #expect(vm.syncDisplay(for: historical) == .issue("Swipe to repair duplicate"))
        #expect(vm.syncDisplay(for: current) == .healthy)
        #expect(vm.canKeepLocally(historical))
        #expect(!vm.canKeepLocally(current))
    }

    @Test("Keep locally clears the duplicate warning")
    func keepLocallyClearsWarning() async throws {
        let historical = Account(
            id: AccountID("old"),
            externalID: "ext-old",
            name: "Checking",
            institutionName: "Chase",
            currencyCode: "USD",
            balance: 10,
            balanceDate: .now,
            providerState: .historical
        )
        let current = Account(
            id: AccountID("new"),
            externalID: "ext-new",
            name: "Checking",
            institutionName: "Chase",
            currencyCode: "USD",
            balance: 20,
            balanceDate: .now,
            providerState: .current
        )
        let accounts = MockAccountRepository(accounts: [historical, current])
        let vm = AccountsViewModel(
            connectionLifecycle: MockConnectionLifecycle(),
            syncServing: MockAccountsSyncServing(
                connection: LinkedConnection(
                    isLinked: true,
                    providerName: "SimpleFIN",
                    lastSuccessfulSyncAt: .now
                )
            ),
            accountRepository: accounts,
            accountDuplicateRepair: RepairDuplicateAccountUseCase(repairing: MockAccountDuplicateRepair()),
            useLargeDemoSeed: false
        )
        await vm.refreshStatus()
        await vm.keepLocally(historical)

        let kept = try #require(vm.accounts.first { $0.id == historical.id })
        #expect(kept.providerState == .keptLocally)
        #expect(vm.syncDisplay(for: kept) == .quiet("Kept locally"))
        #expect(!vm.canKeepLocally(kept))
        #expect(vm.statusBanner == "Kept locally. It won't sync from SimpleFIN.")
    }
}

private struct MockAccountsSyncServing: SyncServing {
    let connection: LinkedConnection

    func syncNow() async throws -> LinkedConnection { connection }
    func connectionStatus() async -> LinkedConnection { connection }
}

private struct MockConnectionLifecycle: ConnectionLifecycleServing {
    func replaceAndLink(
        withSetupToken token: String,
        deleteLocalData: Bool,
        preservingLinkNamespace: Bool
    ) async throws -> LinkedConnection {
        LinkedConnection(isLinked: true, providerName: "SimpleFIN")
    }

    func disconnect(deleteLocalData: Bool) async throws -> LinkedConnection {
        LinkedConnection(isLinked: false, providerName: "None")
    }

    func resetLocalDataKeepingLink() async throws -> LinkedConnection {
        LinkedConnection(isLinked: true, providerName: "SimpleFIN")
    }

    func eraseEverything() async throws {}
}

private final class MockAccountRepository: AccountRepository, @unchecked Sendable {
    var accounts: [Account]

    init(accounts: [Account]) {
        self.accounts = accounts
    }

    func fetchAll() async throws -> [Account] { accounts }
    func updateName(accountID: AccountID, name: String) async throws {}
    func keepLocally(accountID: AccountID) async throws {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw CashFlowError.persistence(message: "Account not found.")
        }
        let account = accounts[index]
        guard account.providerState == .historical || account.providerState == .keptLocally else {
            throw CashFlowError.persistence(
                message: "Only accounts missing from the latest sync can be kept locally."
            )
        }
        accounts[index] = Account(
            id: account.id,
            externalID: account.externalID,
            name: account.name,
            institutionName: account.institutionName,
            currencyCode: account.currencyCode,
            balance: account.balance,
            balanceDate: account.balanceDate,
            syncIssue: account.syncIssue,
            source: account.source,
            providerState: .keptLocally,
            providerLastSeenAt: account.providerLastSeenAt,
            createdAt: account.createdAt,
            rawProviderName: account.rawProviderName
        )
    }
    func create(
        name: String,
        institutionName: String,
        currencyCode: String,
        createdByImportBatchID: ImportBatchID?
    ) async throws -> Account {
        Account(
            id: AccountID(UUID().uuidString),
            externalID: "csv:test",
            name: name,
            institutionName: institutionName,
            currencyCode: currencyCode,
            balance: 0,
            balanceDate: .now
        )
    }
}

private struct MockAccountDuplicateRepair: AccountDuplicateRepairing {
    func currentProviderCandidates(retaining accountID: AccountID) async throws -> [Account] { [] }
    func preview(
        retaining accountID: AccountID,
        adoptingProviderIdentityFrom providerAccountID: AccountID,
        mergeLikelyDuplicates: Bool
    ) async throws -> DuplicateAccountRepairPreview {
        throw CashFlowError.persistence(message: "not used")
    }
    func repair(_ command: DuplicateAccountRepairCommand) async throws -> DuplicateAccountRepairResult {
        throw CashFlowError.persistence(message: "not used")
    }
}
