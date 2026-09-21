import Foundation
import CashFlowKit
@preconcurrency import SwiftData

/// Current SwiftData schema (V3).
///
/// - Prefer **additive** fields with property defaults. Breaking shape changes require
///   distinct model types + a real `MigrationStage` — do not treat wipe as the happy path
///   after this release.
/// - V3 ships with one explicit one-time ledger reset (credentials preserved in Keychain).
/// - Portable backup uses a separate JSON `formatVersion` (`LocalDataExportDocument`).
public enum CashFlowSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [
            AccountEntity.self,
            TransactionEntity.self,
            ConnectionEntity.self,
            CategorizationRuleEntity.self,
            TagEntity.self,
            MerchantParseMemoEntity.self,
            ImportBatchEntity.self,
        ]
    }
}

/// Backward-compatible aliases used by older call sites / docs.
public typealias CashFlowSchemaV2 = CashFlowSchemaV3
public typealias CashFlowSchemaV1 = CashFlowSchemaV3

public enum CashFlowMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [CashFlowSchemaV3.self]
    }

    public static var stages: [MigrationStage] { [] }
}

@Model
public final class AccountEntity {
    @Attribute(.unique) public var id: String
    /// Canonical length-prefixed provider identity key.
    @Attribute(.unique) public var identityKey: String
    /// Legacy alias kept for gradual call-site migration; mirrors `identityKey`.
    public var externalID: String
    public var sourceRaw: String = ProviderSource.simpleFIN.rawValue
    public var linkNamespace: String = ""
    public var providerConnectionID: String?
    public var providerAccountID: String?
    public var providerOrganizationID: String?
    public var rawProviderName: String?
    public var name: String
    public var institutionName: String
    public var currencyCode: String
    public var balance: Decimal
    public var balanceDate: Date
    /// When true, sync keeps local `name` and does not apply SimpleFIN's account name.
    public var userEditedName: Bool = false
    /// Last provider sync issue for this account; `nil` means healthy.
    public var syncIssue: String?
    /// Set when this account was created by a CSV import batch.
    public var createdByImportBatchID: String? = nil
    public var createdAt: Date = Date()
    public var providerLastSeenAt: Date?
    public var providerStateRaw: String = AccountProviderState.current.rawValue

    @Relationship(deleteRule: .cascade, inverse: \TransactionEntity.account)
    public var transactions: [TransactionEntity] = []

    public init(
        id: String,
        identityKey: String,
        source: ProviderSource,
        linkNamespace: String,
        providerConnectionID: String? = nil,
        providerAccountID: String? = nil,
        providerOrganizationID: String? = nil,
        rawProviderName: String? = nil,
        name: String,
        institutionName: String,
        currencyCode: String,
        balance: Decimal,
        balanceDate: Date,
        userEditedName: Bool = false,
        syncIssue: String? = nil,
        createdByImportBatchID: String? = nil,
        createdAt: Date = .now,
        providerLastSeenAt: Date? = nil,
        providerState: AccountProviderState = .current
    ) {
        self.id = id
        self.identityKey = identityKey
        self.externalID = identityKey
        self.sourceRaw = source.rawValue
        self.linkNamespace = linkNamespace
        self.providerConnectionID = providerConnectionID
        self.providerAccountID = providerAccountID
        self.providerOrganizationID = providerOrganizationID
        self.rawProviderName = rawProviderName
        self.name = name
        self.institutionName = institutionName
        self.currencyCode = currencyCode
        self.balance = balance
        self.balanceDate = balanceDate
        self.userEditedName = userEditedName
        self.syncIssue = syncIssue
        self.createdByImportBatchID = createdByImportBatchID
        self.createdAt = createdAt
        self.providerLastSeenAt = providerLastSeenAt
        self.providerStateRaw = providerState.rawValue
        self.transactions = []
    }

