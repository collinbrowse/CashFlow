import Testing
import Foundation
@testable import ExpenseTracking
import CashFlowKit

@Suite("AssistantViewModel")
@MainActor
struct AssistantViewModelTests {
    @Test("Send surfaces a pending proposal without applying")
    func sendSurfacesProposal() async {
        let assistant = FakeAssistant()
        await assistant.setNextProposal(
            AssistantProposal(
                summary: "Add tag Thailand for 2 transactions and save as a lasting rule.",
                conditionSummary: "Location contains “Thailand”",
                affectedCount: 2,
                samples: [],
                saveAsRule: true,
                conditions: [.locationContains("Thailand")],
                appliesCategory: false,
                categoryID: SystemCategory.other.id,
                tagNames: ["Thailand"],
                matchingTransactionIDs: [TransactionID("1"), TransactionID("2")]
            )
        )
        let vm = AssistantViewModel(
            availabilityChecker: FixedAvailability(.available),
            assistant: assistant,
            transactionRepository: AssistantMockTransactionRepository()
        )
        await vm.onAppear()
        await vm.send("Tag Thailand spend")

        #expect(vm.pendingProposal?.affectedCount == 2)
        // Proposal card is the preview; no duplicate assistant chat bubble.
        #expect(vm.messages.contains(where: { $0.role == .assistant }) == false)
        #expect(vm.messages.contains(where: { $0.role == .user }))
        #expect(vm.isShowingLiveProgress == false)
    }

    @Test("Send consumes status and draft events before the proposal")
    func sendConsumesStreamEvents() async {
        let assistant = FakeAssistant()
        let proposal = AssistantProposal(
            summary: "Categorize Mobile Deposit as Income",
            conditionSummary: "Title contains “Mobile Deposit”",
            affectedCount: 3,
            samples: [],
            saveAsRule: true,
            conditions: [.titleContains("Mobile Deposit")],
            appliesCategory: true,
            categoryID: SystemCategory.income.id,
            matchingTransactionIDs: [TransactionID("1")]
        )
        await assistant.setNextProposal(proposal)
        await assistant.setEmitDraft(true)
        let vm = AssistantViewModel(
            availabilityChecker: FixedAvailability(.available),
            assistant: assistant,
            transactionRepository: AssistantMockTransactionRepository()
        )
        await vm.onAppear()
        await vm.send("Set Mobile Deposit to Income")

        #expect(vm.pendingProposal?.affectedCount == 3)
        #expect(vm.pendingProposal?.tagNames.isEmpty == true)
        #expect(await assistant.interpretCount == 1)
        #expect(vm.liveProgressLine == nil)
        #expect(vm.messages.contains(where: { $0.role == .assistant }) == false)
    }

    @Test("Execute applies through the assistant port without chat undo")
    func executeAppliesWithoutChatUndo() async {
        let assistant = FakeAssistant()
        let proposal = AssistantProposal(
            summary: "Done",
            conditionSummary: "Title contains “Coffee”",
            affectedCount: 1,
            samples: [],
            saveAsRule: true,
            conditions: [.titleContains("Coffee")],
            appliesCategory: true,
            categoryID: SystemCategory.dining.id,
            matchingTransactionIDs: [TransactionID("1")]
        )
        await assistant.setNextProposal(proposal)
        await assistant.setNextTurn(
            AssistantTurn(
                message: AssistantMessage(
                    role: .assistant,
                    text: """
                    • Updated 1 transaction.
                    • Saved rule.
                    • Undo from Rules → Edit Rule.
                    """
                )
            )
        )
        let vm = AssistantViewModel(
            availabilityChecker: FixedAvailability(.available),
            assistant: assistant,
            transactionRepository: AssistantMockTransactionRepository()
        )
        await vm.onAppear()
        await vm.send("coffee")
        await vm.executePendingProposal()

        #expect(vm.pendingProposal == nil)
        #expect(await assistant.executeCount == 1)
        #expect(vm.bannerMessage == nil)
        #expect(vm.messages.last?.text.contains("• Updated 1") == true)
        #expect(vm.messages.last?.text.contains("• Undo from Rules") == true)
    }

