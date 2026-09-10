import SwiftUI
import CashFlowKit

struct DuplicateAccountRepairSheet: View {
    @Bindable var viewModel: AccountsViewModel

    var body: some View {
        NavigationStack {
            Form {
                if let retained = viewModel.accounts.first(where: { $0.id == viewModel.repairingAccountID }) {
                    Section("Keep local account") {
                        Text(retained.name)
                        Text(retained.institutionName)
                            .foregroundStyle(.secondary)
                        if retained.providerState == .historical {
                            Text("Marked historical after the provider stopped returning it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Adopt provider identity from") {
                    if viewModel.repairCandidates.isEmpty {
                        Text("No current provider accounts available. Sync Now, then try again.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Choose which current account should donate identity. Nothing is selected until you tap one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(viewModel.repairCandidates) { candidate in
                            Button {
                                Task { await viewModel.selectRepairProvider(candidate.id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name)
                                        Text(candidate.institutionName)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if viewModel.selectedRepairProviderID == candidate.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let preview = viewModel.repairPreview {
                    Section("Preview") {
                        LabeledContent("Exact matches", value: "\(preview.exactDuplicateCount)")
                        LabeledContent("Likely matches", value: "\(preview.likelyDuplicateCount)")
                        LabeledContent("Ambiguous kept", value: "\(preview.ambiguousCount)")
                        LabeledContent("Moved", value: "\(preview.movedCount)")
                        Toggle("Merge likely duplicates", isOn: $viewModel.mergeLikelyDuplicates)
                            .onChange(of: viewModel.mergeLikelyDuplicates) { _, _ in
                                Task { await viewModel.refreshRepairPreview() }
                            }
                        Text("Off by default so similar CSV or memo-only matches stay separate.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Repair duplicate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.cancelRepair() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Repair") {
                        Task { await viewModel.confirmRepair() }
                    }
                    .disabled(viewModel.repairPreview == nil || viewModel.isWorking)
                }
            }
        }
    }
}
