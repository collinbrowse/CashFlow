import Foundation
import Observation
import UIKit
import CashFlowKit

@MainActor
@Observable
final class AccountsViewModel {
    private let connectionLifecycle: any ConnectionLifecycleServing
    private let syncServing: any SyncServing
    private let accountRepository: any AccountRepository
    private let accountDuplicateRepair: RepairDuplicateAccountUseCase
    private let useLargeDemoSeed: Bool

    var accounts: [Account] = []
    var connection: LinkedConnection = .init(isLinked: false, providerName: "None")
    var setupToken = ""
    var showLinkSheet = false
    var pendingLinkAfterOnboarding = false
    var isWorking = false
    var workingTitle: String?
    var syncProgress: SyncProgress?
    var statusBanner: String?
    var errorAlert: AccountsErrorAlert?
    var showOnboarding: Bool
    var storeEpoch: Int = 0
    var renamingAccountID: AccountID?
    var renamingName = ""
    var repairingAccountID: AccountID?
    var repairCandidates: [Account] = []
    var repairPreview: DuplicateAccountRepairPreview?
    var selectedRepairProviderID: AccountID?
    var mergeLikelyDuplicates = false

    private var operationID = UUID()
    private var statusBannerDismissTask: Task<Void, Never>?
    private var syncProgressTask: Task<Void, Never>?

    /// Prefer live sync stage copy while a sync is in flight.
    var busyOverlayTitle: String {
        if let syncProgress {
            return SyncProgressFormatting.title(for: syncProgress)
        }
        return workingTitle ?? "Working…"
    }

    var hasOrphanLocalData: Bool {
        !connection.isLinked && !accounts.isEmpty
    }

    /// True when any linked account still carries a Bridge sync issue from the last pull.
    var hasAccountSyncIssues: Bool {
        connection.isLinked && accounts.contains(where: \.hasSyncIssue)
    }

    /// Connection row label — soft Bridge failures are not "Linked" / OK.
    var connectionStatusLabel: String {
        guard connection.isLinked else { return "Not linked" }
        if connection.needsReauth { return "Reconnect required" }
        if hasAccountSyncIssues { return "Needs attention" }
        return "Linked"
    }

    /// Offer reclaim/relink when access was revoked or an account still has a sync issue.
    var showsReconnectAction: Bool {
        connection.isLinked && (connection.needsReauth || hasAccountSyncIssues)
    }

    /// Per-row sync health for the Accounts list. Healthy only when linked and issue-free.
    func syncDisplay(for account: Account) -> AccountSyncDisplay {
        guard connection.isLinked else { return .none }
        if connection.needsReauth {
            return .issue("Reconnect required")
        }
        if account.providerState == .historical {
            return .issue("Not in latest sync — Repair duplicate if this was re-added")
        }
        if let issue = account.syncIssue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !issue.isEmpty
        {
            return .issue(issue)
        }
        return .healthy
    }

    init(
        connectionLifecycle: any ConnectionLifecycleServing,
        syncServing: any SyncServing,
        accountRepository: any AccountRepository,
        accountDuplicateRepair: RepairDuplicateAccountUseCase,
        useLargeDemoSeed: Bool
    ) {
        self.connectionLifecycle = connectionLifecycle
        self.syncServing = syncServing
        self.accountRepository = accountRepository
        self.accountDuplicateRepair = accountDuplicateRepair
        self.useLargeDemoSeed = useLargeDemoSeed
        self.showOnboarding = !UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
    }

    func onAppear() async {
        startObservingSyncProgress()
        await refreshStatus()
        await syncEmptyLinkedLedgerIfNeeded()
    }

    private func startObservingSyncProgress() {
        guard syncProgressTask == nil else { return }
        syncProgressTask = Task { [syncServing] in
            for await progress in syncServing.syncProgressUpdates() {
                guard !Task.isCancelled else { break }
                syncProgress = progress
            }
        }
    }

    func refreshStatus() async {
        connection = await syncServing.connectionStatus()
        accounts = (try? await accountRepository.fetchAll()) ?? []
    }

    private func syncEmptyLinkedLedgerIfNeeded() async {
        guard connection.isLinked,
              connection.lastSuccessfulSyncAt == nil,
              accounts.isEmpty
        else { return }
        await syncNow()
    }

