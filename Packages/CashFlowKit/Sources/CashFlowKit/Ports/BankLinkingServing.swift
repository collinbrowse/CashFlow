import Foundation

public struct LinkedConnection: Sendable, Equatable {
    public let isLinked: Bool
    public let providerName: String
    public let needsReauth: Bool
    public let lastSuccessfulSyncAt: Date?
    public let providerMessages: [String]
    public let linkNamespace: String?

    public init(
        isLinked: Bool,
        providerName: String,
        needsReauth: Bool = false,
        lastSuccessfulSyncAt: Date? = nil,
        providerMessages: [String] = [],
        linkNamespace: String? = nil
    ) {
        self.isLinked = isLinked
        self.providerName = providerName
        self.needsReauth = needsReauth
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.providerMessages = providerMessages
        self.linkNamespace = linkNamespace
    }
}

public struct RemoteAccountSnapshot: Sendable, Equatable {
    public let identity: RemoteAccountIdentity
    public let name: String
    /// Raw provider account name before any local rename.
    public let providerName: String
    public let institutionName: String
    public let organization: RemoteOrganization?
    public let currencyCode: String
    public let balance: Decimal
    public let balanceDate: Date
    public let transactions: [RemoteTransactionSnapshot]
    public let transactionCompleteness: RemoteTransactionCompleteness
    /// Provider error for this account from the latest fetch, if any.
    public let syncIssue: String?
    public let issues: [RemoteProviderIssue]

    public init(
        identity: RemoteAccountIdentity,
        name: String,
        providerName: String? = nil,
        institutionName: String,
        organization: RemoteOrganization? = nil,
        currencyCode: String,
        balance: Decimal,
        balanceDate: Date,
        transactions: [RemoteTransactionSnapshot],
        transactionCompleteness: RemoteTransactionCompleteness = .authoritative,
        syncIssue: String? = nil,
        issues: [RemoteProviderIssue] = []
    ) {
        self.identity = identity
        self.name = name
        self.providerName = providerName ?? name
        self.institutionName = institutionName
        self.organization = organization
        self.currencyCode = currencyCode
        self.balance = balance
        self.balanceDate = balanceDate
        self.transactions = transactions
        self.transactionCompleteness = transactionCompleteness
        self.syncIssue = syncIssue
        self.issues = issues
    }

    /// Canonical identity key for upsert / uniqueness.
    public var identityKey: String { identity.identityKey }

    /// Convenience for call sites that previously used `externalID`.
    public var externalID: String { identityKey }
}

public struct RemoteTransactionSnapshot: Sendable, Equatable {
    public let externalID: String
    public let amount: Decimal
    public let postedDate: Date
    public let description: String
    public let isPending: Bool
    public let suggestedCategoryID: CategoryID
    /// When true (Demo fixtures), merge stores `suggestedCategoryID` as `.keyword` instead of Undefined.
    public let preferSuggestedCategory: Bool

    public init(
        externalID: String,
        amount: Decimal,
        postedDate: Date,
        description: String,
        isPending: Bool = false,
        suggestedCategoryID: CategoryID = SystemCategory.other.id,
        preferSuggestedCategory: Bool = false
    ) {
        self.externalID = externalID
        self.amount = amount
        self.postedDate = postedDate
        self.description = description
        self.isPending = isPending
        self.suggestedCategoryID = suggestedCategoryID
        self.preferSuggestedCategory = preferSuggestedCategory
    }
}

public struct RemoteSyncPayload: Sendable, Equatable {
    public let source: ProviderLinkIdentity
    public let accounts: [RemoteAccountSnapshot]
    public let connections: [RemoteProviderConnection]
    public let issues: [RemoteProviderIssue]
    public let inventoryCompleteness: RemoteInventoryCompleteness
    /// Connections whose account inventory is complete enough to archive unseen locals.
    public let authoritativeConnectionIDs: Set<String>
    /// Sanitized display strings derived from `issues` for UI banners.
    public let providerMessages: [String]