    /// Compatibility initializer used by older tests / seeders.
    public convenience init(
        id: String,
        externalID: String,
        name: String,
        institutionName: String,
        currencyCode: String,
        balance: Decimal,
        balanceDate: Date,
        userEditedName: Bool = false,
        connectionExternalID: String? = nil,
        syncIssue: String? = nil,
        createdByImportBatchID: String? = nil
    ) {
        let source: ProviderSource = {
            if createdByImportBatchID != nil || externalID.hasPrefix("csv:") {
                return .csvImport
            }
            if externalID.hasPrefix("demo-") || externalID.contains("demo") {
                return .demo
            }
            return .simpleFIN
        }()
        let namespace = createdByImportBatchID != nil ? id : "legacy"
        self.init(
            id: id,
            identityKey: externalID,
            source: source,
            linkNamespace: namespace,
            providerConnectionID: connectionExternalID,
            providerAccountID: externalID,
            name: name,
            institutionName: institutionName,
            currencyCode: currencyCode,
            balance: balance,
            balanceDate: balanceDate,
            userEditedName: userEditedName,
            syncIssue: syncIssue,
            createdByImportBatchID: createdByImportBatchID
        )
    }

    public var source: ProviderSource {
        ProviderSource(rawValue: sourceRaw) ?? .simpleFIN
    }

    public var providerState: AccountProviderState {
        get { AccountProviderState(rawValue: providerStateRaw) ?? .unknown }
        set { providerStateRaw = newValue.rawValue }
    }

    /// Compatibility for call sites that still read `connectionExternalID`.
    public var connectionExternalID: String? {
        get { providerConnectionID }
        set { providerConnectionID = newValue }
    }
}

@Model
public final class TransactionEntity {
    @Attribute(.unique) public var id: String
    public var externalID: String
    /// Denormalized local account id so mapping does not depend on relationship faults.
    public var accountID: String = ""
    public var amount: Decimal
    public var postedDate: Date
    public var transactionDescription: String
    public var categoryID: String
    public var currencyCode: String
    public var userEditedCategory: Bool
    public var isPending: Bool
    /// When true, user categorization rules never change this row’s category.
    public var categoryLocked: Bool = false
    /// Local-only merchant title from on-device enrichment; sync never invents this.
    public var enrichedTitle: String?
    /// Local-only location from on-device enrichment; sync never invents this.
    public var enrichedLocation: String?
    /// `TitleSource.rawValue` for the enrichment fields; nil when no enrichment is present.
    public var titleSourceRaw: String? = nil
    /// `CategorySource.rawValue` for who authored `categoryID`; nil when unprocessed / legacy.
    public var categorySourceRaw: String? = nil
    /// JSON-encoded `[TagID]` the user removed; rules must not re-add these.
    public var suppressedTagIDsData: Data? = nil
    /// `IngestSource.rawValue` — defaults to bank link for migrated rows.
    public var ingestSourceRaw: String = IngestSource.bankLink.rawValue
    /// CSV import batch id when `ingestSource` is csvImport.
    public var importBatchID: String? = nil
    /// Canonical identity: source + local account UUID + provider transaction id.
    @Attribute(.unique) public var identityKey: String
    /// Legacy alias mirroring `identityKey` for gradual call-site migration.
    public var syncKey: String

    public var account: AccountEntity?

    /// Local-only tags; sync upserts never clear this relationship.
    @Relationship(inverse: \TagEntity.transactions)
    public var tags: [TagEntity] = []

    public init(
        id: String,
        externalID: String,
        accountID: String,
        amount: Decimal,
        postedDate: Date,
        transactionDescription: String,
        categoryID: String,
        currencyCode: String,
        userEditedCategory: Bool,
        isPending: Bool,
        identityKey: String,
        account: AccountEntity?,
        categoryLocked: Bool = false,
        enrichedTitle: String? = nil,
        enrichedLocation: String? = nil,
        titleSourceRaw: String? = nil,
        categorySourceRaw: String? = nil,
        suppressedTagIDsData: Data? = nil,
        ingestSourceRaw: String = IngestSource.bankLink.rawValue,
        importBatchID: String? = nil
    ) {
        self.id = id
        self.externalID = externalID
        self.accountID = accountID
        self.amount = amount
        self.postedDate = postedDate
        self.transactionDescription = transactionDescription
        self.categoryID = categoryID
        self.currencyCode = currencyCode
        self.userEditedCategory = userEditedCategory
        self.isPending = isPending
        self.identityKey = identityKey
        self.syncKey = identityKey
        self.account = account
        self.categoryLocked = categoryLocked
        self.enrichedTitle = enrichedTitle
        self.enrichedLocation = enrichedLocation
        self.titleSourceRaw = titleSourceRaw
        self.categorySourceRaw = categorySourceRaw
        self.suppressedTagIDsData = suppressedTagIDsData
        self.ingestSourceRaw = ingestSourceRaw
        self.importBatchID = importBatchID
        self.tags = []
    }

