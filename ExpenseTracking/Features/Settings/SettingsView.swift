import SwiftUI
import CashFlowKit

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var accountsViewModel: AccountsViewModel
    var onSelectAccount: (AccountID) -> Void = { _ in }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AccountsView(
                        viewModel: accountsViewModel,
                        onSelectAccount: onSelectAccount
                    )
                } label: {
                    Label("Accounts", systemImage: "building.columns")
                }

                NavigationLink {
                    CategorizationRulesView(
                        viewModel: CategorizationRulesViewModel(
                            ruleRepository: viewModel.ruleRepository,
                            ruleApplying: viewModel.ruleApplying,
                            accountRepository: viewModel.accountRepository,
                            tagRepository: viewModel.tagRepository,
                            ruleDrafting: viewModel.ruleDrafting,
                            availabilityChecker: viewModel.availabilityChecker
                        )
                    )
                } label: {
                    Label("Rules", systemImage: "list.bullet.rectangle")
                }
            }

            Section("Bank History") {
                Picker("Import history", selection: Binding(
                    get: { viewModel.selectedLookback },
                    set: { newValue in
                        Task { await viewModel.applyLookback(newValue) }
                    }
                )) {
                    ForEach(HistoryLookbackYears.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                if viewModel.isHistoryComplete {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(viewModel.historyCoverageText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 8)
                        Text("Up to date")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(viewModel.historyCoverageText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let status = viewModel.historyStatus {
                            ProgressView(value: status.historyFraction)
                            Text(status.continuationCopy)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Section("Transaction Titles") {
                HStack(alignment: .center, spacing: 12) {
                    if viewModel.isCleaningUpTitles {
                        ProgressView()
                            .accessibilityLabel("Title cleanup in progress")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(viewModel.titleCleanupText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if viewModel.showTitleCleanupProgress {
                            ProgressView(value: viewModel.titleCleanupFraction)
                                .animation(.default, value: viewModel.titleCleanupFraction)
                        }
                        if let footnote = viewModel.titleCleanupFootnote {
                            Text(footnote)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.titleCleanup.status")

                if viewModel.canStopTitleCleanup {
                    Button("Stop", role: .destructive) {
                        Task { await viewModel.stopTitleCleanup() }
                    }
                    .accessibilityIdentifier("settings.stopCleanup")
                } else if viewModel.canCleanUpTitles {
                    Button(viewModel.titleCleanupActionTitle) {
                        Task { await viewModel.startTitleCleanup() }
                    }
                    .accessibilityIdentifier("settings.cleanupTitles")
                }

                if let message = viewModel.cleanupErrorMessage, !viewModel.isCleaningUpTitles {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Section("Security") {
                Toggle(viewModel.appLock.requireLockToggleTitle, isOn: viewModel.requireLockBinding)
                    .disabled(!viewModel.appLock.canAuthenticate && !viewModel.appLock.isEnabled)

                if !viewModel.appLock.canAuthenticate && !viewModel.appLock.isEnabled {
                    Text("Set a device passcode to enable app lock.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("When enabled, Cash Flow locks after 15 seconds in the background. Unlock with \(viewModel.appLock.biometryDisplayName) or your device passcode.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let message = viewModel.appLock.settingsErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("About") {
                LabeledContent("Version", value: viewModel.appVersion)
                LabeledContent("Build", value: viewModel.appBuild)
            }
            Section("Data") {
                Button {
                    Task { await viewModel.prepareExportSheet() }
                } label: {
                    Label("Export CSV…", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings.exportCSV")

                Button {
                    viewModel.beginImportFlow()
                } label: {
                    Label("Import CSV…", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("settings.importCSV")

                NavigationLink {
                    ImportHistoryView(viewModel: viewModel)
                } label: {
                    Label("Import History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("settings.importHistory")

                Text("Export and import transactions as CSV. Bank credentials are never included. Imported rows use the same categorization pipeline as bank sync.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $viewModel.showExportSheet) {
            ExportCSVSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showImportSheet) {
            ImportCSVSheet(viewModel: viewModel)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.exportFileURL != nil },
            set: { if !$0 { viewModel.clearExportShare() } }
        )) {
            if let url = viewModel.exportFileURL {
                ActivityShareSheet(activityItems: [url]) {
                    viewModel.clearExportShare()
                }
            }
        }
        .task {
            viewModel.startObservingEnrichmentProgress()
            await viewModel.reloadHistoryStatus()
        }
        .onDisappear {
            // Keep observing while cleanup may still run from the prompt; RootTabView owns lifetime.
        }
    }
}