    public init(
        source: ProviderLinkIdentity,
        accounts: [RemoteAccountSnapshot],
        connections: [RemoteProviderConnection] = [],
        issues: [RemoteProviderIssue] = [],
        inventoryCompleteness: RemoteInventoryCompleteness = .complete,
        authoritativeConnectionIDs: Set<String>? = nil,
        providerMessages: [String] = []
    ) {
        self.source = source
        self.accounts = accounts
        self.connections = connections
        self.issues = issues
        self.inventoryCompleteness = inventoryCompleteness
        self.authoritativeConnectionIDs = authoritativeConnectionIDs
            ?? Self.derivedAuthoritativeConnectionIDs(
                connections: connections,
                accounts: accounts,
                issues: issues,
                inventoryCompleteness: inventoryCompleteness
            )
        self.providerMessages = providerMessages
    }

    public var hasGlobalIncompleteness: Bool {
        issues.contains { issue in
            if case .global = issue.scope { return true }
            return false
        }
    }

    public static func derivedAuthoritativeConnectionIDs(
        connections: [RemoteProviderConnection],
        accounts: [RemoteAccountSnapshot],
        issues: [RemoteProviderIssue],
        inventoryCompleteness: RemoteInventoryCompleteness
    ) -> Set<String> {
        if issues.contains(where: { if case .global = $0.scope { return true }; return false }) {
            return []
        }
        var ids = Set(connections.map(\.id))
        ids.formUnion(accounts.map(\.identity.connectionID))
        for issue in issues {
            if case .connection(let connID) = issue.scope {
                ids.remove(connID)
            }
        }
        if inventoryCompleteness == .incomplete, connections.isEmpty, accounts.isEmpty {
            return []
        }
        return ids
    }
}

public protocol BankLinkingServing: Sendable {
    var providerName: String { get }

    func connectionStatus() async -> LinkedConnection

    /// Claim a SimpleFIN setup token (base64) or enable demo mode.
    /// Returns a secret-free receipt that must be persisted before the first sync.
    /// Pass `preservingLinkNamespace` on reconnect so existing local identities keep matching.
    @discardableResult
    func link(
        withSetupToken token: String,
        preservingLinkNamespace: String?
    ) async throws -> BankLinkReceipt

    func unlink(removeLocalData: Bool) async throws

    func fetchAccounts(
        startDate: Date?,
        endDate: Date?
    ) async throws -> RemoteSyncPayload
}

extension BankLinkingServing {
    @discardableResult
    public func link(withSetupToken token: String) async throws -> BankLinkReceipt {
        try await link(withSetupToken: token, preservingLinkNamespace: nil)
    }
}

public protocol SyncServing: Sendable {
    func syncNow() async throws -> LinkedConnection
    func connectionStatus() async -> LinkedConnection

    /// Live sync progress. Yields the latest value on subscribe when a sync is in flight;
    /// yields `nil` when idle. Overlapping `syncNow` callers share one sync and one stream.
    func syncProgressUpdates() -> AsyncStream<SyncProgress?>

    /// Consumes a one-shot enrichment prompt produced after a large first sync.
    func consumePendingEnrichmentPrompt() async -> EnrichmentWorkEstimate?

    /// Durable multi-day history + title cleanup status for Settings.
    func historyImportStatus() async -> HistoryImportStatus?

    /// Updates the stored lookback target; deeper targets re-open backward walk only.
    func setHistoryLookback(_ lookback: HistoryLookbackYears) async throws
}

extension SyncServing {
    public func syncProgressUpdates() -> AsyncStream<SyncProgress?> {
        AsyncStream { continuation in
            continuation.yield(nil)
            continuation.finish()
        }
    }

    public func consumePendingEnrichmentPrompt() async -> EnrichmentWorkEstimate? { nil }

    public func historyImportStatus() async -> HistoryImportStatus? { nil }

    public func setHistoryLookback(_ lookback: HistoryLookbackYears) async throws {}
}