    /// Compatibility initializer accepting legacy `syncKey`.
    public convenience init(
        id: String,
        externalID: String,
        accountID: String,
        amount: Decimal,
        postedDate: Date,
        transactionDescription: String,
        categoryID: String,
        currencyCode: String,
        userEditedCategory: Bool,
        isPending: Bool,
        syncKey: String,
        account: AccountEntity?,
        categoryLocked: Bool = false,
        enrichedTitle: String? = nil,
        enrichedLocation: String? = nil,
        titleSourceRaw: String? = nil,
        categorySourceRaw: String? = nil,
        suppressedTagIDsData: Data? = nil,
        ingestSourceRaw: String = IngestSource.bankLink.rawValue,
        importBatchID: String? = nil
    ) {
        self.init(
            id: id,
            externalID: externalID,
            accountID: accountID,
            amount: amount,
            postedDate: postedDate,
            transactionDescription: transactionDescription,
            categoryID: categoryID,
            currencyCode: currencyCode,
            userEditedCategory: userEditedCategory,
            isPending: isPending,
            identityKey: syncKey,
            account: account,
            categoryLocked: categoryLocked,
            enrichedTitle: enrichedTitle,
            enrichedLocation: enrichedLocation,
            titleSourceRaw: titleSourceRaw,
            categorySourceRaw: categorySourceRaw,
            suppressedTagIDsData: suppressedTagIDsData,
            ingestSourceRaw: ingestSourceRaw,
            importBatchID: importBatchID
        )
    }
}

@Model
public final class ConnectionEntity {
    @Attribute(.unique) public var id: String
    public var providerName: String
    public var needsReauth: Bool
    public var lastSuccessfulSyncAt: Date?
    public var isDemo: Bool = false
    public var sourceRaw: String = ProviderSource.simpleFIN.rawValue
    public var linkNamespace: String? = nil
    public var inventoryCompletenessRaw: String = RemoteInventoryCompleteness.incomplete.rawValue
    public var lastSyncIssuesData: Data? = nil
    /// Oldest posted date the provider has been asked for so far; nil before the first sync.
    public var earliestFetchedDate: Date? = nil
    /// `HistoryLookbackYears.rawValue` the user asked us to import.
    public var lookbackYearsRaw: Int = 2
    /// True once the backward walk reached the target start date or the bank ran dry.
    public var historyComplete: Bool = false
    /// Last time the backward walk actually moved `earliestFetchedDate` older.
    public var lastBackfillAdvanceAt: Date? = nil
    /// Legacy flag kept for lightweight migration from stores that still have the column.
    public var historyBackfillComplete: Bool = false

    public init(
        id: String = "primary",
        providerName: String,
        needsReauth: Bool = false,
        lastSuccessfulSyncAt: Date? = nil,
        isDemo: Bool = false,
        source: ProviderSource = .simpleFIN,
        linkNamespace: String? = nil,
        inventoryCompleteness: RemoteInventoryCompleteness = .incomplete,
        earliestFetchedDate: Date? = nil,
        lookbackYearsRaw: Int = 2,
        historyComplete: Bool = false,
        lastBackfillAdvanceAt: Date? = nil,
        historyBackfillComplete: Bool = false
    ) {
        self.id = id
        self.providerName = providerName
        self.needsReauth = needsReauth
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.isDemo = isDemo
        self.sourceRaw = source.rawValue
        self.linkNamespace = linkNamespace
        self.inventoryCompletenessRaw = inventoryCompleteness.rawValue
        self.earliestFetchedDate = earliestFetchedDate
        self.lookbackYearsRaw = lookbackYearsRaw
        self.historyComplete = historyComplete
        self.lastBackfillAdvanceAt = lastBackfillAdvanceAt
        self.historyBackfillComplete = historyBackfillComplete
    }

    public var lookback: HistoryLookbackYears {
        HistoryLookbackYears(rawValue: lookbackYearsRaw) ?? .default
    }

