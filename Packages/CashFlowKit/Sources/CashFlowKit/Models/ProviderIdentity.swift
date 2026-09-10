import Foundation

/// Where an account or transaction identity originates.
public enum ProviderSource: String, Hashable, Sendable, Codable {
    case simpleFIN
    case demo
    case csvImport
}

/// Non-secret lineage for one claimed credential / Demo session.
public struct ProviderLinkIdentity: Hashable, Sendable, Codable {
    public let source: ProviderSource
    public let linkNamespace: String

    public init(source: ProviderSource, linkNamespace: String) {
        self.source = source
        self.linkNamespace = linkNamespace
    }
}

/// Scoped remote account identity. Display names are never part of this.
public struct RemoteAccountIdentity: Hashable, Sendable, Codable {
    public let link: ProviderLinkIdentity
    public let connectionID: String
    public let accountID: String

    public init(link: ProviderLinkIdentity, connectionID: String, accountID: String) {
        self.link = link
        self.connectionID = connectionID
        self.accountID = accountID
    }

    public var identityKey: String {
        ProviderIdentityEncoding.accountKey(
            source: link.source,
            linkNamespace: link.linkNamespace,
            connectionID: connectionID,
            accountID: accountID
        )
    }
}

public struct RemoteOrganization: Hashable, Sendable, Codable {
    public let id: String?
    public let name: String?
    public let url: String?
    public let sfinURL: String?

    public init(id: String? = nil, name: String? = nil, url: String? = nil, sfinURL: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.sfinURL = sfinURL
    }
}

public struct RemoteProviderConnection: Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let organization: RemoteOrganization

    public init(id: String, name: String, organization: RemoteOrganization) {
        self.id = id
        self.name = name
        self.organization = organization
    }
}

public enum RemoteProviderIssueScope: Hashable, Sendable, Codable {
    case global
    case connection(String)
    /// Account ids are unique only within a connection — both values are required to match.
    case account(connectionID: String, accountID: String)
}

public struct RemoteProviderIssue: Hashable, Sendable, Codable {
    public let code: String
    public let message: String
    public let scope: RemoteProviderIssueScope

    public init(code: String, message: String, scope: RemoteProviderIssueScope) {
        self.code = code
        self.message = message
        self.scope = scope
    }

    public var isAccountFailed: Bool {
        code == "act.failed" || code.hasPrefix("act.failed.")
    }

    public var isMissingData: Bool {
        code == "act.missingdata" || code.hasPrefix("act.missingdata.")
    }

    public var blocksAuthoritativeTransactions: Bool {
        isAccountFailed || isMissingData || code.hasPrefix("act.")
    }
}

/// Whether the provider inventory for a connection (or the whole payload) is complete.
public enum RemoteInventoryCompleteness: String, Hashable, Sendable, Codable {
    case complete
    case incomplete
}

/// Whether the transaction array for one account is authoritative for pending cleanup.
public enum RemoteTransactionCompleteness: String, Hashable, Sendable, Codable {
    /// Provider included a transaction array and no act.failed / act.missingdata applies.
    case authoritative
    /// Transactions were omitted or an account-level error blocks authority.
    case incomplete
}

/// Lifecycle of a local bank-linked account relative to the current credential.
public enum AccountProviderState: String, Hashable, Sendable, Codable {
    case current
    case historical
    case unknown
}

/// Secret-free result of claiming / establishing a bank link.
public struct BankLinkReceipt: Hashable, Sendable, Codable {
    public let link: ProviderLinkIdentity
    public let providerName: String

    public init(link: ProviderLinkIdentity, providerName: String) {
        self.link = link
        self.providerName = providerName
    }
}

/// Length-prefixed canonical encoding. Never uses delimiter interpolation.
public enum ProviderIdentityEncoding: Sendable {
    public static let version = "v1"

    public static func accountKey(
        source: ProviderSource,
        linkNamespace: String,
        connectionID: String,
        accountID: String
    ) -> String {
        encode([version, source.rawValue, linkNamespace, connectionID, accountID])
    }

    public static func transactionKey(
        source: ProviderSource,
        localAccountID: String,
        sourceTransactionID: String
    ) -> String {
        encode([version, source.rawValue, localAccountID, sourceTransactionID])
    }

    public static func csvAccountKey(localAccountID: String) -> String {
        encode([version, ProviderSource.csvImport.rawValue, localAccountID])
    }

    public static func demoAccountKey(linkNamespace: String, accountID: String) -> String {
        encode([version, ProviderSource.demo.rawValue, linkNamespace, "", accountID])
    }

    private static func encode(_ parts: [String]) -> String {
        parts.map { part in
            let utf8 = Array(part.utf8)
            return "\(utf8.count):\(part)"
        }.joined(separator: "|")
    }
}
