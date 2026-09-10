import Foundation
import SwiftData
import CashFlowKit

enum SyncMergeEngine {
    static func merge(
        payload: RemoteSyncPayload,
        into context: ModelContext,
        syncedAt: Date = .now,
        pruneStalePending: Bool = true,
        persist: Bool = true
    ) throws {
        let rules = try loadRules(from: context)
        var touchedIdentityKeys = Set<String>()
        touchedIdentityKeys.reserveCapacity(payload.accounts.count)

        for remoteAccount in payload.accounts {
            touchedIdentityKeys.insert(remoteAccount.identityKey)
            let account = try upsertAccount(
                remoteAccount,
                source: payload.source,
                syncedAt: syncedAt,
                context: context
            )
            var remoteExternalIDs = Set<String>()
            remoteExternalIDs.reserveCapacity(remoteAccount.transactions.count)
            for remoteTx in remoteAccount.transactions {
                remoteExternalIDs.insert(remoteTx.externalID)
                try upsertTransaction(
                    remoteTx,
                    account: account,
                    source: payload.source.source,
                    rules: rules,
                    context: context
                )
            }
            if remoteAccount.transactionCompleteness == .authoritative, pruneStalePending {
                try removeStalePendingTransactions(
                    account: account,
                    remoteExternalIDs: remoteExternalIDs,
                    context: context
                )
            }
        }

        try markUnseenAccountsHistorical(
            source: payload.source,
            excludingIdentityKeys: touchedIdentityKeys,
            authoritativeConnectionIDs: payload.authoritativeConnectionIDs,
            hasGlobalIncompleteness: payload.hasGlobalIncompleteness,
            into: context
        )

        try applyUnmatchedProviderMessages(
            issues: payload.issues,
            messages: payload.providerMessages,
            remoteAccounts: payload.accounts,
            excludingIdentityKeys: touchedIdentityKeys,
            into: context
        )
        if persist {
            try context.save()
        }
    }

    static func applyUnmatchedProviderMessages(
        issues: [RemoteProviderIssue] = [],
        messages: [String],
        remoteAccounts: [RemoteAccountSnapshot],
        excludingIdentityKeys: Set<String>,
        into context: ModelContext
    ) throws {
        let actionable = messages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !SimpleFINClient.isBenignDateRangeAdvisory($0) }
        guard !actionable.isEmpty || !issues.isEmpty else { return }

        let attachedMessages = Set(
            remoteAccounts.compactMap { account -> String? in
                guard let issue = account.syncIssue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !issue.isEmpty
                else { return nil }
                return issue.lowercased()
            }
        )

        let unmatched = actionable.filter { message in
            let key = message.lowercased()
            if attachedMessages.contains(key) { return false }
            return !attachedMessages.contains { $0.contains(key) || key.contains($0) }
        }

        let locals = try context.fetch(FetchDescriptor<AccountEntity>())
        let untouched = locals.filter { !excludingIdentityKeys.contains($0.identityKey) }
        guard !untouched.isEmpty else { return }

