import Foundation
import SwiftData
import CashFlowKit

public actor SwiftDataAccountDuplicateRepairer: AccountDuplicateRepairing {
    private let modelContainer: ModelContainer
    private let widgetTimelineReloader: any WidgetTimelineReloading

    public init(
        modelContainer: ModelContainer,
        widgetTimelineReloader: any WidgetTimelineReloading = NoOpWidgetTimelineReloader()
    ) {
        self.modelContainer = modelContainer
        self.widgetTimelineReloader = widgetTimelineReloader
    }

    public func currentProviderCandidates(retaining accountID: AccountID) async throws -> [Account] {
        let context = ModelContext(modelContainer)
        let retained = try fetchAccount(id: accountID.rawValue, context: context)
        let locals = try context.fetch(FetchDescriptor<AccountEntity>())
        return locals
            .filter { candidate in
                candidate.id != retained.id
                    && candidate.source == retained.source
                    && candidate.source != .csvImport
                    && candidate.providerState == .current
                    && candidate.createdByImportBatchID == nil
            }
            .map(EntityMappers.account(from:))
            .sorted { $0.name < $1.name }
    }

    public func preview(
        retaining accountID: AccountID,
        adoptingProviderIdentityFrom providerAccountID: AccountID,
        mergeLikelyDuplicates: Bool
    ) async throws -> DuplicateAccountRepairPreview {
        let context = ModelContext(modelContainer)
        let plan = try buildPlan(
            retaining: accountID.rawValue,
            provider: providerAccountID.rawValue,
            mergeLikely: mergeLikelyDuplicates,
            context: context
        )
        return plan.preview
    }

    public func repair(
        _ command: DuplicateAccountRepairCommand
    ) async throws -> DuplicateAccountRepairResult {
        let context = ModelContext(modelContainer)
        let plan = try buildPlan(
            retaining: command.retainedAccountID.rawValue,
            provider: command.providerAccountID.rawValue,
            mergeLikely: command.mergeLikelyDuplicates,
            context: context
        )
        guard plan.preview.id == command.expectedPreviewID else {
            throw CashFlowError.persistence(
                message: "That repair preview is out of date. Review the accounts again."
            )
        }

        let retained = try fetchAccount(id: command.retainedAccountID.rawValue, context: context)
        let provider = try fetchAccount(id: command.providerAccountID.rawValue, context: context)
        let mergedPairs = plan.exactPairs + (command.mergeLikelyDuplicates ? plan.likelyPairs : [])

        retained.sourceRaw = provider.sourceRaw
        retained.linkNamespace = provider.linkNamespace
        retained.providerConnectionID = provider.providerConnectionID
        retained.providerAccountID = provider.providerAccountID
        retained.providerOrganizationID = provider.providerOrganizationID
        retained.rawProviderName = provider.rawProviderName
        if !retained.userEditedName {
            retained.name = provider.name
        }
        retained.institutionName = provider.institutionName
        retained.currencyCode = provider.currencyCode
        retained.balance = provider.balance
        retained.balanceDate = provider.balanceDate
        retained.syncIssue = provider.syncIssue
        retained.providerLastSeenAt = provider.providerLastSeenAt
        retained.providerState = .current
        retained.createdByImportBatchID = nil

        var deduplicated = 0
        var moved = 0

        for pair in mergedPairs {
            guard let retainedTx = try fetchTransaction(id: pair.retainedTransactionID, context: context),
                  let providerTx = try fetchTransaction(id: pair.providerTransactionID, context: context)
            else { continue }
            let merged = MergeDuplicateTransactionMetadataPolicy.merge(
                retained: EntityMappers.transaction(from: retainedTx),
                discarded: EntityMappers.transaction(from: providerTx)
            )
            try applyMergedMetadata(merged, to: retainedTx, account: retained, context: context)
            retainedTx.externalID = providerTx.externalID
            retainedTx.identityKey = ProviderIdentityEncoding.transactionKey(
                source: retained.source,
                localAccountID: retained.id,
                sourceTransactionID: providerTx.externalID
            )
            retainedTx.syncKey = retainedTx.identityKey
            retainedTx.amount = providerTx.amount
            retainedTx.postedDate = providerTx.postedDate
            retainedTx.transactionDescription = providerTx.transactionDescription
            retainedTx.isPending = merged.isPending
            context.delete(providerTx)
            deduplicated += 1
        }

        for txID in plan.moveTransactionIDs {
            guard let tx = try fetchTransaction(id: txID, context: context) else { continue }
            tx.account = retained
            tx.accountID = retained.id
            tx.identityKey = ProviderIdentityEncoding.transactionKey(
                source: retained.source == .csvImport ? .csvImport : retained.source,
                localAccountID: retained.id,
                sourceTransactionID: tx.externalID
            )
            tx.syncKey = tx.identityKey
            moved += 1
        }

        try remapRules(
            from: provider.id,
            to: retained.id,
            deletedTransactionIDs: Set(mergedPairs.map(\.providerTransactionID)),
            survivingTransactionIDs: Dictionary(
                uniqueKeysWithValues: mergedPairs.map { ($0.providerTransactionID, $0.retainedTransactionID) }
            ),
            context: context
        )
        try remapImportBatches(from: provider.id, to: retained.id, context: context)

        let providerAccountID = provider.id
        let remaining = try context.fetch(
            FetchDescriptor<TransactionEntity>(
                predicate: #Predicate { $0.accountID == providerAccountID }
            )
        )
        for leftover in remaining {
            leftover.account = retained
            leftover.accountID = retained.id
            leftover.identityKey = ProviderIdentityEncoding.transactionKey(
                source: retained.source,
                localAccountID: retained.id,
                sourceTransactionID: leftover.externalID
            )
            leftover.syncKey = leftover.identityKey
            moved += 1
        }
        context.delete(provider)
        retained.identityKey = plan.finalIdentityKey
        retained.externalID = plan.finalIdentityKey
        do {
            try assertUniqueIdentityKeys(in: context)
            try context.save()
        } catch {
            context.rollback()
            throw CashFlowError.persistence(
                message: "Couldn't repair duplicate accounts. \(error.localizedDescription)"
            )
        }
        widgetTimelineReloader.reloadCashFlowWidget()
        return DuplicateAccountRepairResult(
            retainedAccountID: command.retainedAccountID,
            removedAccountID: command.providerAccountID,
            deduplicatedCount: deduplicated,
            movedCount: moved
        )
    }

    private struct Pair {
        let retainedTransactionID: String
        let providerTransactionID: String
    }

    private struct Plan {
        let preview: DuplicateAccountRepairPreview
        let finalIdentityKey: String
        let exactPairs: [Pair]
        let likelyPairs: [Pair]
        let moveTransactionIDs: [String]
    }

    private func buildPlan(
        retaining retainedID: String,
        provider providerID: String,
        mergeLikely: Bool,
        context: ModelContext
    ) throws -> Plan {
        let retained = try fetchAccount(id: retainedID, context: context)
        let provider = try fetchAccount(id: providerID, context: context)
        guard retained.id != provider.id else {
            throw CashFlowError.persistence(message: "Choose two different accounts to repair.")
        }
        guard provider.providerState == .current else {
            throw CashFlowError.persistence(
                message: "Adopt identity only from a current provider account."
            )
        }

        let retainedTxs = try context.fetch(
            FetchDescriptor<TransactionEntity>(
                predicate: #Predicate { $0.accountID == retainedID }
            )
        )
        let providerTxs = try context.fetch(
            FetchDescriptor<TransactionEntity>(
                predicate: #Predicate { $0.accountID == providerID }
            )
        )

        var exact: [Pair] = []
        var usedRetained = Set<String>()
        var usedProvider = Set<String>()
            let retainedByExternal = Dictionary(grouping: retainedTxs, by: \.externalID)
        for providerTx in providerTxs {
            guard let matches = retainedByExternal[providerTx.externalID], matches.count == 1,
                  let retainedTx = matches.first,
                  usedRetained.insert(retainedTx.id).inserted,
                  usedProvider.insert(providerTx.id).inserted
            else { continue }
            exact.append(Pair(retainedTransactionID: retainedTx.id, providerTransactionID: providerTx.id))
        }

        var likely: [Pair] = []
        var ambiguous = 0
        let leftoverRetained = retainedTxs.filter { !usedRetained.contains($0.id) }
        let leftoverProvider = providerTxs.filter { !usedProvider.contains($0.id) }
        var fingerprintGroups: [String: (retained: [TransactionEntity], provider: [TransactionEntity])] = [:]
        for tx in leftoverRetained {
            let key = fingerprintKey(tx)
            fingerprintGroups[key, default: ([], [])].retained.append(tx)
        }
        for tx in leftoverProvider {
            let key = fingerprintKey(tx)
            fingerprintGroups[key, default: ([], [])].provider.append(tx)
        }
        for (_, group) in fingerprintGroups {
            if group.retained.count == 1, group.provider.count == 1 {
                likely.append(
                    Pair(
                        retainedTransactionID: group.retained[0].id,
                        providerTransactionID: group.provider[0].id
                    )
                )
                usedRetained.insert(group.retained[0].id)
                usedProvider.insert(group.provider[0].id)
            } else if group.retained.count + group.provider.count > 1,
                      !group.retained.isEmpty,
                      !group.provider.isEmpty
            {
                ambiguous += group.retained.count + group.provider.count
            }
        }

        let consumedProvider = Set(
            exact.map(\.providerTransactionID)
                + (mergeLikely ? likely.map(\.providerTransactionID) : [])
        )
        let actualMoves = providerTxs.filter { !consumedProvider.contains($0.id) }.map(\.id)

        let preview = DuplicateAccountRepairPreview(
            id: [
                retained.id,
                provider.id,
                retained.identityKey,
                provider.identityKey,
                mergeLikely ? "likely" : "exact",
                "\(exact.count)",
                "\(likely.count)",
                "\(ambiguous)",
                "\(actualMoves.count)",
                "\(retainedTxs.count)",
                "\(providerTxs.count)",
            ].joined(separator: "|"),
            retainedAccount: EntityMappers.account(from: retained),
            providerAccount: EntityMappers.account(from: provider),
            exactDuplicateCount: exact.count,
            likelyDuplicateCount: likely.count,
            ambiguousCount: ambiguous,
            movedCount: actualMoves.count
        )

        return Plan(
            preview: preview,
            finalIdentityKey: provider.identityKey,
            exactPairs: exact,
            likelyPairs: likely,
            moveTransactionIDs: actualMoves
        )
    }

    private func fingerprintKey(_ tx: TransactionEntity) -> String {
        let day = Calendar.current.startOfDay(for: tx.postedDate).timeIntervalSince1970
        let description = tx.transactionDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(day)|\(tx.amount)|\(tx.currencyCode)|\(description)"
    }

    private func applyMergedMetadata(
        _ merged: Transaction,
        to entity: TransactionEntity,
        account: AccountEntity,
        context: ModelContext
    ) throws {
        entity.account = account
        entity.accountID = account.id
        entity.categoryID = merged.categoryID.rawValue
        entity.userEditedCategory = merged.userEditedCategory
        entity.categoryLocked = merged.categoryLocked
        entity.enrichedTitle = merged.enrichedTitle
        entity.enrichedLocation = merged.enrichedLocation
        entity.titleSourceRaw = EntityMappers.titleSourceRaw(from: merged.titleSource)
        entity.categorySourceRaw = EntityMappers.categorySourceRaw(from: merged.categorySource)
        entity.ingestSourceRaw = merged.ingestSource.rawValue
        entity.importBatchID = merged.importBatchID?.rawValue
        entity.suppressedTagIDsData = try EntityMappers.encodeTagIDs(merged.suppressedTagIDs)
        let tagIDs = merged.tagIDs.map(\.rawValue)
        if tagIDs.isEmpty {
            entity.tags = []
        } else {
            let predicate = #Predicate<TagEntity> { tagIDs.contains($0.id) }
            entity.tags = try context.fetch(FetchDescriptor<TagEntity>(predicate: predicate))
        }
    }

    private func remapRules(
        from removedAccountID: String,
        to retainedAccountID: String,
        deletedTransactionIDs: Set<String>,
        survivingTransactionIDs: [String: String],
        context: ModelContext
    ) throws {
        let rules = try context.fetch(FetchDescriptor<CategorizationRuleEntity>())
        for rule in rules {
            var conditions = try JSONDecoder().decode(
                [CategorizationCondition].self,
                from: rule.conditionsData
            )
            var changed = false
            for index in conditions.indices {
                if case .accountID(let id) = conditions[index], id.rawValue == removedAccountID {
                    conditions[index] = .accountID(AccountID(retainedAccountID))
                    changed = true
                }
            }
            if changed {
                rule.conditionsData = try EntityMappers.encodeConditions(conditions)
            }
            if var snapshot = EntityMappers.decodeApplySnapshot(rule.applySnapshotData) {
                let priors = snapshot.priors.compactMap { prior -> CategorizationRuleTransactionPrior? in
                    if deletedTransactionIDs.contains(prior.transactionID.rawValue) {
                        if let survivor = survivingTransactionIDs[prior.transactionID.rawValue] {
                            return CategorizationRuleTransactionPrior(
                                transactionID: TransactionID(survivor),
                                categoryID: prior.categoryID,
                                userEditedCategory: prior.userEditedCategory,
                                tagIDs: prior.tagIDs,
                                enrichedTitle: prior.enrichedTitle,
                                enrichedLocation: prior.enrichedLocation,
                                titleSource: prior.titleSource,
                                categorySource: prior.categorySource
                            )
                        }
                        return nil
                    }
                    return prior
                }
                // Dedupe by transaction id keeping first.
                var seen = Set<String>()
                let uniquePriors = priors.filter { seen.insert($0.transactionID.rawValue).inserted }
                snapshot = CategorizationRuleApplySnapshot(
                    capturedAt: snapshot.capturedAt,
                    appliesCategory: snapshot.appliesCategory,
                    categoryID: snapshot.categoryID,
                    tagIDs: snapshot.tagIDs,
                    renameTitle: snapshot.renameTitle,
                    renameLocation: snapshot.renameLocation,
                    priors: uniquePriors
                )
                rule.applySnapshotData = try EntityMappers.encodeApplySnapshot(snapshot)
            }
        }
    }

    private func remapImportBatches(
        from removedAccountID: String,
        to retainedAccountID: String,
        context: ModelContext
    ) throws {
        let batches = try context.fetch(FetchDescriptor<ImportBatchEntity>())
        for batch in batches {
            if batch.accountID == removedAccountID {
                batch.accountID = retainedAccountID
            }
            if batch.createdAccountID == removedAccountID {
                batch.createdAccount = false
                batch.createdAccountID = nil
            }
        }
    }

    private func assertUniqueIdentityKeys(in context: ModelContext) throws {
        let accounts = try context.fetch(FetchDescriptor<AccountEntity>())
        var accountKeys = Set<String>()
        for account in accounts {
            guard accountKeys.insert(account.identityKey).inserted else {
                throw CashFlowError.persistence(
                    message: "Couldn't repair duplicate accounts because account identities would collide."
                )
            }
        }
        let transactions = try context.fetch(FetchDescriptor<TransactionEntity>())
        var transactionKeys = Set<String>()
        for transaction in transactions {
            guard transactionKeys.insert(transaction.identityKey).inserted else {
                throw CashFlowError.persistence(
                    message: "Couldn't repair duplicate accounts because transaction identities would collide."
                )
            }
        }
    }

    private func fetchAccount(id: String, context: ModelContext) throws -> AccountEntity {
        let predicate = #Predicate<AccountEntity> { $0.id == id }
        var descriptor = FetchDescriptor<AccountEntity>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else {
            throw CashFlowError.persistence(message: "Account not found.")
        }
        return entity
    }

    private func fetchTransaction(id: String, context: ModelContext) throws -> TransactionEntity? {
        let predicate = #Predicate<TransactionEntity> { $0.id == id }
        var descriptor = FetchDescriptor<TransactionEntity>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
