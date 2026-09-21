import ActivityKit
import SwiftUI
import WidgetKit
import CashFlowKit

struct TitleCleanupLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TitleCleanupActivityAttributes.self) { context in
            TitleCleanupBannerView(content: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TitleCleanupGlyph(content: context.state, pointSize: 22)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TitleCleanupProgressRing(content: context.state, tint: .white)
                        .controlSize(.small)
                }
                DynamicIslandExpandedRegion(.center) {
                    // Never use `.bottom` — that region is clipped on the expanded island
                    // regardless of string length. Keep all copy in this row.
                    TitleCleanupLiveActivityText(content: context.state, style: .expandedIsland)
                }
            } compactLeading: {
                TitleCleanupGlyph(content: context.state, pointSize: 14)
            } compactTrailing: {
                TitleCleanupProgressRing(content: context.state, tint: .white)
                    .controlSize(.mini)
            } minimal: {
                TitleCleanupProgressRing(content: context.state, tint: .white)
                    .controlSize(.mini)
            }
        }
    }
}

/// Copy that degrades by dropping lines / combining them, never by clipping.
private struct TitleCleanupLiveActivityText: View {
    enum Style {
        /// Two lines max so the leading/trailing island row can grow instead of clipping.
        case expandedIsland
        /// Lock Screen / StandBy / banner — extra height, still ViewThatFits.
        case banner
    }

    let content: TitleCleanupLiveActivityContent
    var style: Style

    var body: some View {
        Group {
            switch style {
            case .expandedIsland:
                expandedIsland
            case .banner:
                banner
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(content.headline)
        .accessibilityValue("\(content.countLine), \(content.statusLine)")
    }

    private var expandedIsland: some View {
        VStack(alignment: .leading, spacing: 1) {
            title
            ViewThatFits(in: .horizontal) {
                Text(content.secondaryLine)
                Text(content.countLine)
                Text(content.statusLine)
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .allowsTightening(true)
        }
    }

    private var banner: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 1) {
                title
                count
                status
            }
            VStack(alignment: .leading, spacing: 1) {
                title
                ViewThatFits(in: .horizontal) {
                    Text(content.secondaryLine)
                    Text(content.countLine)
                    Text(content.statusLine)
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
            }
            title
        }
    }

    private var title: some View {
        Text(content.headline)
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .allowsTightening(true)
    }

    private var count: some View {
        Text(content.countLine)
            .font(.subheadline.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .allowsTightening(true)
    }

    private var status: some View {
        Text(content.statusLine)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .allowsTightening(true)
    }
}

private struct TitleCleanupGlyph: View {
    let content: TitleCleanupLiveActivityContent
    var pointSize: CGFloat

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: pointSize, weight: .semibold))
            .accessibilityHidden(true)
    }

    private var symbolName: String {
        if content.isComplete { return "checkmark.circle.fill" }
        if content.isPaused { return "pause.circle.fill" }
        return "apple.intelligence"
    }
}

private struct TitleCleanupProgressRing: View {
    let content: TitleCleanupLiveActivityContent
    var tint: Color

    var body: some View {
        Group {
            if content.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
            } else {
                ProgressView(value: content.fractionCompleted)
                    .progressViewStyle(.circular)
            }
        }
        .tint(tint)
        .accessibilityHidden(true)
    }
}

private struct TitleCleanupBannerView: View {
    let content: TitleCleanupLiveActivityContent

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(.secondary.opacity(0.18))
                TitleCleanupGlyph(content: content, pointSize: 20)
            }
            .frame(width: 40, height: 40)

            TitleCleanupLiveActivityText(content: content, style: .banner)

            TitleCleanupProgressRing(content: content, tint: .primary)
                .controlSize(.small)
                .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