        let broadcastAll = remoteAccounts.isEmpty
        for account in untouched {
            var matching = unmatched.filter { message in
                if broadcastAll { return true }
                return SimpleFINClient.messageMatchesAccountIdentity(
                    message,
                    name: account.name,
                    institutionName: account.institutionName
                )
            }
            for issue in issues {
                switch issue.scope {
                case .global:
                    matching.append(issue.message)
                case .connection(let connID):
                    if account.providerConnectionID == connID {
                        matching.append(issue.message)
                    }
                case .account(let connID, let accountID):
                    guard account.providerAccountID == accountID else { continue }
                    if connID.isEmpty || account.providerConnectionID == connID {
                        matching.append(issue.message)
                    }
                }
            }
            guard !matching.isEmpty else { continue }
            account.syncIssue = SimpleFINClient.mergeSyncIssues(
                account.syncIssue,
                matching.joined(separator: " ")
            )
        }
    }

    private static func loadRules(from context: ModelContext) throws -> [CategorizationRule] {
        let descriptor = FetchDescriptor<CategorizationRuleEntity>(
            sortBy: [
                SortDescriptor(\.priority, order: .forward),
                SortDescriptor(\.id, order: .forward),
            ]
        )
        return try context.fetch(descriptor).map { try EntityMappers.categorizationRule(from: $0) }
    }

    private static func upsertAccount(
        _ remote: RemoteAccountSnapshot,
        source: ProviderLinkIdentity,
        syncedAt: Date,
        context: ModelContext
    ) throws -> AccountEntity {
        let identityKey = remote.identityKey
        let predicate = #Predicate<AccountEntity> { $0.identityKey == identityKey }
        var descriptor = FetchDescriptor<AccountEntity>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            let resolved = MergeAccountSyncPolicy.resolvedName(
                localName: existing.name,
                localUserEditedName: existing.userEditedName,
                remoteName: remote.name
            )
            existing.name = resolved.name
            existing.userEditedName = resolved.userEditedName
            existing.institutionName = remote.institutionName
            existing.currencyCode = remote.currencyCode
            existing.balance = remote.balance
            existing.balanceDate = remote.balanceDate
            existing.providerConnectionID = remote.identity.connectionID
            existing.providerAccountID = remote.identity.accountID
            existing.providerOrganizationID = remote.organization?.id
            existing.rawProviderName = remote.providerName
            existing.linkNamespace = source.linkNamespace
            existing.sourceRaw = source.source.rawValue
            existing.syncIssue = remote.syncIssue
            existing.providerLastSeenAt = syncedAt
            existing.providerState = .current
            existing.externalID = identityKey
            return existing
        }

        let entity = AccountEntity(
            id: UUID().uuidString,
            identityKey: identityKey,
            source: source.source,
            linkNamespace: source.linkNamespace,
            providerConnectionID: remote.identity.connectionID,
            providerAccountID: remote.identity.accountID,
            providerOrganizationID: remote.organization?.id,
            rawProviderName: remote.providerName,
            name: remote.name,
            institutionName: remote.institutionName,
            currencyCode: remote.currencyCode,
            balance: remote.balance,
            balanceDate: remote.balanceDate,
            syncIssue: remote.syncIssue,
            providerLastSeenAt: syncedAt,
            providerState: .current
        )
        context.insert(entity)
        return entity
    }

    private static func markUnseenAccountsHistorical(
        source: ProviderLinkIdentity,
        excludingIdentityKeys: Set<String>,
        authoritativeConnectionIDs: Set<String>,
        hasGlobalIncompleteness: Bool,
        into context: ModelContext
    ) throws {
        let namespace = source.linkNamespace
        let sourceRaw = source.source.rawValue
        let locals = try context.fetch(FetchDescriptor<AccountEntity>())
        let canArchiveForeignNamespaces = !hasGlobalIncompleteness && !authoritativeConnectionIDs.isEmpty
        for account in locals {
            guard account.createdByImportBatchID == nil,
                  account.sourceRaw != ProviderSource.csvImport.rawValue,
                  !excludingIdentityKeys.contains(account.identityKey)
            else { continue }

            if account.sourceRaw == sourceRaw, account.linkNamespace != namespace {
                if canArchiveForeignNamespaces {
                    account.providerState = .historical
                }
                continue
            }

            guard account.sourceRaw == sourceRaw,
                  account.linkNamespace == namespace
            else { continue }

            let connID = account.providerConnectionID ?? ""
            guard authoritativeConnectionIDs.contains(connID) else { continue }
            account.providerState = .historical
        }
    }

    private static func upsertTransaction(
        _ remote: RemoteTransactionSnapshot,
        account: AccountEntity,
        source: ProviderSource,
        rules: [CategorizationRule],
        context: ModelContext
    ) throws {
        let identityKey = ProviderIdentityEncoding.transactionKey(
            source: source,
            localAccountID: account.id,
            sourceTransactionID: remote.externalID
        )
        let predicate = #Predicate<TransactionEntity> { $0.identityKey == identityKey }
        var descriptor = FetchDescriptor<TransactionEntity>(predicate: predicate)
        descriptor.fetchLimit = 1

        let remoteDomain = Transaction(
            id: TransactionID(identityKey),
            accountID: AccountID(account.id),
            externalID: remote.externalID,
            amount: remote.amount,
            postedDate: remote.postedDate,
            description: remote.description,
            categoryID: remote.suggestedCategoryID,
            currencyCode: account.currencyCode,
            userEditedCategory: false,
            isPending: remote.isPending,
            categoryLocked: false
        )

        if let existing = try context.fetch(descriptor).first {
            let local = EntityMappers.transaction(from: existing)
            let merged = MergeSyncPolicy.merge(
                local: local,
                remote: remoteDomain,
                rules: rules,
                preferSuggestedCategory: remote.preferSuggestedCategory
            )
            existing.amount = merged.amount
            existing.postedDate = merged.postedDate
            existing.transactionDescription = merged.description
            existing.categoryID = merged.categoryID.rawValue
            existing.userEditedCategory = merged.userEditedCategory
            existing.isPending = merged.isPending
            existing.currencyCode = merged.currencyCode
            existing.accountID = account.id
            existing.account = account
            existing.categoryLocked = merged.categoryLocked
            existing.enrichedTitle = merged.enrichedTitle
            existing.enrichedLocation = merged.enrichedLocation
            existing.titleSourceRaw = EntityMappers.titleSourceRaw(from: merged.titleSource)
            existing.categorySourceRaw = EntityMappers.categorySourceRaw(from: merged.categorySource)
            existing.suppressedTagIDsData = try EntityMappers.encodeTagIDs(merged.suppressedTagIDs)
            existing.identityKey = identityKey
            existing.syncKey = identityKey
            try applyTags(merged.tagIDs, to: existing, context: context)
        } else {
            let merged = MergeSyncPolicy.merge(
                local: nil,
                remote: remoteDomain,
                rules: rules,
                preferSuggestedCategory: remote.preferSuggestedCategory
            )
            let entity = TransactionEntity(
                id: UUID().uuidString,
                externalID: remote.externalID,
                accountID: account.id,
                amount: merged.amount,
                postedDate: merged.postedDate,
                transactionDescription: merged.description,
                categoryID: merged.categoryID.rawValue,
                currencyCode: account.currencyCode,
                userEditedCategory: merged.userEditedCategory,
                isPending: remote.isPending,
                identityKey: identityKey,
                account: account,
                categoryLocked: false,
                enrichedTitle: merged.enrichedTitle,
                enrichedLocation: merged.enrichedLocation,
                titleSourceRaw: EntityMappers.titleSourceRaw(from: merged.titleSource),
                categorySourceRaw: EntityMappers.categorySourceRaw(from: merged.categorySource),
                suppressedTagIDsData: try EntityMappers.encodeTagIDs(merged.suppressedTagIDs),
                ingestSourceRaw: IngestSource.bankLink.rawValue,
                importBatchID: nil
            )
            context.insert(entity)
            try applyTags(merged.tagIDs, to: entity, context: context)
        }
    }

    private static func applyTags(
        _ tagIDs: [TagID],
        to entity: TransactionEntity,
        context: ModelContext
    ) throws {
        let uniqueIDs = Array(Set(tagIDs.map(\.rawValue)))
        guard !uniqueIDs.isEmpty else { return }
        let predicate = #Predicate<TagEntity> { uniqueIDs.contains($0.id) }
        let tags = try context.fetch(FetchDescriptor<TagEntity>(predicate: predicate))
        var byID = Dictionary(uniqueKeysWithValues: entity.tags.map { ($0.id, $0) })
        for tag in tags {
            byID[tag.id] = tag
        }
        entity.tags = Array(byID.values)
    }

    private static func removeStalePendingTransactions(
        account: AccountEntity,
        remoteExternalIDs: Set<String>,
        context: ModelContext
    ) throws {
        let accountID = account.id
        let descriptor = FetchDescriptor<TransactionEntity>(
            predicate: #Predicate<TransactionEntity> {
                $0.accountID == accountID && $0.isPending == true
            }
        )
        for entity in try context.fetch(descriptor) where !remoteExternalIDs.contains(entity.externalID) {
            context.delete(entity)
        }
    }
}
