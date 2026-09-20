import Foundation

/// Keyset list + Home/Insights range fetches.
public protocol TransactionListing: Sendable {
    func fetchPage(
        filter: TransactionFilter,
        cursor: TransactionCursor?,
        limit: Int
    ) async throws -> TransactionPage

    /// Walks the keyset until exhausted — for CSV export and other full-filter reads.
    /// Default implementation pages via `fetchPage`.
    func fetchAllMatching(filter: TransactionFilter) async throws -> [Transaction]

    func fetchPosted(
        in range: CashFlowDateRange,
        now: Date
    ) async throws -> [Transaction]

    /// Oldest non-pending posted date, if any. Used to gate long Home ranges honestly.
    func earliestPostedDate() async throws -> Date?
}

public extension TransactionListing {
    func fetchAllMatching(filter: TransactionFilter) async throws -> [Transaction] {
        var items: [Transaction] = []
        var cursor: TransactionCursor?
        while true {
            let page = try await fetchPage(
                filter: filter,
                cursor: cursor,
                limit: TransactionPageSize.default
            )
            items.append(contentsOf: page.items)
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return items
    }
}

/// Single-row edits from the transaction editor.
public protocol TransactionMutating: Sendable {
    func updateCategory(
        transactionID: TransactionID,
        categoryID: CategoryID,
        categoryLocked: Bool
    ) async throws

    /// Replaces the transaction’s local tag memberships.
    func updateTags(
        transactionID: TransactionID,
        tagIDs: [TagID]
    ) async throws

    /// Persists local-only merchant/location enrichment. Never mutates bank description.
    /// Honors `TitleSource` precedence: lower-ranked sources cannot overwrite higher.
    /// Pass `clearLocation: true` to intentionally blank location (user edit).
    func updateEnrichment(
        transactionID: TransactionID,
        title: String,
        location: String?,
        source: TitleSource,
        clearLocation: Bool
    ) async throws

    /// Marks a row as attempted-but-unparseable so it leaves the untitled backlog.
    /// Leaves `enrichedTitle` nil (UI keeps showing raw bank text).
    func markEnrichmentSkipped(transactionID: TransactionID) async throws
}

/// Store-wide categorization / assistant bulk writes. Not for list UI pagination.
public protocol TransactionBulkWriting: Sendable {
    func applyCategoryAssignments(_ assignments: [CategoryAssignment]) async throws

    func applyTagAssignments(_ assignments: [TagAssignment]) async throws

    /// Batch title/location restore for rule undo.
    func applyTitleLocationAssignments(_ assignments: [TitleLocationAssignment]) async throws

    /// Posted transactions for rule re-apply / editor hydrate. Not for list UI pagination.
    func fetchAllForCategorization() async throws -> [Transaction]
}

/// Enrichment backlog queries used by post-sync / Settings drain.
public protocol TransactionEnrichmentQuerying: Sendable {
    /// Posted Undefined rows needing an initial LLM/keyword category (newest first).
    func fetchNeedingCategorySuggestion(limit: Int) async throws -> [Transaction]

    /// Count of posted Undefined transactions still awaiting initial categorization.
    func countNeedingCategorySuggestion() async throws -> Int

    /// Posted transactions missing enrichment cache (for post-sync enrichment).
    func fetchNeedingEnrichment(limit: Int) async throws -> [Transaction]

    /// Count of posted transactions still missing a title.
    func countNeedingEnrichment() async throws -> Int

    /// Distinct normalized bank descriptions still lacking enrichment (memo-cache work units).
    func countDistinctDescriptionsNeedingEnrichment() async throws -> Int
}

/// Full transaction store surface — composition of listing, mutation, bulk, and enrichment ports.
public protocol TransactionRepository: TransactionListing, TransactionMutating, TransactionBulkWriting, TransactionEnrichmentQuerying {}

public protocol AccountRepository: Sendable {
    func fetchAll() async throws -> [Account]

    /// Persists a local display name; subsequent syncs keep it while the account still matches.
    func updateName(accountID: AccountID, name: String) async throws

    /// Marks a historical bank account as kept locally so it no longer warns as a possible duplicate.
    /// Later complete inventories leave this state alone until the provider returns the account again.
    func keepLocally(accountID: AccountID) async throws

    /// Creates a local (CSV / manual) account. `externalID` is namespaced by the implementation.
    func create(
        name: String,
        institutionName: String,
        currencyCode: String,
        createdByImportBatchID: ImportBatchID?
    ) async throws -> Account
}
