import Foundation

/// Atomic link / disconnect / erase / reset orchestration for bank connections.
/// Kept separate from `SyncServing` (ISP) — lifecycle is a different reason to change.
public protocol ConnectionLifecycleServing: Sendable {
    /// Claim/link and sync. When `deleteLocalData` is true, wipe accounts/transactions first.
    /// When false, keep existing local rows (e.g. CSV imports) and sync bank data alongside them.
    /// When `preservingLinkNamespace` is true, reuse the current Keychain namespace (reconnect).
    func replaceAndLink(
        withSetupToken token: String,
        deleteLocalData: Bool,
        preservingLinkNamespace: Bool
    ) async throws -> LinkedConnection

    /// Unlink credentials. When `deleteLocalData` is true, wipe store first (retry-safe), then unlink.
    func disconnect(deleteLocalData: Bool) async throws -> LinkedConnection

    /// Best-effort unlink + full local wipe (orphan recovery when Not linked but rows remain).
    func eraseEverything() async throws

    /// Wipe accounts/transactions/watermark/snapshot; keep credentials so Sync can re-pull.
    func resetLocalDataKeepingLink() async throws -> LinkedConnection
}

extension ConnectionLifecycleServing {
    public func replaceAndLink(
        withSetupToken token: String,
        deleteLocalData: Bool
    ) async throws -> LinkedConnection {
        try await replaceAndLink(
            withSetupToken: token,
            deleteLocalData: deleteLocalData,
            preservingLinkNamespace: false
        )
    }
}