    @Test("Unavailable availability disables chat")
    func unavailableDisablesChat() async {
        let vm = AssistantViewModel(
            availabilityChecker: FixedAvailability(.appleIntelligenceOff),
            assistant: FakeAssistant(),
            transactionRepository: AssistantMockTransactionRepository()
        )
        await vm.onAppear()
        #expect(vm.canChat == false)
        #expect(vm.availabilityMessage.contains("Turn on Apple Intelligence"))
    }

    @Test("Send surfaces bridged CashFlowError description in the banner")
    func sendSurfacesBridgedErrorDescription() async {
        let assistant = FakeAssistant()
        await assistant.setNextError(
            NSError(
                domain: CashFlowError.errorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Timed out talking to SimpleFIN."]
            )
        )
        let vm = AssistantViewModel(
            availabilityChecker: FixedAvailability(.available),
            assistant: FakeAssistant(),
            transactionRepository: AssistantMockTransactionRepository()
        )
        // Use the configured assistant instance
        let vm2 = AssistantViewModel(
            availabilityChecker: FixedAvailability(.available),
            assistant: assistant,
            transactionRepository: AssistantMockTransactionRepository()
        )
        await vm2.onAppear()
        await vm2.send("Tag Thailand")

        #expect(vm2.bannerMessage == "Timed out talking to SimpleFIN.")
        #expect(vm2.bannerMessage?.contains("error 2") != true)
        _ = vm
    }
}

@Suite("CategorizationRuleEditorViewModel drafting")
@MainActor
struct CategorizationRuleEditorDraftingTests {
    @Test("apply draft fills the same editor fields as manual entry")
    func applyDraftFillsEditor() {
        let vm = CategorizationRuleEditorViewModel(
            ruleRepository: FakeRuleRepository(),
            ruleApplying: FakeRuleApplying(),
            accountRepository: FakeAccountRepository(),
            tagRepository: FakeTagRepository()
        )
        let draft = CategorizationRuleDraft(
            action: .categorize,
            categoryID: SystemCategory.dining.id,
            conditions: [
                .titleContains("Starbucks"),
                .amountMin(10),
            ],
            explanation: "Coffee spend"
        )
        vm.apply(draft: draft)

        #expect(vm.appliesCategory)
        #expect(vm.categoryID == SystemCategory.dining.id)
        #expect(vm.conditions.count == 2)
        #expect(vm.conditions[0].kind == .titleContains)
        #expect(vm.conditions[0].textValue == "Starbucks")
        #expect(vm.conditions[1].kind == .amountMin)
        #expect(vm.canSave)
    }
}

private struct FixedAvailability: OnDeviceModelAvailabilityChecking {
    let value: OnDeviceModelAvailability
    init(_ value: OnDeviceModelAvailability) { self.value = value }
    func availability() async -> OnDeviceModelAvailability { value }
}

private actor FakeAssistant: TransactionAssistantServing {
    private var nextProposal: AssistantProposal?
    private var nextTurn = AssistantTurn(
        message: AssistantMessage(role: .assistant, text: "ok")
    )
    private var nextError: Error?
    private var emitDraft = false
    private(set) var executeCount = 0
    private(set) var interpretCount = 0

    func setNextProposal(_ proposal: AssistantProposal) {
        nextProposal = proposal
        nextError = nil
    }

    func setNextTurn(_ turn: AssistantTurn) {
        nextTurn = turn
        nextError = nil
    }

    func setNextError(_ error: Error) {
        nextError = error
    }

    func setEmitDraft(_ value: Bool) {
        emitDraft = value
    }

    func reset() async { nextProposal = nil }

    nonisolated func interpret(
        prompt: String
    ) -> AsyncThrowingStream<AssistantInterpretEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let error = await self.nextError
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                guard let proposal = await self.nextProposal else {
                    continuation.finish(
                        throwing: CashFlowError.intelligence(message: "No proposal")
                    )
                    return
                }
                await self.bumpInterpretCount()
                continuation.yield(.status("Understanding your request…"))
                if await self.emitDraft {
                    continuation.yield(
                        .draft(
                            explanation: proposal.summary,
                            conditionSummary: proposal.conditionSummary
                        )
                    )
                    continuation.yield(.status("Finding matching transactions…"))
                }
                continuation.yield(.proposal(proposal))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func bumpInterpretCount() {
        interpretCount += 1
    }

    func execute(_ proposal: AssistantProposal) async throws -> AssistantTurn {
        if let nextError { throw nextError }
        executeCount += 1
        return nextTurn
    }

    func undoLastChange() async throws {}

    func lastUndoSnapshot() async -> AssistantUndoSnapshot? { nil }

    func discardUndoSnapshot() async {}
}

