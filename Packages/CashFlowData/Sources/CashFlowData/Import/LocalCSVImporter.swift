import Foundation
import SwiftData
import CryptoKit
import CashFlowKit

public actor LocalCSVImporter: CSVImporting {
    private let modelContainer: ModelContainer
    private let enrichment: (any TransactionEnrichmentRunning)?
    private let detectMapping = DetectCSVColumnMappingUseCase()
    private let matchFingerprints = MatchImportFingerprintsUseCase()
    private let resolveConflicts = ResolveImportConflictsUseCase()

    public init(
        modelContainer: ModelContainer,
        enrichment: (any TransactionEnrichmentRunning)? = nil
    ) {
        self.modelContainer = modelContainer
        self.enrichment = enrichment
    }

    public func parsePreview(
        data: Data,
        fileName: String,
        mapping: CSVColumnMapping?
    ) async throws -> CSVImportPreview {
        _ = fileName
        let table = try CSVTextParser.parse(data)
        let sample = Array(table.rows.prefix(5))
        let resolved = mapping ?? detectMapping.execute(headers: table.headers, sampleRows: sample)
        guard resolved.isReady else {
            let rows = CSVRowMapper.mapRows(headers: table.headers, rawRows: table.rows, mapping: resolved)
            return CSVImportPreview(
                headers: table.headers,
                mapping: resolved,
                sampleRows: sample,
                rows: rows
            )
        }
        let rows = CSVRowMapper.mapRows(headers: table.headers, rawRows: table.rows, mapping: resolved)
        return CSVImportPreview(
            headers: table.headers,
            mapping: resolved,
            sampleRows: sample,
            rows: rows
        )
    }

    public func findConflicts(
        rows: [CSVImportRow],
        accountID: AccountID
    ) async throws -> [CSVImportConflict] {
        let context = ModelContext(modelContainer)
        let accountKey = accountID.rawValue
        let descriptor = FetchDescriptor<TransactionEntity>(
            predicate: #Predicate<TransactionEntity> { $0.accountID == accountKey }
        )
        let existing = try context.fetch(descriptor).map(EntityMappers.transaction(from:))
        return matchFingerprints.execute(
            rows: rows.filter(\.isValid),
            accountID: accountID,
            existing: existing
        )
    }

    public func commit(_ plan: CSVImportCommitPlan) async throws -> CSVImportCommitResult {
        let validRows = plan.rows.filter(\.isValid)
        guard !validRows.isEmpty else {
            throw CashFlowError.csvImport(message: "No valid rows to import.")
        }
        // Block if any invalid rows remain in the plan set.
        if plan.rows.contains(where: { !$0.isValid }) {
            throw CashFlowError.csvImport(
                message: "Fix or remove invalid rows before importing."
            )
        }

        let context = ModelContext(modelContainer)
        let batchID = ImportBatchID(UUID().uuidString)
        let importedAt = Date()

        let account: AccountEntity
        let createdAccount: Bool
        switch plan.accountChoice {
        case .existing(let accountID):
            let id = accountID.rawValue
            let predicate = #Predicate<AccountEntity> { $0.id == id }
            var descriptor = FetchDescriptor<AccountEntity>(predicate: predicate)
            descriptor.fetchLimit = 1
            guard let existing = try context.fetch(descriptor).first else {
                throw CashFlowError.csvImport(message: "Selected account was not found.")
            }
            account = existing
            createdAccount = false
        case .createNew(let name, let institutionName):
            let id = UUID().uuidString
            let identityKey = ProviderIdentityEncoding.csvAccountKey(localAccountID: id)
            let entity = AccountEntity(
                id: id,
                identityKey: identityKey,
                source: .csvImport,
                linkNamespace: id,
                providerAccountID: identityKey,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                institutionName: institutionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "CSV Import"
                    : institutionName.trimmingCharacters(in: .whitespacesAndNewlines),
                currencyCode: plan.currencyCode,
                balance: 0,
                balanceDate: importedAt,
                userEditedName: true,
                createdByImportBatchID: batchID.rawValue,
                providerState: .current
            )
            context.insert(entity)
            account = entity
            createdAccount = true
        }

        let rules = try loadRules(from: context)
        guard resolveConflicts.allResolved(plan.conflicts) else {
            throw CashFlowError.csvImport(message: "Choose an action for every duplicate before importing.")
        }
        let toInsert = resolveConflicts.rowsToInsert(allValidRows: validRows, conflicts: plan.conflicts)
        let replacements = resolveConflicts.replacements(conflicts: plan.conflicts)
        let skipped = resolveConflicts.skippedCount(conflicts: plan.conflicts)
        let keepBothCount = plan.conflicts.filter { $0.action == .keepBoth }.count

        var inserted = 0
        var replaced = 0

        let keepBothIDs = Set(plan.conflicts.filter { $0.action == .keepBoth }.map(\.importRow.id))

        for row in toInsert {
            let forceUnique = keepBothIDs.contains(row.id)
            let externalID = makeExternalID(
                for: row,
                account: account,
                forceUnique: forceUnique,
                batchID: batchID
            )
            try upsertCSVRow(
                row,
                externalID: externalID,
                account: account,
                batchID: batchID,
                rules: rules,
                replaceEntity: nil,
                context: context
            )
            inserted += 1
        }

        for (row, existingID) in replacements {
            let id = existingID.rawValue
            let predicate = #Predicate<TransactionEntity> { $0.id == id }
            var descriptor = FetchDescriptor<TransactionEntity>(predicate: predicate)
            descriptor.fetchLimit = 1
            let existing = try context.fetch(descriptor).first
            let externalID = existing?.externalID
                ?? makeExternalID(for: row, account: account, forceUnique: false, batchID: batchID)
            try upsertCSVRow(
                row,
                externalID: externalID,
                account: account,
                batchID: batchID,
                rules: rules,
                replaceEntity: existing,
                context: context
            )
            replaced += 1
        }

        // Ensure tags from CSV exist and attach on new/replaced rows that listed tags.
        try ensureAndAttachTags(for: toInsert + replacements.map(\.row), account: account, batchID: batchID, context: context)

        let batch = ImportBatchEntity(
            id: batchID.rawValue,
            fileName: plan.fileName,
            importedAt: importedAt,
            accountID: account.id,
            accountName: account.name,
            createdAccount: createdAccount,
            createdAccountID: createdAccount ? account.id : nil,
            insertedCount: inserted,
            skippedCount: skipped,
            replacedCount: replaced,
            keepBothCount: keepBothCount,
            statusRaw: ImportBatchStatus.active.rawValue
        )
        context.insert(batch)
        try context.save()

        if let enrichment {
            _ = await enrichment.enrichAfterSync(skipIfLargeBacklog: true, onProgress: nil)
        }

        return CSVImportCommitResult(batch: EntityMappers.importBatch(from: batch))
    }

    public func listBatches() async throws -> [ImportBatch] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ImportBatchEntity>(
            sortBy: [SortDescriptor(\.importedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map(EntityMappers.importBatch(from:))
    }

    public func deleteBatch(id: ImportBatchID) async throws -> ImportBatch {
        let context = ModelContext(modelContainer)
        let batchKey = id.rawValue
        let predicate = #Predicate<ImportBatchEntity> { $0.id == batchKey }
        var descriptor = FetchDescriptor<ImportBatchEntity>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let batch = try context.fetch(descriptor).first else {
            throw CashFlowError.csvImport(message: "Import batch not found.")
        }
        guard batch.statusRaw == ImportBatchStatus.active.rawValue else {
            return EntityMappers.importBatch(from: batch)
        }

        let txPredicate = #Predicate<TransactionEntity> { $0.importBatchID == batchKey }
        let txs = try context.fetch(FetchDescriptor<TransactionEntity>(predicate: txPredicate))
        for tx in txs {
            context.delete(tx)
        }

        if batch.createdAccount, let accountID = batch.createdAccountID {
            let accountPredicate = #Predicate<AccountEntity> { $0.id == accountID }
            var accountDescriptor = FetchDescriptor<AccountEntity>(predicate: accountPredicate)
            accountDescriptor.fetchLimit = 1
            if let account = try context.fetch(accountDescriptor).first {
                let remaining = account.transactions.filter { $0.importBatchID != batchKey }
                if remaining.isEmpty {
                    context.delete(account)
                }
            }
        }

        batch.statusRaw = ImportBatchStatus.deleted.rawValue
        batch.deletedAt = Date()
        try context.save()
        return EntityMappers.importBatch(from: batch)
    }

    // MARK: - Private

    private func loadRules(from context: ModelContext) throws -> [CategorizationRule] {
        let descriptor = FetchDescriptor<CategorizationRuleEntity>(
            sortBy: [
                SortDescriptor(\.priority, order: .forward),
                SortDescriptor(\.id, order: .forward),
            ]
        )
        return try context.fetch(descriptor).map { try EntityMappers.categorizationRule(from: $0) }
    }

    private func makeExternalID(
        for row: CSVImportRow,
        account: AccountEntity,
        forceUnique: Bool,
        batchID: ImportBatchID
    ) -> String {
        if !forceUnique,
           let external = row.externalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !external.isEmpty
        {
            return external
        }
        let fp = TransactionFingerprint(
            accountID: AccountID(account.id),
            postedDate: row.postedDate,
            amount: row.amount,
            description: row.description
        )
        let material = "\(fp.dayKey)|\(fp.amount)|\(fp.description)|\(batchID.rawValue)|\(row.rowIndex)|\(forceUnique)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "csv:\(hex.prefix(24))"
    }

    private func upsertCSVRow(
        _ row: CSVImportRow,
        externalID: String,
        account: AccountEntity,
        batchID: ImportBatchID,
        rules: [CategorizationRule],
        replaceEntity: TransactionEntity?,
        context: ModelContext
    ) throws {
        let identityKey = ProviderIdentityEncoding.transactionKey(
            source: .csvImport,
            localAccountID: account.id,
            sourceTransactionID: externalID
        )
        let suggested = MapCSVCategoryUseCase.categoryID(forName: row.categoryName)
            ?? SystemCategory.undefined.id

        let remoteDomain = Transaction(
            id: TransactionID(identityKey),
            accountID: AccountID(account.id),
            externalID: externalID,
            amount: row.amount,
            postedDate: row.postedDate,
            description: row.description,
            categoryID: suggested,
            currencyCode: row.currencyCode.isEmpty ? account.currencyCode : row.currencyCode,
            userEditedCategory: false,
            isPending: row.isPending,
            categoryLocked: false,
            ingestSource: .csvImport,
            importBatchID: batchID
        )

        let preferSuggested = MapCSVCategoryUseCase.categoryID(forName: row.categoryName) != nil
            && suggested != SystemCategory.undefined.id

        if let existing = replaceEntity {
            let local = EntityMappers.transaction(from: existing)
            let merged = MergeSyncPolicy.merge(
                local: local,
                remote: remoteDomain,
                rules: rules,
                preferSuggestedCategory: preferSuggested
            )
            existing.externalID = externalID
            existing.identityKey = identityKey
            existing.syncKey = identityKey
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
            existing.enrichedTitle = row.title ?? merged.enrichedTitle
            existing.enrichedLocation = row.location ?? merged.enrichedLocation
            if row.title != nil {
                existing.titleSourceRaw = TitleSource.user.rawValue
            } else {
                existing.titleSourceRaw = EntityMappers.titleSourceRaw(from: merged.titleSource)
            }
            existing.categorySourceRaw = EntityMappers.categorySourceRaw(from: merged.categorySource)
            existing.ingestSourceRaw = IngestSource.csvImport.rawValue
            existing.importBatchID = batchID.rawValue
            existing.suppressedTagIDsData = try EntityMappers.encodeTagIDs(merged.suppressedTagIDs)
        } else {
            let syncPredicate = #Predicate<TransactionEntity> { $0.identityKey == identityKey }
            var syncDescriptor = FetchDescriptor<TransactionEntity>(predicate: syncPredicate)
            syncDescriptor.fetchLimit = 1
            if let existing = try context.fetch(syncDescriptor).first {
                try upsertCSVRow(
                    row,
                    externalID: externalID,
                    account: account,
                    batchID: batchID,
                    rules: rules,
                    replaceEntity: existing,
                    context: context
                )
                return
            }

            let merged = MergeSyncPolicy.merge(
                local: nil,
                remote: remoteDomain,
                rules: rules,
                preferSuggestedCategory: preferSuggested
            )
            let entity = TransactionEntity(
                id: UUID().uuidString,
                externalID: externalID,
                accountID: account.id,
                amount: merged.amount,
                postedDate: merged.postedDate,
                transactionDescription: merged.description,
                categoryID: merged.categoryID.rawValue,
                currencyCode: merged.currencyCode,
                userEditedCategory: merged.userEditedCategory,
                isPending: row.isPending,
                identityKey: identityKey,
                account: account,
                categoryLocked: false,
                enrichedTitle: row.title ?? merged.enrichedTitle,
                enrichedLocation: row.location ?? merged.enrichedLocation,
                titleSourceRaw: row.title != nil
                    ? TitleSource.user.rawValue
                    : EntityMappers.titleSourceRaw(from: merged.titleSource),
                categorySourceRaw: EntityMappers.categorySourceRaw(from: merged.categorySource),
                suppressedTagIDsData: try EntityMappers.encodeTagIDs(merged.suppressedTagIDs),
                ingestSourceRaw: IngestSource.csvImport.rawValue,
                importBatchID: batchID.rawValue
            )
            context.insert(entity)
        }
    }

    private func ensureAndAttachTags(
        for rows: [CSVImportRow],
        account: AccountEntity,
        batchID: ImportBatchID,
        context: ModelContext
    ) throws {
        let allNames = Set(rows.flatMap(\.tags).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !allNames.isEmpty else { return }

        var tagsByName: [String: TagEntity] = [:]
        let existingTags = try context.fetch(FetchDescriptor<TagEntity>())
        for tag in existingTags {
            tagsByName[tag.name.lowercased()] = tag
        }
        for name in allNames {
            let key = name.lowercased()
            if tagsByName[key] == nil {
                let tag = TagEntity(id: UUID().uuidString, name: name)
                context.insert(tag)
                tagsByName[key] = tag
            }
        }

        let batchKey = batchID.rawValue
        let accountKey = account.id
        let descriptor = FetchDescriptor<TransactionEntity>(
            predicate: #Predicate<TransactionEntity> {
                $0.importBatchID == batchKey && $0.accountID == accountKey
            }
        )
        let entities = try context.fetch(descriptor)
        // Match by row fingerprint for tag attach
        for entity in entities {
            guard let row = rows.first(where: {
                $0.amount == entity.amount
                    && $0.description == entity.transactionDescription
                    && Calendar.current.isDate($0.postedDate, inSameDayAs: entity.postedDate)
            }) else { continue }
            guard !row.tags.isEmpty else { continue }
            var byID = Dictionary(uniqueKeysWithValues: entity.tags.map { ($0.id, $0) })
            for name in row.tags {
                if let tag = tagsByName[name.lowercased()] {
                    byID[tag.id] = tag
                }
            }
            entity.tags = Array(byID.values)
        }
    }
}