    func loadDemo(deleteLocalData: Bool = true) async {
        let op = beginWorking("Loading demo data…")
        defer { endWorking(op) }
        do {
            let token = useLargeDemoSeed ? "demo-large" : "demo"
            connection = try await connectionLifecycle.replaceAndLink(
                withSetupToken: token,
                deleteLocalData: deleteLocalData
            )
            guard isCurrent(op) else { return }
            completeOnboarding()
            presentStatus("Demo data loaded.")
            await refreshStatus()
            storeEpoch += 1
        } catch {
            presentError(
                title: "Couldn't load demo data",
                message: userFacingMessage(for: error, fallback: "Something went wrong while loading demo data."),
                operation: op
            )
        }
    }

    func beginLinkFlow() {
        clearStatusBanner()
        errorAlert = nil
        showLinkSheet = true
    }

    func beginLinkFlowFromOnboarding() {
        clearStatusBanner()
        errorAlert = nil
        pendingLinkAfterOnboarding = true
        showOnboarding = false
    }

    func presentPendingLinkIfNeeded() {
        guard pendingLinkAfterOnboarding else { return }
        pendingLinkAfterOnboarding = false
        showLinkSheet = true
    }

    /// Set before presenting the link sheet when the user already chose keep/delete.
    var pendingLinkDeletesLocalData = true
    /// Reuse the current Keychain namespace (reconnect). New tokens keep this false.
    var pendingLinkPreservesNamespace = false

    func linkSimpleFIN() async {
        let op = beginWorking("Linking SimpleFIN…")
        defer { endWorking(op) }
        do {
            workingTitle = "Linking SimpleFIN…"
            connection = try await connectionLifecycle.replaceAndLink(
                withSetupToken: setupToken,
                deleteLocalData: pendingLinkDeletesLocalData,
                preservingLinkNamespace: pendingLinkPreservesNamespace
            )
            guard isCurrent(op) else { return }
            setupToken = ""
            showLinkSheet = false
            pendingLinkDeletesLocalData = true
            pendingLinkPreservesNamespace = false
            completeOnboarding()
            presentStatus(
                banner(afterSync: connection, successFallback: "Account linked."),
                dismissAfter: statusDismissDelay(for: connection)
            )
            await refreshStatus()
            storeEpoch += 1
        } catch CashFlowError.unauthorized {
            guard isCurrent(op) else { return }
            await refreshStatus()
            let needsReauth = connection.needsReauth
            presentError(
                title: "Couldn't link SimpleFIN",
                message: needsReauth || connection.isLinked
                    ? "That setup token was already used or access was revoked. Create a new SimpleFIN token to reconnect."
                    : "Token may be compromised or already used. Create a new SimpleFIN token.",
                operation: op,
                primaryAction: .reconnect
            )
        } catch {
            guard isCurrent(op) else { return }
            await refreshStatus()
            // Claim may have succeeded inside replaceAndLink before sync failed.
            if connection.isLinked {
                setupToken = ""
                showLinkSheet = false
                completeOnboarding()
                storeEpoch += 1
                presentError(
                    title: "Linked, but sync failed",
                    message: userFacingMessage(
                        for: error,
                        fallback: "Your token was claimed. Tap Sync Now to retry."
                    ),
                    operation: op,
                    primaryAction: .syncNow
                )
            } else {
                presentError(
                    title: "Couldn't link SimpleFIN",
                    message: userFacingMessage(for: error, fallback: "Check your token and try again."),
                    operation: op
                )
            }
        }
    }

    func syncNow() async {
        let op = beginWorking("Syncing…")
        defer { endWorking(op) }
        do {
            connection = try await syncServing.syncNow()
            guard isCurrent(op) else { return }
            presentStatus(
                banner(afterSync: connection, successFallback: "Synced."),
                dismissAfter: statusDismissDelay(for: connection)
            )
            await refreshStatus()
            storeEpoch += 1
        } catch CashFlowError.unauthorized {
            guard isCurrent(op) else { return }
            await refreshStatus()
            presentError(
                title: "Reconnect required",
                message: "Your SimpleFIN connection expired. Link again with a new token.",
                operation: op,
                primaryAction: .reconnect
            )
        } catch {
            guard isCurrent(op) else { return }
            presentError(
                title: "Couldn't sync",
                message: userFacingMessage(for: error, fallback: "Try again in a moment."),
                operation: op
            )
        }
    }

