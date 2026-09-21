import Foundation
import Observation
import SwiftUI
import CashFlowKit

@MainActor
@Observable
final class SettingsViewModel {
    let ruleRepository: any CategorizationRuleRepository
    let ruleApplying: any CategorizationRuleApplying
    let accountRepository: any AccountRepository
    let tagRepository: any TagRepository
    let ruleDrafting: any CategorizationRuleDrafting
    let availabilityChecker: any OnDeviceModelAvailabilityChecking
    let appLock: AppLockViewModel
    let syncServing: any SyncServing
    let backgroundEnrichment: any BackgroundEnrichmentScheduling
    let cleanupState: any TitleCleanupStateStoring
    let localDataExport: any LocalDataExporting
    let csvImport: any CSVImporting
    let filters: TransactionFilterSession
    let transactionRepository: any TransactionRepository

    var historyStatus: HistoryImportStatus?
    var selectedLookback: HistoryLookbackYears = .default
    var cleanupErrorMessage: String?
    var isCleaningUpTitles = false
    var cleanupPhase: EnrichmentProgress.Phase = .running
    var cleanupDetail: String?
    var cleanupCompleted = 0
    var cleanupTotal = 0
    var modelAvailability: OnDeviceModelAvailability = .unavailable
    var ruleCount = 0
    var isExporting = false
    var exportErrorMessage: String?
    var exportFileURL: URL?
    var showExportSheet = false
    var exportAccounts: [Account] = []
    var exportTags: [Tag] = []
    var exportMatchCount: Int?

    // CSV import
    var showImportSheet = false
    var importStep: ImportCSVStep = .pickFile
    var importFileData: Data?
    var importFileName = "import.csv"
    var importPreview: CSVImportPreview?
    var importMapping = CSVColumnMapping()
    var importAccounts: [Account] = []
    var importAccountMode: ImportAccountMode = .createNew
    var importSelectedAccountID: AccountID?
    var importNewAccountName = ""
    var importNewInstitutionName = "CSV Import"
    var importConflicts: [CSVImportConflict] = []
    var isImporting = false
    var importErrorMessage: String?
    var importBatches: [ImportBatch] = []
    var importHistoryErrorMessage: String?

    /// True after a drain stops early with titles still remaining — show Resume.
    /// Mirrored to `cleanupState` so a relaunch still offers Resume.
    private(set) var isTitleCleanupPaused: Bool
    /// True while `startTitleCleanup` owns the drain lifecycle (ignore hub `nil` races).
    private var ownsActiveDrain = false
    /// Set by Stop during the reload/availability window, before the scheduler session exists.
    private var stopRequested = false

    private var progressObservation: Task<Void, Never>?
    private let resolveConflicts = ResolveImportConflictsUseCase()

    private let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    init(
        filters: TransactionFilterSession,
        transactionRepository: any TransactionRepository,
        ruleRepository: any CategorizationRuleRepository,
        ruleApplying: any CategorizationRuleApplying,
        accountRepository: any AccountRepository,
        tagRepository: any TagRepository,
        ruleDrafting: any CategorizationRuleDrafting,
        availabilityChecker: any OnDeviceModelAvailabilityChecking,
        appLock: AppLockViewModel,
        syncServing: any SyncServing,
        backgroundEnrichment: any BackgroundEnrichmentScheduling,
        cleanupState: any TitleCleanupStateStoring,
        localDataExport: any LocalDataExporting,
        csvImport: any CSVImporting
    ) {
        self.filters = filters
        self.transactionRepository = transactionRepository
        self.ruleRepository = ruleRepository
        self.ruleApplying = ruleApplying
        self.accountRepository = accountRepository
        self.tagRepository = tagRepository
        self.ruleDrafting = ruleDrafting
        self.availabilityChecker = availabilityChecker
        self.appLock = appLock
        self.syncServing = syncServing
        self.backgroundEnrichment = backgroundEnrichment
        self.cleanupState = cleanupState
        self.localDataExport = localDataExport
        self.csvImport = csvImport
        self.isTitleCleanupPaused = cleanupState.isPaused()
    }

