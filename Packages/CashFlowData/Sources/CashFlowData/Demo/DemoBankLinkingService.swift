import Foundation
import CashFlowKit

/// Deterministic fake bank data for portfolio screenshots, CI, and large-list perf.
public actor DemoBankLinkingService: BankLinkingServing {
    public let providerName = "Demo"
    public static let linkNamespace = "demo"

    public enum SeedSize: Sendable {
        case standard
        case large // 10k+ transactions

        var transactionCount: Int {
            switch self {
            case .standard: 120
            case .large: 10_500
            }
        }
    }

    private var isLinked = false
    private let seedSize: SeedSize
    private let clock: Date

    public init(seedSize: SeedSize = .standard, clock: Date = .now) {
        self.seedSize = seedSize
        self.clock = clock
    }

    public func connectionStatus() async -> LinkedConnection {
        LinkedConnection(
            isLinked: isLinked,
            providerName: providerName,
            needsReauth: false,
            lastSuccessfulSyncAt: isLinked ? clock : nil,
            linkNamespace: isLinked ? Self.linkNamespace : nil
        )
    }

    @discardableResult
    public func link(
        withSetupToken token: String,
        preservingLinkNamespace: String?
    ) async throws -> BankLinkReceipt {
        _ = token
        _ = preservingLinkNamespace
        isLinked = true
        return BankLinkReceipt(
            link: ProviderLinkIdentity(source: .demo, linkNamespace: Self.linkNamespace),
            providerName: providerName
        )
    }

    public func unlink(removeLocalData: Bool) async throws {
        _ = removeLocalData
        isLinked = false
    }

    /// Used when durable `ConnectionEntity.isDemo` restores Demo mode after relaunch.
    public func adoptLinkedState(_ linked: Bool) {
        isLinked = linked
    }

    public func fetchAccounts(
        startDate: Date?,
        endDate: Date?
    ) async throws -> RemoteSyncPayload {
        try await fetchAccounts(startDate: startDate, endDate: endDate, onWindowProgress: nil)
    }

    public func fetchAccounts(
        startDate: Date?,
        endDate: Date?,
        onWindowProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async throws -> RemoteSyncPayload {
        guard isLinked else { throw CashFlowError.notLinked }
        onWindowProgress?(0, 1)
        let accounts = Self.makeAccounts(
            count: seedSize.transactionCount,
            now: clock,
            startDate: startDate,
            endDate: endDate
        )
        onWindowProgress?(1, 1)
        return RemoteSyncPayload(
            source: ProviderLinkIdentity(source: .demo, linkNamespace: Self.linkNamespace),
            accounts: accounts,
            inventoryCompleteness: .complete
        )
    }

    public static func makeAccounts(
        count: Int,
        now: Date,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) -> [RemoteAccountSnapshot] {
        let link = ProviderLinkIdentity(source: .demo, linkNamespace: linkNamespace)
        let checkingID = "demo-checking"
        let cardID = "demo-card"
        var checkingTx: [RemoteTransactionSnapshot] = []
        var cardTx: [RemoteTransactionSnapshot] = []
        checkingTx.reserveCapacity(count / 2 + 10)
        cardTx.reserveCapacity(count / 2 + 10)

        let calendar = Calendar.current
        let merchants = [
            ("Whole Foods", SystemCategory.groceries, Decimal(-64.23)),
            ("Uber Trip", SystemCategory.transport, Decimal(-18.40)),
            ("Transfer to Savings", SystemCategory.transfer, Decimal(-500)),
            ("Credit Card Payment", SystemCategory.creditCardPayment, Decimal(-1200)),
            ("Hidden Adjustment", SystemCategory.hidden, Decimal(-99)),
            ("Netflix", SystemCategory.entertainment, Decimal(-15.99)),
            ("Shell Gas", SystemCategory.transport, Decimal(-42.10)),
            ("Trader Joe's", SystemCategory.groceries, Decimal(-87.55)),
            ("Amazon", SystemCategory.shopping, Decimal(-35.00)),
            ("Coffee Shop", SystemCategory.dining, Decimal(-6.50)),
        ]

        let paycheckDaysAgo = 7
        let paycheckDate = calendar.date(byAdding: .day, value: -paycheckDaysAgo, to: now) ?? now
        if startDate.map({ paycheckDate >= $0 }) ?? true,
           endDate.map({ paycheckDate <= $0 }) ?? true
        {
            checkingTx.append(
                RemoteTransactionSnapshot(
                    externalID: "demo-tx-paycheck",
                    amount: 3_200,
                    postedDate: paycheckDate,
                    description: "Payroll ACME Corp",
                    isPending: false,
                    suggestedCategoryID: SystemCategory.income.id,
                    preferSuggestedCategory: true
                )
            )
        }

        for index in 0..<count {
            let daysAgo: Int
            if index < 60 {
                daysAgo = index
            } else {
                daysAgo = 60 + ((index - 60) % 340)
            }
            if daysAgo == paycheckDaysAgo { continue }

            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            if let startDate, date < startDate { continue }
            if let endDate, date > endDate { continue }

            let template = merchants[index % merchants.count]
            let snapshot = RemoteTransactionSnapshot(
                externalID: "demo-tx-\(index)",
                amount: template.2,
                postedDate: date,
                description: template.0,
                isPending: false,
                suggestedCategoryID: template.1.id,
                preferSuggestedCategory: true
            )
            if index % 3 != 0 {
                checkingTx.append(snapshot)
            } else {
                cardTx.append(snapshot)
            }
        }

        return [
            RemoteAccountSnapshot(
                identity: RemoteAccountIdentity(
                    link: link,
                    connectionID: "demo-conn",
                    accountID: checkingID
                ),
                name: "Everyday Checking",
                institutionName: "Demo Bank",
                currencyCode: "USD",
                balance: 4_250.55,
                balanceDate: now,
                transactions: checkingTx,
                transactionCompleteness: .authoritative
            ),
            RemoteAccountSnapshot(
                identity: RemoteAccountIdentity(
                    link: link,
                    connectionID: "demo-conn",
                    accountID: cardID
                ),
                name: "Rewards Card",
                institutionName: "Demo Bank",
                currencyCode: "USD",
                balance: -890.12,
                balanceDate: now,
                transactions: cardTx,
                transactionCompleteness: .authoritative
            ),
        ]
    }
}