    func disconnect(removeLocalData: Bool) async {
        let op = beginWorking(removeLocalData ? "Disconnecting and deleting…" : "Disconnecting…")
        defer { endWorking(op) }
        do {
            connection = try await connectionLifecycle.disconnect(deleteLocalData: removeLocalData)
            guard isCurrent(op) else { return }
            presentStatus(
                removeLocalData ? "Disconnected and local data deleted." : "Disconnected."
            )
            await refreshStatus()
            storeEpoch += 1
        } catch {
            guard isCurrent(op) else { return }
            presentError(
                title: "Couldn't disconnect",
                message: userFacingMessage(for: error, fallback: "Try again in a moment."),
                operation: op
            )
            await refreshStatus()
        }
    }

    func resetLocalDataKeepingLink() async {
        let op = beginWorking("Clearing local data…")
        defer { endWorking(op) }
        do {
            connection = try await connectionLifecycle.resetLocalDataKeepingLink()
            guard isCurrent(op) else { return }
            presentStatus(
                connection.isLinked
                    ? "Local data cleared. Tap Sync Now to re-download."
                    : "Local data cleared.",
                dismissAfter: 4
            )
            await refreshStatus()
            storeEpoch += 1
        } catch {
            guard isCurrent(op) else { return }
            presentError(
                title: "Couldn't clear local data",
                message: userFacingMessage(for: error, fallback: "Try again in a moment."),
                operation: op
            )
            await refreshStatus()
        }
    }

    func eraseEverything() async {
        let op = beginWorking("Erasing everything…")
        defer { endWorking(op) }
        do {
            try await connectionLifecycle.eraseEverything()
            guard isCurrent(op) else { return }
            presentStatus("All local data erased.")
            await refreshStatus()
            storeEpoch += 1
        } catch {
            guard isCurrent(op) else { return }
            presentError(
                title: "Couldn't erase data",
                message: userFacingMessage(for: error, fallback: "Try again in a moment."),
                operation: op
            )
            await refreshStatus()
        }
    }

    func performErrorAction(_ action: AccountsErrorAction) {
        dismissErrorAlert()
        switch action {
        case .reconnect:
            pendingLinkDeletesLocalData = false
            pendingLinkPreservesNamespace = connection.isLinked
            beginLinkFlow()
        case .syncNow:
            Task { await syncNow() }
        case .dismissOnly:
            break
        }
    }

    func openSimpleFINCreate() {
        if let url = URL(string: "https://bridge.simplefin.org/simplefin/create") {
            #if canImport(UIKit)
            UIApplication.shared.open(url)
            #endif
        }
    }

    func dismissErrorAlert() {
        errorAlert = nil
    }

    func dismissOnboarding() {
        completeOnboarding()
    }

    func beginRename(_ account: Account) {
        renamingAccountID = account.id
        renamingName = account.name
    }

    func cancelRename() {
        renamingAccountID = nil
        renamingName = ""
    }

    func saveRename() async {
        guard let id = renamingAccountID else { return }
        do {
            try await accountRepository.updateName(accountID: id, name: renamingName)
            renamingAccountID = nil
            renamingName = ""
            await refreshStatus()
            storeEpoch += 1
        } catch {
            errorAlert = AccountsErrorAlert(
                title: "Couldn't rename account",
                message: userFacingMessage(for: error, fallback: "Try a different name."),
                primaryAction: .dismissOnly
            )
        }
    }

    func beginRepair(_ account: Account) async {
        repairingAccountID = account.id
        selectedRepairProviderID = nil
        repairPreview = nil
        mergeLikelyDuplicates = false
        do {
            repairCandidates = try await accountDuplicateRepair.candidates(retaining: account.id)
        } catch {
            repairingAccountID = nil
            errorAlert = AccountsErrorAlert(
                title: "Couldn't start repair",
                message: userFacingMessage(for: error, fallback: "Try Sync Now, then repair again."),
                primaryAction: .dismissOnly
            )
        }
    }

