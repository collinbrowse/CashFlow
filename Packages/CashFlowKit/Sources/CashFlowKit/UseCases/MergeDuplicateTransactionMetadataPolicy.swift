import Foundation

/// Pure metadata merge for two local transactions that represent the same spend.
public enum MergeDuplicateTransactionMetadataPolicy: Sendable {
    public static func merge(retained: Transaction, discarded: Transaction) -> Transaction {
        let categorySource = preferredCategorySource(
            retained: retained.effectiveCategorySource,
            discarded: discarded.effectiveCategorySource,
            retainedLocked: retained.categoryLocked,
            discardedLocked: discarded.categoryLocked
        )
        let categoryID: CategoryID
        let categoryLocked: Bool
        if retained.categoryLocked {
            categoryID = retained.categoryID
            categoryLocked = true
        } else if discarded.categoryLocked {
            categoryID = discarded.categoryID
            categoryLocked = true
        } else if let categorySource {
            categoryID = preferredCategoryID(
                source: categorySource,
                retained: retained,
                discarded: discarded
            )
            categoryLocked = false
        } else {
            categoryID = retained.categoryID
            categoryLocked = false
        }

        let titleChoice = preferredTitle(
            retainedTitle: retained.enrichedTitle,
            retainedLocation: retained.enrichedLocation,
            retainedSource: retained.titleSource,
            discardedTitle: discarded.enrichedTitle,
            discardedLocation: discarded.enrichedLocation,
            discardedSource: discarded.titleSource
        )

        var tags = Set(retained.tagIDs.map(\.rawValue))
        tags.formUnion(discarded.tagIDs.map(\.rawValue))
        var suppressed = Set(retained.suppressedTagIDs.map(\.rawValue))
        suppressed.formUnion(discarded.suppressedTagIDs.map(\.rawValue))
        tags.subtract(suppressed)

        let ingestSource: IngestSource = {
            if retained.ingestSource == .bankLink || discarded.ingestSource == .bankLink {
                return .bankLink
            }
            return retained.ingestSource
        }()

        // Posted wins over pending when either side has posted.
        let isPending = retained.isPending && discarded.isPending

        return Transaction(
            id: retained.id,
            accountID: retained.accountID,
            externalID: retained.externalID,
            amount: retained.amount,
            postedDate: retained.postedDate,
            description: retained.description,
            categoryID: categoryID,
            currencyCode: retained.currencyCode,
            userEditedCategory: categorySource?.isUserEditedCompat ?? false,
            isPending: isPending,
            categoryLocked: categoryLocked,
            tagIDs: tags.map { TagID($0) }.sorted { $0.rawValue < $1.rawValue },
            suppressedTagIDs: suppressed.map { TagID($0) }.sorted { $0.rawValue < $1.rawValue },
            enrichedTitle: titleChoice.title,
            enrichedLocation: titleChoice.location,
            titleSource: titleChoice.source,
            categorySource: categorySource,
            ingestSource: ingestSource,
            importBatchID: ingestSource == .bankLink ? nil : retained.importBatchID ?? discarded.importBatchID
        )
    }

    private static func preferredCategorySource(
        retained: CategorySource?,
        discarded: CategorySource?,
        retainedLocked: Bool,
        discardedLocked: Bool
    ) -> CategorySource? {
        if retainedLocked { return retained ?? .user }
        if discardedLocked { return discarded ?? .user }
        switch (retained, discarded) {
        case let (r?, d?):
            return r.rank >= d.rank ? r : d
        case let (r?, nil):
            return r
        case let (nil, d?):
            return d
        case (nil, nil):
            return nil
        }
    }

    private static func preferredCategoryID(
        source: CategorySource,
        retained: Transaction,
        discarded: Transaction
    ) -> CategoryID {
        if retained.effectiveCategorySource == source {
            return retained.categoryID
        }
        if discarded.effectiveCategorySource == source {
            return discarded.categoryID
        }
        return retained.categoryID
    }

    private static func preferredTitle(
        retainedTitle: String?,
        retainedLocation: String?,
        retainedSource: TitleSource?,
        discardedTitle: String?,
        discardedLocation: String?,
        discardedSource: TitleSource?
    ) -> (title: String?, location: String?, source: TitleSource?) {
        switch (retainedSource, discardedSource) {
        case let (r?, d?):
            if r.rank >= d.rank {
                return (retainedTitle, retainedLocation, r)
            }
            return (discardedTitle, discardedLocation, d)
        case let (r?, nil):
            return (retainedTitle, retainedLocation, r)
        case let (nil, d?):
            return (discardedTitle, discardedLocation, d)
        case (nil, nil):
            return (retainedTitle ?? discardedTitle, retainedLocation ?? discardedLocation, nil)
        }
    }
}
