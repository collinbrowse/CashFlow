import WidgetKit
import SwiftUI
import AppIntents
import CashFlowKit
import CashFlowData

// MARK: - Configuration

enum WidgetTimeFrameAppEnum: String, AppEnum {
    case thisMonth
    case previousMonth
    case last30Days
    case previous3Months
    case last90Days
    case previous6Months
    case last180Days

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Time Frame")

    static let caseDisplayRepresentations: [WidgetTimeFrameAppEnum: DisplayRepresentation] = [
        .thisMonth: "This Month",
        .previousMonth: "Previous Month",
        .last30Days: "Last 30 Days",
        .previous3Months: "Previous 3 Months",
        .last90Days: "Last 90 Days",
        .previous6Months: "Previous 6 Months",
        .last180Days: "Last 180 Days",
    ]

    var domain: WidgetCashFlowTimeFrame {
        WidgetCashFlowTimeFrame(rawValue: rawValue) ?? .thisMonth
    }
}

struct CashFlowWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Cash Flow"
    static let description = IntentDescription("Choose which time frame the widget shows.")

    @Parameter(title: "Time Frame", default: .thisMonth)
    var timeFrame: WidgetTimeFrameAppEnum

    init() {
        self.timeFrame = .thisMonth
    }

    init(timeFrame: WidgetTimeFrameAppEnum) {
        self.timeFrame = timeFrame
    }
}

// MARK: - Timeline

struct CashFlowWidgetEntry: TimelineEntry {
    let date: Date
    let totals: WidgetNetCashFlowTotals?
}

struct CashFlowTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CashFlowWidgetEntry {
        CashFlowWidgetEntry(
            date: .now,
            totals: WidgetNetCashFlowTotals(
                net: 420,
                incomeTotal: 3200,
                expenseTotal: 2780,
                rangeLabel: "This Month"
            )
        )
    }

    func snapshot(
        for configuration: CashFlowWidgetConfigurationIntent,
        in context: Context
    ) async -> CashFlowWidgetEntry {
        await loadEntry(for: configuration)
    }

    func timeline(
        for configuration: CashFlowWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<CashFlowWidgetEntry> {
        let entry = await loadEntry(for: configuration)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func loadEntry(
        for configuration: CashFlowWidgetConfigurationIntent
    ) async -> CashFlowWidgetEntry {
        let totals = await WidgetNetCashFlowLoader().load(
            timeFrame: configuration.timeFrame.domain
        )
        return CashFlowWidgetEntry(date: .now, totals: totals)
    }
}

// MARK: - View

struct CashFlowWidgetView: View {
    var entry: CashFlowWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.totals?.rangeLabel ?? "Cash Flow")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Text(netText)
                .font(.title.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Group {
                if let totals = entry.totals {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CashFlowCurrencyFormatting.signedIncomeUSD(totals.incomeTotal))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.green)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .allowsTightening(true)

                        Text(CashFlowCurrencyFormatting.signedExpenseUSD(totals.expenseTotal))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.red)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .allowsTightening(true)
                    }
                } else {
                    Text("Open the app to sync")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var netText: String {
        guard let net = entry.totals?.net else { return "—" }
        return CashFlowCurrencyFormatting.signedUSD(net)
    }
}

// MARK: - Widget

struct CashFlowWidget: Widget {
    let kind = WidgetCashFlowTimeFrame.widgetKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: CashFlowWidgetConfigurationIntent.self,
            provider: CashFlowTimelineProvider()
        ) { entry in
            CashFlowWidgetView(entry: entry)
        }
        .configurationDisplayName("Net Cash Flow")
        .description("See net cash flow for a time frame you choose.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct OpenCashFlowIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Cash Flow"
    static let description: IntentDescription = IntentDescription("Opens the Cash Flow app.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

@main
struct CashFlowWidgetBundle: WidgetBundle {
    var body: some Widget {
        CashFlowWidget()
        TitleCleanupLiveActivity()
    }
}
