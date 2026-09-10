import Foundation
import Observation
import CashFlowKit
import CashFlowData

enum HomeDisplayState: Equatable {
    case empty
    case loading
    case populated
}

@MainActor
@Observable
final class HomeViewModel {
    private let transactionRepository: any TransactionRepository
    private let syncServing: any SyncServing
    private let calculateNetCashFlow: CalculateNetCashFlowUseCase
    private let connectivity: ConnectivityMonitor
    private let widgetTimelineReloader: any WidgetTimelineReloading

    var selectedOption: HomeRangeOption = .month
    var customStart: Date = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    var customEnd: Date = .now
    var result: NetCashFlowResult = .init(
        net: 0,
        incomeTotal: 0,
        expenseTotal: 0,
        dailyPoints: []
    )
    var isRefreshing = false
    /// Starts true so the first paint is a loader, not a flash of the empty state.
    var isLoading = true
    var bannerMessage: String?
    var syncProgress: SyncProgress?
    var isOffline = false
    var showCustomRange = false
    /// True when the selected range has at least one posted transaction (drives chart animation).
    var hasData = false
    /// True when the store has any posted history (even if this range is empty).
    var hasStoreHistory = false
    /// Bumped when chart-worthy data lands so the chart can replay its entrance animation.
    var chartAnimationToken = 0
    /// Oldest posted transaction; gates whether Year appears in the range picker.
    var earliestPostedDate: Date?
    var availableRangeOptions: [HomeRangeOption] = HomeRangeOption.pickerOptions(earliestPosted: nil)

    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var syncProgressTask: Task<Void, Never>?
    private var didKickEmptyLedgerSync = false

    init(
        transactionRepository: any TransactionRepository,
        syncServing: any SyncServing,
        calculateNetCashFlow: CalculateNetCashFlowUseCase,
        connectivity: ConnectivityMonitor,
        widgetTimelineReloader: any WidgetTimelineReloading = NoOpWidgetTimelineReloader()
    ) {
        self.transactionRepository = transactionRepository
        self.syncServing = syncServing
        self.calculateNetCashFlow = calculateNetCashFlow
        self.connectivity = connectivity
        self.widgetTimelineReloader = widgetTimelineReloader
    }

    var selectedRange: CashFlowDateRange {
        selectedOption.dateRange(customStart: customStart, customEnd: customEnd)
    }

    var displayState: HomeDisplayState {
        if isLoading { return .loading }
        // A quiet month/range must not look like “no account linked”.
        if hasStoreHistory || hasData { return .populated }
        return .empty
    }

    func onAppear() async {
        startObservingSyncProgress()
        isOffline = !connectivity.isOnline
        await reload(preferLoadingIndicator: !hasStoreHistory && !hasData)
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

    /// Updates the segmented control synchronously, then reloads (cancelling any in-flight range load).
    func selectOption(_ option: HomeRangeOption) {
        guard availableRangeOptions.contains(option) else { return }
        if option == .custom {
            showCustomRange = true
            return
        }
        selectedOption = option
        scheduleReload(preferLoadingIndicator: false)
    }

    func applyCustomRange() {
        selectedOption = .custom
        showCustomRange = false
        scheduleReload(preferLoadingIndicator: false)
    }

    private func scheduleReload(preferLoadingIndicator: Bool) {
        reloadTask?.cancel()
        reloadTask = Task { await reload(preferLoadingIndicator: preferLoadingIndicator) }
    }

    private func syncEmptyLinkedLedgerIfNeeded() async {
        guard !didKickEmptyLedgerSync else { return }
        let status = await syncServing.connectionStatus()
        guard status.isLinked, status.lastSuccessfulSyncAt == nil, !hasStoreHistory else { return }
        didKickEmptyLedgerSync = true
        await refresh()
    }

    /// - Parameter preferLoadingIndicator: When true (e.g. empty → first data), show the centered loader.
    func reload(preferLoadingIndicator: Bool = true) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        // Capture range up front so a later selection change cannot alter this load's query.
        let range = selectedRange
        let wasUnlinkedEmpty = !hasStoreHistory && !hasData
        let shouldShowLoader = preferLoadingIndicator && wasUnlinkedEmpty
        if shouldShowLoader {
            isLoading = true
        }
        defer {
            if generation == reloadGeneration {
                isLoading = false
            }
        }

        do {
            earliestPostedDate = try await transactionRepository.earliestPostedDate()
            guard generation == reloadGeneration, !Task.isCancelled else { return }

            hasStoreHistory = earliestPostedDate != nil
            availableRangeOptions = HomeRangeOption.pickerOptions(earliestPosted: earliestPostedDate)
            if !availableRangeOptions.contains(selectedOption) {
                selectedOption = .month
            }

            let now = Date.now
            let transactions = try await transactionRepository.fetchPosted(
                in: range,
                now: now
            )
            guard generation == reloadGeneration, !Task.isCancelled else { return }

            let nextHasData = !transactions.isEmpty
            let nextResult = calculateNetCashFlow.execute(
                transactions: transactions,
                range: range,
                now: now
            )

            hasData = nextHasData
            result = nextResult

            if nextHasData && (wasUnlinkedEmpty || shouldShowLoader) {
                chartAnimationToken += 1
            }
            // Invalidate widget timelines so each instance recomputes its own configured range.
            widgetTimelineReloader.reloadCashFlowWidget()
        } catch is CancellationError {
            return
        } catch {
            guard generation == reloadGeneration else { return }
            bannerMessage = CashFlowError.userFacingMessage(
                for: error,
                fallback: "Couldn't load transactions."
            )
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        isOffline = !connectivity.isOnline
        let wasUnlinkedEmpty = !hasStoreHistory && !hasData
        if wasUnlinkedEmpty {
            isLoading = true
        }
        do {
            let status = try await syncServing.syncNow()
            if !status.providerMessages.isEmpty {
                let detail = status.providerMessages.joined(separator: " ")
                bannerMessage = "\(detail) Open Accounts to retry or reconnect."
            } else {
                bannerMessage = nil
            }
            await reload(preferLoadingIndicator: wasUnlinkedEmpty)
        } catch CashFlowError.cancelled {
            isLoading = false
            return
        } catch {
            if CashFlowError.fromBridgedError(error) == .unauthorized {
                bannerMessage = "Reconnect your account — access was revoked."
            } else {
                let detail = CashFlowError.userFacingMessage(
                    for: error,
                    fallback: "Couldn't refresh."
                )
                let asOf = (await syncServing.connectionStatus()).lastSuccessfulSyncAt
                if let asOf {
                    bannerMessage =
                        "\(detail) Showing data as of \(DateFormatting.medium(asOf))."
                } else {
                    bannerMessage = "\(detail) Showing last saved data."
                }
            }
            await reload(preferLoadingIndicator: wasUnlinkedEmpty)
        }
    }

    var rangeTitle: String {
        switch selectedOption {
        case .month: "This Month"
        case .last30Days: "Last 30 Days"
        case .lastYear: "Last Year"
        case .custom: "Custom"
        }
    }
}
