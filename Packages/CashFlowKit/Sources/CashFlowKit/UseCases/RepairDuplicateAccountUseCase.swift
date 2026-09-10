import Foundation

/// Domain entry point for previewing and executing a user-confirmed duplicate-account repair.
public struct RepairDuplicateAccountUseCase: Sendable {
    private let repairing: any AccountDuplicateRepairing

    public init(repairing: any AccountDuplicateRepairing) {
        self.repairing = repairing
    }

    public func candidates(retaining accountID: AccountID) async throws -> [Account] {
        try await repairing.currentProviderCandidates(retaining: accountID)
    }

    public func preview(
        retaining accountID: AccountID,
        adoptingProviderIdentityFrom providerAccountID: AccountID,
        mergeLikelyDuplicates: Bool = false
    ) async throws -> DuplicateAccountRepairPreview {
        try await repairing.preview(
            retaining: accountID,
            adoptingProviderIdentityFrom: providerAccountID,
            mergeLikelyDuplicates: mergeLikelyDuplicates
        )
    }

    public func execute(
        _ command: DuplicateAccountRepairCommand
    ) async throws -> DuplicateAccountRepairResult {
        try await repairing.repair(command)
    }
}
