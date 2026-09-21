import Foundation
import SwiftData
import CashFlowKit
import CashFlowData

@MainActor
final class DependencyContainer {
    let modelContainer: ModelContainer
    let transactionRepository: any TransactionRepository
    let accountRepository: any AccountRepository
    let categorizationRuleRepository: any CategorizationRuleRepository
    let categorizationRuleApplying: any CategorizationRuleApplying
    let tagRepository: any TagRepository
    let bankLinking: CompositeBankLinkingService
    let syncServing: SyncCoordinator
    let connectionLifecycle: any ConnectionLifecycleServing
    let resetter: LocalDataResetter
    let connectivity: ConnectivityMonitor
    let calculateNetCashFlow: CalculateNetCashFlowUseCase
    let calculateSpendingBreakdown: CalculateSpendingBreakdownUseCase
    let appLockPreferences: any AppLockPreferencesStoring
    let titleCleanupState: any TitleCleanupStateStoring
    let deviceAuthentication: any DeviceAuthenticationServing
    let onDeviceModelAvailability: any OnDeviceModelAvailabilityChecking
    let descriptionEnricher: any TransactionDescriptionEnriching
    let categoryEnricher: any TransactionCategoryEnriching
    let transactionEnrichment: any TransactionEnrichmentRunning
    let transactionAssistant: any TransactionAssistantServing
    let categorizationRuleDrafting: any CategorizationRuleDrafting
    let backgroundEnrichment: any BackgroundEnrichmentScheduling
    let localDataExport: any LocalDataExporting
    let csvImport: any CSVImporting
    let widgetTimelineReloader: any WidgetTimelineReloading
    let titleCleanupLiveActivity: TitleCleanupLiveActivityPresenter
    let accountDuplicateRepair: RepairDuplicateAccountUseCase
    let useLargeDemoSeed: Bool

