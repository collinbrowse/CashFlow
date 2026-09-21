import Foundation

/// User-confirmed merge of a historical local account into a current provider account identity.
public protocol AccountDuplicateRepairing: Sendable {
    /// Current provider accounts that can donate identity to `accountID`.
    func currentProviderCandidates(retaining accountID: AccountID) async throws -> [Account]

    func preview(
        retaining accountID: AccountID,
        adoptingProviderIdentityFrom providerAccountID: AccountID,
        mergeLikelyDuplicates: Bool
    ) async throws -> DuplicateAccountRepairPreview

    func repair(_ command: DuplicateAccountRepairCommand) async throws -> DuplicateAccountRepairResult
}

extension AccountDuplicateRepairing {
    public func preview(
        retaining accountID: AccountID,
        adoptingProviderIdentityFrom providerAccountID: AccountID
    ) async throws -> DuplicateAccountRepairPreview {
        try await preview(
            retaining: accountID,
            adoptingProviderIdentityFrom: providerAccountID,
            mergeLikelyDuplicates: false
        )
    }
}
