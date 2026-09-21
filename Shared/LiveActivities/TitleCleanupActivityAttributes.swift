import ActivityKit
import CashFlowKit

/// Shared by the app (request / update / end) and the widget (Live Activity UI).
struct TitleCleanupActivityAttributes: ActivityAttributes {
    typealias ContentState = TitleCleanupLiveActivityContent
}