private final class AssistantMockTransactionRepository: TransactionRepository, @unchecked Sendable {
    var tagAssignments: [TagAssignment] = []
    var categoryAssignments: [CategoryAssignment] = []

    func fetchPage(
        filter: TransactionFilter,
        cursor: TransactionCursor?,
        limit: Int
    ) async throws -> TransactionPage {
        TransactionPage(items: [], nextCursor: nil)
    }

    func fetchPosted(in range: CashFlowDateRange, now: Date) async throws -> [Transaction] { [] }
    func earliestPostedDate() async throws -> Date? { nil }
    func updateCategory(
        transactionID: TransactionID,
        categoryID: CategoryID,
        categoryLocked: Bool
    ) async throws {}
    func updateTags(transactionID: TransactionID, tagIDs: [TagID]) async throws {}
    func applyCategoryAssignments(_ assignments: [CategoryAssignment]) async throws {
        categoryAssignments.append(contentsOf: assignments)
    }
    func applyTagAssignments(_ assignments: [TagAssignment]) async throws {
        tagAssignments.append(contentsOf: assignments)
    }
    func updateEnrichment(
        transactionID: TransactionID,
        title: String,
        location: String?,
        source: TitleSource,
        clearLocation: Bool
    ) async throws {}
    func markEnrichmentSkipped(transactionID: TransactionID) async throws {}
    func fetchAllForCategorization() async throws -> [Transaction] { [] }
    func fetchNeedingCategorySuggestion(limit: Int) async throws -> [Transaction] { [] }
    func countNeedingCategorySuggestion() async throws -> Int { 0 }
    
    func applyTitleLocationAssignments(_ assignments: [TitleLocationAssignment]) async throws {}
    func countNeedingEnrichment() async throws -> Int { 0 }
    func countDistinctDescriptionsNeedingEnrichment() async throws -> Int { 0 }

    func fetchNeedingEnrichment(limit: Int) async throws -> [Transaction] { [] }
}

private struct FakeRuleRepository: CategorizationRuleRepository {
    func fetchAll() async throws -> [CategorizationRule] { [] }
    func upsert(_ rule: CategorizationRule) async throws {}
    func delete(id: CategorizationRuleID) async throws {}
    func reorder(ids: [CategorizationRuleID]) async throws {}
}

private struct FakeRuleApplying: CategorizationRuleApplying {
    func reapplyAllRules() async throws -> Int { 0 }
    func applyAndCaptureUndo(for rule: CategorizationRule) async throws -> CategorizationRule { rule }
    func undoRule(id: CategorizationRuleID) async throws -> Int { 0 }
}

private struct FakeAccountRepository: AccountRepository {
    func fetchAll() async throws -> [Account] { [] }
    func updateName(accountID: AccountID, name: String) async throws {}
    func keepLocally(accountID: AccountID) async throws {}
    func create(
        name: String,
        institutionName: String,
        currencyCode: String,
        createdByImportBatchID: ImportBatchID?
    ) async throws -> Account {
        Account(
            id: AccountID(UUID().uuidString),
            externalID: "csv:stub",
            name: name,
            institutionName: institutionName,
            currencyCode: currencyCode,
            balance: 0,
            balanceDate: .now
        )
    }
}

private struct FakeTagRepository: TagRepository {
    func fetchAll() async throws -> [CashFlowKit.Tag] { [] }
    func create(name: String) async throws -> CashFlowKit.Tag {
        CashFlowKit.Tag(id: TagID(UUID().uuidString), name: name, createdAt: .now)
    }
    func rename(id: TagID, name: String) async throws {}
    func delete(id: TagID) async throws {}
}
