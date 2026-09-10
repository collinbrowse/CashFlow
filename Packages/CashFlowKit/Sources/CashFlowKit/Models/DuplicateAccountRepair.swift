import Foundation

public struct DuplicateAccountRepairPreview: Sendable, Equatable, Identifiable {
    public let id: String
    public let retainedAccount: Account
    public let providerAccount: Account
    public let exactDuplicateCount: Int
    public let likelyDuplicateCount: Int
    public let ambiguousCount: Int
    public let movedCount: Int

    public init(
        id: String,
        retainedAccount: Account,
        providerAccount: Account,
        exactDuplicateCount: Int,
        likelyDuplicateCount: Int,
        ambiguousCount: Int,
        movedCount: Int
    ) {
        self.id = id
        self.retainedAccount = retainedAccount
        self.providerAccount = providerAccount
        self.exactDuplicateCount = exactDuplicateCount
        self.likelyDuplicateCount = likelyDuplicateCount
        self.ambiguousCount = ambiguousCount
        self.movedCount = movedCount
    }
}

public struct DuplicateAccountRepairCommand: Sendable, Equatable {
    public let retainedAccountID: AccountID
    public let providerAccountID: AccountID
    public let expectedPreviewID: String
    public let mergeLikelyDuplicates: Bool

    public init(
        retainedAccountID: AccountID,
        providerAccountID: AccountID,
        expectedPreviewID: String,
        mergeLikelyDuplicates: Bool = false
    ) {
        self.retainedAccountID = retainedAccountID
        self.providerAccountID = providerAccountID
        self.expectedPreviewID = expectedPreviewID
        self.mergeLikelyDuplicates = mergeLikelyDuplicates
    }
}

public struct DuplicateAccountRepairResult: Sendable, Equatable {
    public let retainedAccountID: AccountID
    public let removedAccountID: AccountID
    public let deduplicatedCount: Int
    public let movedCount: Int

    public init(
        retainedAccountID: AccountID,
        removedAccountID: AccountID,
        deduplicatedCount: Int,
        movedCount: Int
    ) {
        self.retainedAccountID = retainedAccountID
        self.removedAccountID = removedAccountID
        self.deduplicatedCount = deduplicatedCount
        self.movedCount = movedCount
    }
}
