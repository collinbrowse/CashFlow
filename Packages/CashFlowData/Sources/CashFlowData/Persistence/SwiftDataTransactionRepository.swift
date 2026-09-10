import Foundation
import SwiftData
import CashFlowKit

public actor SwiftDataTransactionRepository: TransactionRepository {
    private let modelContainer: ModelContainer
    private let scanBatchSize = 200

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    public func fetchPage(
        filter: TransactionFilter,
        cursor: TransactionCursor?,
        limit: Int
    ) async throws -> TransactionPage {
        let context = ModelContext(modelContainer)
        let pageItems = try fetchKeyset(
            context: context,
            filter: filter,
            cursor: cursor,
            limit: limit
        )
        let transactions = pageItems.map(EntityMappers.transaction(from:))
        let next: TransactionCursor?
        if transactions.count == limit, let last = transactions.last {
            next = TransactionCursor(transaction: last)
        } else {
            next = nil
        }
        return TransactionPage(items: transactions, nextCursor: next)
    }

    public func fetchPosted(in range: CashFlowDateRange, now: Date) async throws -> [Transaction] {
        let context = ModelContext(modelContainer)
        let interval = range.interval(now: now)
        // Avoid SwiftData #Predicate date-capture quirks; filter in memory after fetch.
        let descriptor = FetchDescriptor<TransactionEntity>(
            sortBy: [SortDescriptor(\.postedDate, order: .reverse)]
        )
        let entities = try context.fetch(descriptor)
        return entities
            .filter { entity in
                !entity.isPending
                    && entity.postedDate >= interval.start
                    && entity.postedDate <= interval.end
            }
            .map(EntityMappers.transaction(from:))
    }

    public func earliestPostedDate() async throws -> Date? {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<TransactionEntity>(
            predicate: #Predicate { !$0.isPending },
            sortBy: [SortDescriptor(\.postedDate, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.postedDate
    }

    public func updateCategory(
        transactionID: TransactionID,
        categoryID: CategoryID,
        categoryLocked: Bool
    ) async throws {
        let context = ModelContext(modelContainer)
        let id = transactionID.rawValue
        let predicate = #Predicate<TransactionEntity> { $0.id == id }
        var descriptor = FetchDescriptor<TransactionEntity>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else {
            throw CashFlowError.persistence(message: "Transaction not found")
        }
        entity.categoryID = categoryID.rawValue
        entity.categoryLocked = categoryLocked
        entity.categorySourceRaw = CategorySource.user.rawValue
        entity.userEditedCategory = CategorySource.user.isUserEditedCompat
        try context.save()
    }

    public func updateTags(
        transactionID: TransactionID,
        tagIDs: [TagID]
    ) async throws {
        let context = ModelContext(modelContainer)
        let id = transactionID.rawValue
        let predicate = #Predicate<TransactionEntity> { $0.id == id }
        var descriptor = FetchDescriptor<TransactionEntity>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else {
            throw CashFlowError.persistence(message: "Transaction not found")
        }
        let previous = entity.tags.map { TagID($0.id) }
        let uniqueIDs = Array(Set(tagIDs.map(\.rawValue)))
        let newTags: [TagID]
        if uniqueIDs.isEmpty {
            entity.tags = []
            newTags = []
        } else {
            let tagPredicate = #Predicate<TagEntity> { uniqueIDs.contains($0.id) }
            let tags = try context.fetch(FetchDescriptor<TagEntity>(predicate: tagPredicate))
            guard tags.count == uniqueIDs.count else {
                throw CashFlowError.persistence(message: "One or more tags were not found.")
            }
            entity.tags = tags
            newTags = tags.map { TagID($0.id) }
        }
        let existingSuppressions = EntityMappers.decodeTagIDs(entity.suppressedTagIDsData)
        let updated = ResolveTransactionCategoryUseCase.updatedSuppressions(
            previous: previous,
            new: newTags,
            existingSuppressions: existingSuppressions
        )
        entity.suppressedTagIDsData = try EntityMappers.encodeTagIDs(updated)
        try context.save()
    }

    public func applyCategoryAssignments(_ assignments: [CategoryAssignment]) async throws {
        guard !assignments.isEmpty else { return }
        let context = ModelContext(modelContainer)
        let byID = Dictionary(uniqueKeysWithValues: assignments.map {
            ($0.transactionID.rawValue, $0)
        })
        let ids = Array(byID.keys)
        let descriptor = FetchDescriptor<TransactionEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let entities = try context.fetch(descriptor)
        for entity in entities {
            guard let assignment = byID[entity.id] else { continue }
            if entity.categoryLocked { continue }
            let existing = EntityMappers.categorySource(from: entity.categorySourceRaw)
            let incoming = assignment.categorySource
                ?? (assignment.userEditedCategory ? CategorySource.user : nil)
            if let incoming,
               !CategorySource.canOverwrite(existing: existing, with: incoming)
            {
                continue
            }
            entity.categoryID = assignment.categoryID.rawValue
            entity.categorySourceRaw = EntityMappers.categorySourceRaw(from: incoming)
            entity.userEditedCategory = incoming?.isUserEditedCompat ?? false
        }
        try context.save()
    }

    public func applyTagAssignments(_ assignments: [TagAssignment]) async throws {
        guard !assignments.isEmpty else { return }
        let context = ModelContext(modelContainer)
        for assignment in assignments {
            let id = assignment.transactionID.rawValue
            let predicate = #Predicate<TransactionEntity> { $0.id == id }
            var descriptor = FetchDescriptor<TransactionEntity>(predicate: predicate)
            descriptor.fetchLimit = 1
            guard let entity = try context.fetch(descriptor).first else {
                throw CashFlowError.persistence(message: "Transaction not found")
            }
            let uniqueIDs = Array(Set(assignment.tagIDs.map(\.rawValue)))
            if uniqueIDs.isEmpty {
                entity.tags = []
            } else {
                let tagPredicate = #Predicate<TagEntity> { uniqueIDs.contains($0.id) }
                let tags = try context.fetch(FetchDescriptor<TagEntity>(predicate: tagPredicate))
                guard tags.count == uniqueIDs.count else {
                    throw CashFlowError.persistence(message: "One or more tags were not found.")
                }
                entity.tags = tags
            }
            // Only undo/restore paths supply suppressions; rule/assistant applies leave them alone.
            if let suppressed = assignment.suppressedTagIDs {
                entity.suppressedTagIDsData = try EntityMappers.encodeTagIDs(suppressed)
            }
        }
        try context.save()
    }

    public func updateEnrichment(
        transactionID: TransactionID,
        title: String,
        location: String?,
        source: TitleSource,
        clearLocation: Bool
    ) async throws {
        let context = ModelContext(modelContainer)
        let id = transactionID.rawValue
        let predicate = #Predicate<TransactionEntity> { $0.id == id }
        var descriptor = FetchDescriptor<TransactionEntity>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else {
            throw CashFlowError.persistence(message: "Transaction not found")
        }
        let existing = EntityMappers.titleSource(from: entity.titleSourceRaw)
        guard TitleSource.canOverwrite(existing: existing, with: source) else {
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CashFlowError.persistence(message: "Enriched title can't be empty.")
        }
        entity.enrichedTitle = trimmedTitle
        entity.titleSourceRaw = source.rawValue
        if clearLocation {
            entity.enrichedLocation = nil
        } else if let location {
            let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
            entity.enrichedLocation = trimmedLocation.isEmpty ? nil : trimmedLocation
        }
        try context.save()
    }

    public func markEnrichmentSkipped(transactionID: TransactionID) async throws {
        let context = ModelContext(modelContainer)
        let id = transactionID.rawValue
        let predicate = #Predicate<TransactionEntity> { $0.id == id }
        var descriptor = FetchDescriptor<TransactionEntity>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else {
            throw CashFlowError.persistence(message: "Transaction not found")
        }
        let existing = EntityMappers.titleSource(from: entity.titleSourceRaw)
        guard TitleSource.canOverwrite(existing: existing, with: .skipped) else {
            return
        }
        // Keep raw bank text in the UI; only leave the untitled backlog.
        entity.enrichedTitle = nil
        entity.enrichedLocation = nil
        entity.titleSourceRaw = TitleSource.skipped.rawValue
        try context.save()
    }

    public func applyTitleLocationAssignments(_ assignments: [TitleLocationAssignment]) async throws {
        guard !assignments.isEmpty else { return }
        let context = ModelContext(modelContainer)
        for assignment in assignments {
            let id = assignment.transactionID.rawValue
            let predicate = #Predicate<TransactionEntity> { $0.id == id }
            var descriptor = FetchDescriptor<TransactionEntity>(predicate: predicate)
            descriptor.fetchLimit = 1
            guard let entity = try context.fetch(descriptor).first else { continue }
            entity.enrichedTitle = assignment.title
            entity.enrichedLocation = assignment.location
            entity.titleSourceRaw = EntityMappers.titleSourceRaw(from: assignment.titleSource)
        }
        try context.save()
    }

    public func fetchAllForCategorization() async throws -> [Transaction] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<TransactionEntity>(
            predicate: #Predicate { !$0.isPending }
        )
        return try context.fetch(descriptor).map(EntityMappers.transaction(from:))
    }

    public func fetchNeedingCategorySuggestion(limit: Int) async throws -> [Transaction] {
        let context = ModelContext(modelContainer)
        let undefinedID = SystemCategory.undefined.id.rawValue
        var descriptor = FetchDescriptor<TransactionEntity>(
            predicate: #Predicate {
                !$0.isPending && $0.categoryID == undefinedID && !$0.categoryLocked
            },
            sortBy: [SortDescriptor(\.postedDate, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try context.fetch(descriptor).map(EntityMappers.transaction(from:))
    }

    public func countNeedingCategorySuggestion() async throws -> Int {
        let context = ModelContext(modelContainer)
        let undefinedID = SystemCategory.undefined.id.rawValue
        let descriptor = FetchDescriptor<TransactionEntity>(
            predicate: #Predicate {
                !$0.isPending && $0.categoryID == undefinedID && !$0.categoryLocked
            }
        )
        return try context.fetchCount(descriptor)
    }

    public func fetchNeedingEnrichment(limit: Int) async throws -> [Transaction] {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<TransactionEntity>(
            predicate: EnrichmentBacklogQuery.predicate,
            sortBy: [SortDescriptor(\.postedDate, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try context.fetch(descriptor).map(EntityMappers.transaction(from:))
    }

    public func countNeedingEnrichment() async throws -> Int {
        try EnrichmentBacklogQuery.count(context: ModelContext(modelContainer))
    }

    public func countDistinctDescriptionsNeedingEnrichment() async throws -> Int {
        try EnrichmentBacklogQuery.distinctDescriptionCount(
            context: ModelContext(modelContainer)
        )
    }

    /// Keyset scan that can walk the full store (no hard 1k cap) for infinite scrolling.
    private func fetchKeyset(
        context: ModelContext,
        filter: TransactionFilter,
        cursor: TransactionCursor?,
        limit: Int
    ) throws -> [TransactionEntity] {
        let calendar = Calendar.current
        let now = Date.now
        let dateInterval = filter.dateRange?.interval(calendar: calendar, now: now)
        var results: [TransactionEntity] = []
        results.reserveCapacity(limit)
        var scanCursor = cursor

        while results.count < limit {
            let batch = try fetchBatch(context: context, after: scanCursor)
            if batch.isEmpty { break }

            for entity in batch {
                if matches(entity, filter: filter, dateInterval: dateInterval) {
                    results.append(entity)
                    if results.count == limit { break }
                }
            }

            if let last = batch.last {
                scanCursor = TransactionCursor(
                    postedDate: last.postedDate,
                    id: TransactionID(last.id)
                )
            }
            if batch.count < scanBatchSize { break }
        }

        return results
    }

    private func fetchBatch(
        context: ModelContext,
        after cursor: TransactionCursor?
    ) throws -> [TransactionEntity] {
        var descriptor = FetchDescriptor<TransactionEntity>(
            sortBy: [
                SortDescriptor(\.postedDate, order: .reverse),
                SortDescriptor(\.id, order: .reverse),
            ]
        )
        descriptor.fetchLimit = scanBatchSize

        if let cursor {
            let cursorDate = cursor.postedDate
            let cursorID = cursor.id.rawValue
            descriptor.predicate = #Predicate<TransactionEntity> { entity in
                entity.postedDate < cursorDate
                    || (entity.postedDate == cursorDate && entity.id < cursorID)
            }
        }

        return try context.fetch(descriptor)
    }

    private func matches(
        _ entity: TransactionEntity,
        filter: TransactionFilter,
        dateInterval: DateInterval?
    ) -> Bool {
        let entityAccountID = entity.account?.id ?? entity.accountID
        if let accountID = filter.accountID?.rawValue, entityAccountID != accountID {
            return false
        }
        if let categoryID = filter.categoryID?.rawValue, entity.categoryID != categoryID {
            return false
        }
        if let tagID = filter.tagID?.rawValue {
            guard entity.tags.contains(where: { $0.id == tagID }) else {
                return false
            }
        }
        if let dateInterval {
            if entity.postedDate < dateInterval.start || entity.postedDate > dateInterval.end {
                return false
            }
        }
        if let query = filter.searchQuery {
            let categoryName = SystemCategory.category(for: CategoryID(entity.categoryID)).name
            let tagNames = entity.tags.map(\.name)
            let accountName = entity.account?.name ?? ""
            return TransactionSearchMatching.matches(
                query: query,
                title: entity.enrichedTitle,
                location: entity.enrichedLocation,
                description: entity.transactionDescription,
                categoryName: categoryName,
                tagNames: tagNames,
                accountName: accountName,
                amount: entity.amount
            )
        }
        return true
    }
}

public actor SwiftDataAccountRepository: AccountRepository {
    private let modelContainer: ModelContainer

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    public func fetchAll() async throws -> [Account] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AccountEntity>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map(EntityMappers.account(from:))
    }

    public func updateName(accountID: AccountID, name: String) async throws {
        let context = ModelContext(modelContainer)
        let id = accountID.rawValue
        let predicate = #Predicate<AccountEntity> { $0.id == id }
        var descriptor = FetchDescriptor<AccountEntity>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else {
            throw CashFlowError.persistence(message: "Account not found.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CashFlowError.persistence(message: "Account name can't be empty.")
        }
        entity.name = trimmed
        entity.userEditedName = true
        try context.save()
    }

    public func create(
        name: String,
        institutionName: String,
        currencyCode: String,
        createdByImportBatchID: ImportBatchID?
    ) async throws -> Account {
        let context = ModelContext(modelContainer)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CashFlowError.persistence(message: "Account name can't be empty.")
        }
        let id = UUID().uuidString
        let identityKey = ProviderIdentityEncoding.csvAccountKey(localAccountID: id)
        let entity = AccountEntity(
            id: id,
            identityKey: identityKey,
            source: .csvImport,
            linkNamespace: id,
            providerAccountID: identityKey,
            name: trimmed,
            institutionName: institutionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "CSV Import"
                : institutionName.trimmingCharacters(in: .whitespacesAndNewlines),
            currencyCode: currencyCode.isEmpty ? "USD" : currencyCode,
            balance: 0,
            balanceDate: .now,
            userEditedName: true,
            createdByImportBatchID: createdByImportBatchID?.rawValue,
            providerState: .current
        )
        context.insert(entity)
        try context.save()
        return EntityMappers.account(from: entity)
    }
}
