import Foundation

public struct AccountID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct Account: Identifiable, Hashable, Sendable, Codable {
    public let id: AccountID
    /// Canonical provider identity key (length-prefixed). Formerly a raw SimpleFIN account id.
    public let externalID: String
    public let name: String
    public let institutionName: String
    public let currencyCode: String
    public let balance: Decimal
    public let balanceDate: Date
    /// Provider-reported sync problem for this account, if any. `nil` means last sync was clean.
    public let syncIssue: String?
    public let source: ProviderSource
    public let providerState: AccountProviderState
    public let providerLastSeenAt: Date?
    public let createdAt: Date
    /// Raw provider account name before any local rename.
    public let rawProviderName: String?

    public init(
        id: AccountID,
        externalID: String,
        name: String,
        institutionName: String,
        currencyCode: String,
        balance: Decimal,
        balanceDate: Date,
        syncIssue: String? = nil,
        source: ProviderSource = .simpleFIN,
        providerState: AccountProviderState = .current,
        providerLastSeenAt: Date? = nil,
        createdAt: Date = .now,
        rawProviderName: String? = nil
    ) {
        self.id = id
        self.externalID = externalID
        self.name = name
        self.institutionName = institutionName
        self.currencyCode = currencyCode
        self.balance = balance
        self.balanceDate = balanceDate
        self.syncIssue = syncIssue
        self.source = source
        self.providerState = providerState
        self.providerLastSeenAt = providerLastSeenAt
        self.createdAt = createdAt
        self.rawProviderName = rawProviderName
    }

    public var hasSyncIssue: Bool {
        guard let syncIssue else { return false }
        return !syncIssue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var identityKey: String { externalID }
}