    private func setTitleCleanupPaused(_ paused: Bool) {
        isTitleCleanupPaused = paused
        cleanupState.setPaused(paused)
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var requireLockBinding: Binding<Bool> {
        Binding(
            get: { self.appLock.isEnabled },
            set: { newValue in
                Task { await self.appLock.setEnabled(newValue) }
            }
        )
    }

    var isHistoryComplete: Bool {
        historyStatus?.historyComplete == true
    }

    var historyCoverageText: String {
        guard let status = historyStatus else { return "Not linked yet" }
        if status.historyComplete {
            if let earliest = status.earliestFetchedDisplay(formatter: monthFormatter) {
                return "History imported back to \(earliest)"
            }
            return "History import complete"
        }
        if let earliest = status.earliestFetchedDisplay(formatter: monthFormatter) {
            return "Imported back to \(earliest)"
        }
        return "Waiting to import history"
    }

    var showHistoryProgress: Bool {
        guard let status = historyStatus else { return false }
        return !status.historyComplete
    }

    var isCoolingDown: Bool {
        isCleaningUpTitles && cleanupPhase == .coolingDown
    }

    var isTitleCleanupComplete: Bool {
        !isCleaningUpTitles && historyStatus?.needsCleanup != true
    }

    var showTitleCleanupProgress: Bool {
        isCleaningUpTitles
    }

    var titleCleanupText: String {
        if isCleaningUpTitles {
            if isCoolingDown {
                if cleanupTotal > 0 {
                    return "Waiting for Apple Intelligence… \(cleanupCompleted) of \(cleanupTotal)"
                }
                return "Waiting for Apple Intelligence…"
            }
            if cleanupTotal > 0 {
                return "Improving transactions… \(cleanupCompleted) of \(cleanupTotal)"
            }
            return "Improving transactions…"
        }
        guard let status = historyStatus else { return "—" }
        if !status.needsCleanup {
            return finishedTitlesCopy
        }
        if isTitleCleanupPaused {
            return "Paused · \(status.untitledCount) titles · \(status.undefinedCount) undefined"
        }
        let lookups = status.distinctMerchantLookupsRemaining
        if status.needsTitleCleanup, status.needsCategoryCleanup {
            return "\(status.untitledCount) titles · \(status.undefinedCount) undefined · \(lookups) merchant lookups"
        }
        if status.needsCategoryCleanup {
            return "\(status.undefinedCount) undefined categories left"
        }
        return "\(status.untitledCount) titles left · \(lookups) merchant lookups"
    }

    var finishedTitlesCopy: String {
        switch ruleCount {
        case 0:
            return "All transactions processed"
        case 1:
            return "All transactions processed with your 1 rule applied"
        default:
            return "All transactions processed with your \(ruleCount) rules applied"
        }
    }

    var titleCleanupFraction: Double {
        guard cleanupTotal > 0 else { return 0 }
        return min(1, Double(cleanupCompleted) / Double(cleanupTotal))
    }

    var titleCleanupFootnote: String? {
        if isCleaningUpTitles {
            if isCoolingDown {
                return cleanupDetail
                    ?? "Apple Intelligence hit a temporary limit. Waiting to continue…"
            }
            return "Keep the app open — background processing is slower and more likely to pause."
        }
        if isTitleCleanupComplete {
            return nil
        }
        switch modelAvailability {
        case .available:
            return "Uses on-device Apple Intelligence. Keep the app open to process titles quickest. The rest can be completed in the background"
        case .appleIntelligenceOff:
            return "Turn on Apple Intelligence in Settings to clean up titles automatically. You can still rename with rules."
        case .modelNotReady:
            return "Apple Intelligence is downloading or unavailable right now. Try again when it’s ready, or rename with rules."
        case .deviceNotEligible, .unavailable:
            return "This device can’t run on-device title cleanup. Use rename rules to clean titles."
        }
    }

    var canCleanUpTitles: Bool {
        historyStatus?.needsCleanup == true
            && !isCleaningUpTitles
            && modelAvailability == .available
    }

    var canStopTitleCleanup: Bool { isCleaningUpTitles }

    var titleCleanupActionTitle: String {
        if isCleaningUpTitles { return "Stop" }
        return isTitleCleanupPaused ? "Resume" : "Clean up transactions"
    }

    /// Shows a badge on the Settings tab while cleanup runs.
    var settingsTabBadge: String? {
        isCleaningUpTitles ? "…" : nil
    }

    func startObservingEnrichmentProgress() {
        progressObservation?.cancel()
        progressObservation = Task { [weak self] in
            guard let self else { return }
            for await progress in self.backgroundEnrichment.enrichmentProgressUpdates() {
                guard !Task.isCancelled else { return }
                await self.applyEnrichmentProgress(progress)
            }
        }
    }

    func stopObservingEnrichmentProgress() {
        progressObservation?.cancel()
        progressObservation = nil
    }

    /// - Parameter refreshTitleBacklog: When `false`, bank-history fields refresh but the
    ///   idle "N titles left" line keeps its previous snapshot. Use after scene-active
    ///   reloads so opportunistic work can't change the number under the user's nose.
    func reloadHistoryStatus(refreshTitleBacklog: Bool = true) async {
        let previous = historyStatus
        async let status = syncServing.historyImportStatus()
        async let availability = availabilityChecker.availability()
        async let rules = loadRuleCount()
        var next = await status
        if !refreshTitleBacklog, !isCleaningUpTitles, let previous {
            next = next?.preservingTitleBacklog(from: previous)
        }
        historyStatus = next
        modelAvailability = await availability
        ruleCount = await rules
        if let lookback = historyStatus?.lookback {
            selectedLookback = lookback
        }
        if historyStatus?.needsCleanup != true {
            setTitleCleanupPaused(false)
        }
    }

    func applyLookback(_ lookback: HistoryLookbackYears) async {
        selectedLookback = lookback
        do {
            try await syncServing.setHistoryLookback(lookback)
            await reloadHistoryStatus()
        } catch {
            cleanupErrorMessage = CashFlowError.userFacingMessage(
                for: error,
                fallback: "Couldn't update history lookback."
            )
        }
    }

    /// Shared entry point for Settings button and the first-sync prompt.
    func startTitleCleanup(expectedUntitled: Int? = nil) async {
        // Already showing as running — Stop is the way out. Resume while the UI is
        // paused still reaches `runFullEnrichmentDrain`, which reattaches to a live
        // pass or waits out a stopping one then starts fresh.
        if isCleaningUpTitles { return }
        stopRequested = false

        cleanupErrorMessage = nil
        ownsActiveDrain = true
        isCleaningUpTitles = true
        cleanupPhase = .running
        cleanupDetail = nil
        setTitleCleanupPaused(false)
        // Re-read the backlog before a user-started run — the idle line may be a
        // preserved snapshot that shouldn't drive expected totals.
        if expectedUntitled == nil {
            await reloadHistoryStatus(refreshTitleBacklog: true)
        }
        let expected = expectedUntitled
            ?? ((historyStatus?.untitledCount ?? 0) + (historyStatus?.undefinedCount ?? 0))
        guard expected > 0 else {
            ownsActiveDrain = false
            isCleaningUpTitles = false
            setTitleCleanupPaused(false)
            return
        }
        cleanupCompleted = 0
        cleanupTotal = max(expected, 1)

        let availability = await availabilityChecker.availability()
        modelAvailability = availability
        guard availability == .available else {
            isCleaningUpTitles = false
            ownsActiveDrain = false
            cleanupErrorMessage = titleCleanupFootnote
            await reloadHistoryStatus(refreshTitleBacklog: true)
            return
        }
        if stopRequested {
            ownsActiveDrain = false
            isCleaningUpTitles = false
            cleanupPhase = .running
            cleanupDetail = nil
            await reloadHistoryStatus()
            setTitleCleanupPaused(historyStatus?.needsCleanup == true)
            return
        }

        let outcome = await backgroundEnrichment.runFullEnrichmentDrain(expectedTotal: expected) {
            [weak self] completed, total in
            Task { @MainActor in
                self?.cleanupCompleted = completed
                self?.cleanupTotal = max(total, completed, 1)
            }
        }

        ownsActiveDrain = false
        isCleaningUpTitles = false
        cleanupPhase = .running
        cleanupDetail = nil
        await reloadHistoryStatus()
        applyDrainOutcome(outcome)
    }

    func stopTitleCleanup() async {
        stopRequested = true
        await backgroundEnrichment.stopFullEnrichmentDrain()
        if !ownsActiveDrain {
            isCleaningUpTitles = false
            cleanupPhase = .running
            cleanupDetail = nil
            await reloadHistoryStatus()
            setTitleCleanupPaused(historyStatus?.needsCleanup == true)
        }
    }

    /// Back-compat name used by the Settings button.
    func cleanUpTitles() async {
        await startTitleCleanup()
    }

    func prepareExportSheet() async {
        showExportSheet = true
        exportErrorMessage = nil
        exportMatchCount = nil
        exportAccounts = (try? await accountRepository.fetchAll()) ?? []
        exportTags = (try? await tagRepository.fetchAll()) ?? []
        await refreshExportMatchCount()
    }

    func refreshExportMatchCount() async {
        do {
            let matching = try await transactionRepository.fetchAllMatching(filter: filters.filter)
            exportMatchCount = matching.count
        } catch {
            exportMatchCount = nil
        }
    }

    func exportLocalData() async {
        guard !isExporting else { return }
        isExporting = true
        exportErrorMessage = nil
        defer { isExporting = false }
        do {
            let data = try await localDataExport.exportCSV(filter: filters.filter)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let name = "CashFlow-\(formatter.string(from: Date())).csv"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try data.write(to: url, options: .atomic)
            exportFileURL = url
            showExportSheet = false
        } catch {
            exportFileURL = nil
            exportErrorMessage = CashFlowError.userFacingMessage(
                for: error,
                fallback: "Couldn’t export CSV."
            )
        }
    }

    func clearExportShare() {
        exportFileURL = nil
    }

    // MARK: - CSV import

    var canContinueImportAccountStep: Bool {
        switch importAccountMode {
        case .existing:
            return importSelectedAccountID != nil
        case .createNew:
            return !importNewAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var importConflictsResolved: Bool {
        resolveConflicts.allResolved(importConflicts)
    }

    var canConfirmImport: Bool {
        guard !isImporting else { return false }
        guard (importPreview?.invalidRowCount ?? 0) == 0 else { return false }
        guard (importPreview?.validRowCount ?? 0) > 0 else { return false }
        return importConflictsResolved
    }

    func beginImportFlow() {
        cancelImportFlow()
        showImportSheet = true
        importStep = .pickFile
    }

    func cancelImportFlow() {
        showImportSheet = false
        importStep = .pickFile
        importFileData = nil
        importFileName = "import.csv"
        importPreview = nil
        importMapping = CSVColumnMapping()
        importConflicts = []
        importErrorMessage = nil
        isImporting = false
        importNewAccountName = ""
        importNewInstitutionName = "CSV Import"
        importSelectedAccountID = nil
        importAccountMode = .createNew
    }

    func handleImportFilePicked(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            importFileData = data
            importFileName = url.lastPathComponent
            let preview = try await csvImport.parsePreview(
                data: data,
                fileName: importFileName,
                mapping: nil
            )
            importPreview = preview
            importMapping = preview.mapping
            importAccounts = (try? await accountRepository.fetchAll()) ?? []
            if importAccounts.isEmpty {
                importAccountMode = .createNew
            } else {
                importAccountMode = .existing
                importSelectedAccountID = importAccounts.first?.id
            }
            importStep = .mapping
        } catch {
            importErrorMessage = CashFlowError.userFacingMessage(
                for: error,
                fallback: "Couldn't open that CSV file."
            )
        }
    }

    func setImportColumn(_ column: CSVImportColumn, at index: Int) {
        if column == .ignore {
            importMapping.assignments.removeValue(forKey: index)
        } else {
            // Clear prior assignment of the same logical column (except ignore).
            importMapping.assignments = importMapping.assignments.filter { $0.value != column }
            importMapping.assignments[index] = column
        }
        importMapping.presetName = nil
    }

    func reparseImportWithCurrentMapping() async {
        guard let data = importFileData else { return }
        do {
            let preview = try await csvImport.parsePreview(
                data: data,
                fileName: importFileName,
                mapping: importMapping
            )
            importPreview = preview
            importMapping = preview.mapping
        } catch {
            importErrorMessage = CashFlowError.userFacingMessage(
                for: error,
                fallback: "Couldn't parse CSV with that mapping."
            )
        }
    }

    func prepareImportConflicts() async {
        guard importPreview != nil else { return }
        await reparseImportWithCurrentMapping()
        guard let preview = importPreview else { return }
        if preview.invalidRowCount > 0 {
            importErrorMessage = "\(preview.invalidRowCount) row(s) couldn't be parsed. Adjust column mapping first."
            importStep = .mapping
            return
        }

        let accountID: AccountID
        switch importAccountMode {
        case .existing:
            guard let selected = importSelectedAccountID else { return }
            accountID = selected
        case .createNew:
            // Conflicts only against existing account; new account has none.
            importConflicts = []
            importStep = .conflicts
            return
        }

        do {
            importConflicts = try await csvImport.findConflicts(
                rows: preview.rows.filter(\.isValid),
                accountID: accountID
            )
            importStep = .conflicts
        } catch {
            importErrorMessage = CashFlowError.userFacingMessage(
                for: error,
                fallback: "Couldn't check for duplicates."
            )
        }
    }

    func applyBulkConflictAction(_ action: ImportConflictAction) {
        resolveConflicts.applyBulk(action, to: &importConflicts)
    }

    func setConflictAction(_ action: ImportConflictAction?, for id: String) {
        resolveConflicts.setAction(action, forConflictID: id, in: &importConflicts)
    }

    func commitImport() async {
        guard let preview = importPreview, !isImporting else { return }
        guard canConfirmImport else {
            if !importConflictsResolved {
                importErrorMessage = "Choose an action for every duplicate before importing."
            }
            return
        }
        isImporting = true
        importStep = .confirming
        defer { isImporting = false }
        do {
            let accountChoice: CSVImportAccountChoice
            switch importAccountMode {
            case .existing:
                guard let id = importSelectedAccountID else {
                    throw CashFlowError.csvImport(message: "Select an account.")
                }
                accountChoice = .existing(id)
            case .createNew:
                accountChoice = .createNew(
                    name: importNewAccountName,
                    institutionName: importNewInstitutionName
                )
            }
            let plan = CSVImportCommitPlan(
                fileName: importFileName,
                rows: preview.rows.filter(\.isValid),
                conflicts: importConflicts,
                accountChoice: accountChoice
            )
            _ = try await csvImport.commit(plan)
            await reloadImportBatches()
            cancelImportFlow()
        } catch {
            importStep = .conflicts
            importErrorMessage = CashFlowError.userFacingMessage(
                for: error,
                fallback: "Couldn't import CSV."
            )
        }
    }

    func reloadImportBatches() async {
        importBatches = (try? await csvImport.listBatches()) ?? []
    }

    func deleteImportBatch(_ id: ImportBatchID) async {
        do {
            _ = try await csvImport.deleteBatch(id: id)
            await reloadImportBatches()
        } catch {
            importHistoryErrorMessage = CashFlowError.userFacingMessage(
                for: error,
                fallback: "Couldn't delete that import."
            )
        }
    }

    private func loadRuleCount() async -> Int {
        (try? await ruleRepository.fetchAll())?.count ?? 0
    }

    private func applyDrainOutcome(_ outcome: EnrichmentDrainOutcome) {
        switch outcome {
        case .completed:
            setTitleCleanupPaused(false)
            cleanupErrorMessage = nil
        case .interruptedByRateLimit, .interrupted:
            setTitleCleanupPaused(historyStatus?.needsCleanup == true)
            cleanupErrorMessage = nil
        }
    }

    private func applyEnrichmentProgress(_ progress: EnrichmentProgress?) async {
        if let progress, progress.isRunning {
            isCleaningUpTitles = true
            cleanupPhase = progress.phase
            cleanupDetail = progress.detail
            cleanupCompleted = progress.completed
            cleanupTotal = max(progress.total, progress.completed, cleanupTotal, 1)
        } else if isCleaningUpTitles, !ownsActiveDrain {
            isCleaningUpTitles = false
            cleanupPhase = .running
            cleanupDetail = nil
            await reloadHistoryStatus()
        }
    }
}
