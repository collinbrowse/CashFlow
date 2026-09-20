import SwiftUI
import CashFlowKit

struct AccountRowView: View {
    let account: Account
    let syncDisplay: AccountSyncDisplay

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .font(.body)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.name)
                    .foregroundStyle(.primary)
                Text(account.institutionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusDetail
            }

            Spacer(minLength: 8)

            Text(CurrencyFormatting.usd(account.balance))
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch syncDisplay {
        case .healthy:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.positive)
        case .issue:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
        case .quiet:
            Image(systemName: "archivebox.fill")
                .foregroundStyle(Theme.muted)
        case .none:
            Image(systemName: "circle")
                .foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch syncDisplay {
        case .healthy:
            Text("Sync OK")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.positive)
        case .issue(let message):
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        case .quiet(let message):
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .none:
            EmptyView()
        }
    }
}