    func cancelRepair() {
        repairingAccountID = nil
        repairCandidates = []
        repairPreview = nil
        selectedRepairProviderID = nil
    }

    func selectRepairProvider(_ accountID: AccountID) async {
        selectedRepairProviderID = accountID
        await refreshRepairPreview()
    }

    func refreshRepairPreview() async {
        guard let retained = repairingAccountID,
              let provider = selectedRepairProviderID
        else {
            repairPreview = nil
            return
        }
        do {
            repairPreview = try await accountDuplicateRepair.preview(
                retaining: retained,
                adoptingProviderIdentityFrom: provider,
                mergeLikelyDuplicates: mergeLikelyDuplicates
            )
        } catch {
            repairPreview = nil
            errorAlert = AccountsErrorAlert(
                title: "Couldn't preview repair",
                message: userFacingMessage(for: error, fallback: "Choose a different account."),
                primaryAction: .dismissOnly
            )
        }
    }

    func confirmRepair() async {
        guard let retained = repairingAccountID,
              let provider = selectedRepairProviderID,
              let preview = repairPreview
        else { return }
        let op = beginWorking("Repairing duplicate…")
        defer { endWorking(op) }
        do {
            _ = try await accountDuplicateRepair.execute(
                DuplicateAccountRepairCommand(
                    retainedAccountID: retained,
                    providerAccountID: provider,
                    expectedPreviewID: preview.id,
                    mergeLikelyDuplicates: mergeLikelyDuplicates
                )
            )
            guard isCurrent(op) else { return }
            cancelRepair()
            presentStatus("Duplicate accounts repaired.")
            await refreshStatus()
            storeEpoch += 1
        } catch {
            presentError(
                title: "Couldn't repair accounts",
                message: userFacingMessage(for: error, fallback: "Try again after Sync Now."),
                operation: op
            )
        }
    }

    /// Offer repair when two bank accounts exist and at least one can donate current identity.
    var canRepairDuplicates: Bool {
        guard connection.isLinked else { return false }
        let bankAccounts = accounts.filter { $0.source != .csvImport }
        guard bankAccounts.count >= 2 else { return false }
        return bankAccounts.contains { $0.providerState == .current }
    }

    @discardableResult
    private func beginWorking(_ title: String) -> UUID {
        let id = UUID()
        operationID = id
        isWorking = true
        workingTitle = title
        errorAlert = nil
        return id
    }

    private func endWorking(_ operation: UUID) {
        guard operationID == operation else { return }
        isWorking = false
        workingTitle = nil
    }

    private func isCurrent(_ operation: UUID) -> Bool {
        operationID == operation
    }

    private func presentError(
        title: String,
        message: String,
        operation: UUID,
        primaryAction: AccountsErrorAction = .dismissOnly
    ) {
        guard operationID == operation else { return }
        errorAlert = AccountsErrorAlert(
            title: title,
            message: message,
            primaryAction: primaryAction
        )
        clearStatusBanner()
    }

    func presentStatus(_ message: String, dismissAfter seconds: TimeInterval = 2.4) {
        statusBannerDismissTask?.cancel()
        statusBanner = message
        statusBannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if statusBanner == message {
                statusBanner = nil
            }
        }
    }

    func clearStatusBanner() {
        statusBannerDismissTask?.cancel()
        statusBannerDismissTask = nil
        statusBanner = nil
    }

    private func userFacingMessage(for error: Error, fallback: String) -> String {
        CashFlowError.userFacingMessage(for: error, fallback: fallback)
    }

    private func completeOnboarding() {
        showOnboarding = false
        UserDefaults.standard.set(true, forKey: "didCompleteOnboarding")
    }

    private func banner(afterSync connection: LinkedConnection, successFallback: String) -> String {
        let messages = connection.providerMessages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if messages.isEmpty { return successFallback }
        return messages.joined(separator: " ")
    }

    private func statusDismissDelay(for connection: LinkedConnection) -> TimeInterval {
        connection.providerMessages.isEmpty ? 2.4 : 4.5
    }
}

enum AccountSyncDisplay: Equatable {
    case none
    case healthy
    case issue(String)
}

enum AccountsErrorAction: Equatable {
    case dismissOnly
    case reconnect
    case syncNow
}

struct AccountsErrorAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let primaryAction: AccountsErrorAction
}