    public var source: ProviderSource {
        get { ProviderSource(rawValue: sourceRaw) ?? (isDemo ? .demo : .simpleFIN) }
        set { sourceRaw = newValue.rawValue }
    }

    public var inventoryCompleteness: RemoteInventoryCompleteness {
        get { RemoteInventoryCompleteness(rawValue: inventoryCompletenessRaw) ?? .incomplete }
        set { inventoryCompletenessRaw = newValue.rawValue }
    }
}

@Model
public final class CategorizationRuleEntity {
    @Attribute(.unique) public var id: String
    public var categoryID: String
    public var priority: Int
    public var isEnabled: Bool = true
    /// JSON-encoded `[CategorizationCondition]`.
    public var conditionsData: Data
    /// Optional merchant title applied when the rule matches.
    public var renameTitle: String? = nil
    /// Optional location applied when the rule matches.
    public var renameLocation: String? = nil
    /// When false, matching only renames / tags; category is left alone.
    public var appliesCategory: Bool = true
    /// JSON-encoded `[TagID]` added when the rule matches.
    public var tagIDsData: Data? = nil
    /// True when the assistant created this rule.
    public var createdByAssistant: Bool = false
    /// JSON-encoded `CategorizationRuleApplySnapshot` from the last apply.
    public var applySnapshotData: Data? = nil

    public init(
        id: String,
        categoryID: String,
        priority: Int,
        isEnabled: Bool = true,
        conditionsData: Data,
        renameTitle: String? = nil,
        renameLocation: String? = nil,
        appliesCategory: Bool = true,
        tagIDsData: Data? = nil,
        createdByAssistant: Bool = false,
        applySnapshotData: Data? = nil
    ) {
        self.id = id
        self.categoryID = categoryID
        self.priority = priority
        self.isEnabled = isEnabled
        self.conditionsData = conditionsData
        self.renameTitle = renameTitle
        self.renameLocation = renameLocation
        self.appliesCategory = appliesCategory
        self.tagIDsData = tagIDsData
        self.createdByAssistant = createdByAssistant
        self.applySnapshotData = applySnapshotData
    }
}

@Model
public final class TagEntity {
    @Attribute(.unique) public var id: String
    public var name: String
    public var createdAt: Date
    public var transactions: [TransactionEntity] = []

    public init(id: String, name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.transactions = []
    }
}

/// Memoized LLM parse keyed by normalized bank description.
@Model
public final class MerchantParseMemoEntity {
    @Attribute(.unique) public var normalizedKey: String
    public var title: String
    public var location: String?
    public var version: Int = 1
    public var createdAt: Date = Date()

    public init(
        normalizedKey: String,
        title: String,
        location: String? = nil,
        version: Int = 1,
        createdAt: Date = .now
    ) {
        self.normalizedKey = normalizedKey
        self.title = title
        self.location = location
        self.version = version
        self.createdAt = createdAt
    }
}

/// Durable CSV import history (active + deleted tombstones).
@Model
public final class ImportBatchEntity {
    @Attribute(.unique) public var id: String
    public var fileName: String
    public var importedAt: Date
    public var accountID: String
    public var accountName: String
    public var createdAccount: Bool
    public var createdAccountID: String?
    public var insertedCount: Int
    public var skippedCount: Int
    public var replacedCount: Int
    public var keepBothCount: Int = 0
    /// `ImportBatchStatus.rawValue`
    public var statusRaw: String
    public var deletedAt: Date?

    public init(
        id: String,
        fileName: String,
        importedAt: Date,
        accountID: String,
        accountName: String,
        createdAccount: Bool,
        createdAccountID: String? = nil,
        insertedCount: Int,
        skippedCount: Int,
        replacedCount: Int,
        keepBothCount: Int = 0,
        statusRaw: String = ImportBatchStatus.active.rawValue,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.importedAt = importedAt
        self.accountID = accountID
        self.accountName = accountName
        self.createdAccount = createdAccount
        self.createdAccountID = createdAccountID
        self.insertedCount = insertedCount
        self.skippedCount = skippedCount
        self.replacedCount = replacedCount
        self.keepBothCount = keepBothCount
        self.statusRaw = statusRaw
        self.deletedAt = deletedAt
    }
}