    /// Launch-safe: V3 performs one explicit ledger reset; later load failures fall back without wiping.
    convenience init(largeDemoSeed: Bool = false, uiTesting: Bool = false) {
        if uiTesting {
            do {
                let model = try ModelContainerFactory.make(inMemory: true, appGroupID: nil)
                self.init(modelContainer: model, largeDemoSeed: largeDemoSeed, uiTesting: true)
            } catch {
                preconditionFailure("UITest in-memory ModelContainer failed: \(error)")
            }
            return
        }
        // XCTest / unsigned CI hosts often lack App Group entitlements; SwiftData traps
        // (does not throw) if `groupContainer` is requested without them.
        let appGroupID = Self.isRunningUnitTests
            ? nil
            : NetSnapshotStore.defaultAppGroupID
        self.init(
            modelContainer: ModelContainerFactory.makeResilient(appGroupID: appGroupID),
            largeDemoSeed: largeDemoSeed,
            uiTesting: false
        )
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Tests / previews that need an explicit in-memory (or throw-on-failure) stack.
    convenience init(inMemory: Bool, largeDemoSeed: Bool = false) throws {
        let container = try ModelContainerFactory.make(
            inMemory: inMemory,
            appGroupID: NetSnapshotStore.defaultAppGroupID
        )
        self.init(modelContainer: container, largeDemoSeed: largeDemoSeed, uiTesting: false)
    }

    private init(modelContainer: ModelContainer, largeDemoSeed: Bool, uiTesting: Bool) {
        EnrichmentSanitizer.runIfNeeded(modelContainer: modelContainer)
        EnrichmentSkipReviver.runIfNeeded(modelContainer: modelContainer)
        self.useLargeDemoSeed = largeDemoSeed
        self.modelContainer = modelContainer
        let transactionRepository = SwiftDataTransactionRepository(modelContainer: modelContainer)
        self.transactionRepository = transactionRepository
        self.accountRepository = SwiftDataAccountRepository(modelContainer: modelContainer)
        let categorizationRuleRepository = SwiftDataCategorizationRuleRepository(
            modelContainer: modelContainer
        )
        self.categorizationRuleRepository = categorizationRuleRepository
        self.categorizationRuleApplying = CategorizationRuleReapplier(
            modelContainer: modelContainer
        )
        let tagRepository = SwiftDataTagRepository(modelContainer: modelContainer)
        self.tagRepository = tagRepository

        // One coordinator for the whole process: it is the mutex and the pacing/rate-limit
        // state for every on-device model call, so a second instance would let enrichment
        // and the assistant run concurrently.
        let workCoordinator = FoundationModelsWorkCoordinator()
        let availability = AppleIntelligenceAvailabilityChecker(workCoordinator: workCoordinator)
        self.onDeviceModelAvailability = availability
        let descriptionEnricher = DescriptionEnricherFactory.make(
            availability: availability,
            workCoordinator: workCoordinator
        )
        self.descriptionEnricher = descriptionEnricher
        let categoryEnricher = CategoryEnricherFactory.make(
            availability: availability,
            workCoordinator: workCoordinator
        )
        self.categoryEnricher = categoryEnricher
        let enrichment = TransactionEnrichmentCoordinator(
            availability: availability,
            descriptionEnricher: descriptionEnricher,
            categoryEnricher: categoryEnricher,
            transactionRepository: transactionRepository,
            accountRepository: accountRepository,
            ruleRepository: categorizationRuleRepository,
            memoStore: MerchantParseMemoStore(modelContainer: modelContainer),
            workCoordinator: workCoordinator
        )
        self.transactionEnrichment = enrichment
        self.transactionAssistant = TransactionAssistantFactory.make(
            availability: availability,
            transactionRepository: transactionRepository,
            tagRepository: tagRepository,
            accountRepository: accountRepository,
            ruleRepository: categorizationRuleRepository,
            ruleApplying: categorizationRuleApplying,
            workCoordinator: workCoordinator
        )
        self.categorizationRuleDrafting = CategorizationRuleDraftingFactory.make(
            availability: availability,
            workCoordinator: workCoordinator
        )

        let demo = DemoBankLinkingService(
            seedSize: largeDemoSeed ? .large : .standard
        )
        let simpleFIN = SimpleFINBankLinkingService()
        let linking = CompositeBankLinkingService(demo: demo, simpleFIN: simpleFIN)
        self.bankLinking = linking
        // WidgetCenter can stall on unsigned CI simulators; UITests use a no-op.
        let widgetTimelineReloader: any WidgetTimelineReloading = uiTesting
            ? NoOpWidgetTimelineReloader()
            : WidgetKitTimelineReloader()
        self.widgetTimelineReloader = widgetTimelineReloader
        let snapshotStore = NetSnapshotStore()
        let sync = SyncCoordinator(
            modelContainer: modelContainer,
            bankLinking: linking,
            widgetTimelineReloader: widgetTimelineReloader,
            // Skip post-sync enrichment in UITests — Foundation Models can hang on CI.
            enrichment: uiTesting ? nil : enrichment
        )
        self.syncServing = sync
        let resetter = LocalDataResetter(
            modelContainer: modelContainer,
            snapshotStore: snapshotStore,
            widgetTimelineReloader: widgetTimelineReloader
        )
        self.resetter = resetter
        self.connectionLifecycle = ConnectionLifecycleService(
            bankLinking: linking,
            sync: sync,
            resetter: resetter
        )
        self.connectivity = ConnectivityMonitor()
        self.calculateNetCashFlow = CalculateNetCashFlowUseCase()
        self.calculateSpendingBreakdown = CalculateSpendingBreakdownUseCase()
        self.appLockPreferences = UserDefaultsAppLockPreferencesStore()
        self.titleCleanupState = UserDefaultsTitleCleanupStateStore()
        self.deviceAuthentication = LocalAuthenticationDeviceAuthenticator()
        let background = BackgroundEnrichmentScheduler(
            enrichment: enrichment,
            sync: sync,
            workCoordinator: workCoordinator
        )
        self.backgroundEnrichment = background
        self.titleCleanupLiveActivity = TitleCleanupLiveActivityPresenter(
            enabled: !uiTesting,
            backgroundEnrichment: background
        )
        self.localDataExport = LocalCSVExporter(modelContainer: modelContainer)
        self.csvImport = LocalCSVImporter(
            modelContainer: modelContainer,
            enrichment: uiTesting ? nil : enrichment
        )
        let repairer = SwiftDataAccountDuplicateRepairer(
            modelContainer: modelContainer,
            widgetTimelineReloader: widgetTimelineReloader
        )
        self.accountDuplicateRepair = RepairDuplicateAccountUseCase(repairing: repairer)
    }
}
