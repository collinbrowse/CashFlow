import Foundation
import SwiftData
import Testing
import CashFlowKit
@testable import CashFlowData

@Suite("Connection lifecycle")
struct ConnectionLifecycleTests {
    @Test("Demo link persists across fresh status reader via ConnectionEntity")
    func demoSurvivesRelaunch() async throws {
        let harness = try await makeHarness()
        _ = try await harness.lifecycle.replaceAndLink(withSetupToken: "demo", deleteLocalData: true)

        // Simulate process relaunch: new composite/demo session, same store.
        let relaunched = try await makeHarness(
            container: harness.container,
            accessURLStore: harness.accessURLStore
        )
        let status = await relaunched.sync.connectionStatus()
        #expect(status.isLinked)
        #expect(status.providerName == "Demo")
        #expect(status.lastSuccessfulSyncAt != nil)

        let accounts = try ModelContext(harness.container).fetch(FetchDescriptor<AccountEntity>())
        #expect(accounts.contains(where: { $0.institutionName == "Demo Bank" }))
    }

    @Test("replaceAndLink wipes prior Demo accounts before SimpleFIN sync")
    func replaceAndLinkWipesDemo() async throws {
        let harness = try await makeHarness()
        _ = try await harness.lifecycle.replaceAndLink(withSetupToken: "demo", deleteLocalData: true)
        let afterDemo = try ModelContext(harness.container).fetch(FetchDescriptor<AccountEntity>())
        #expect(afterDemo.contains(where: { $0.institutionName == "Demo Bank" }))

        _ = try await harness.lifecycle.replaceAndLink(withSetupToken: makeSetupToken(), deleteLocalData: true)
        let afterSimpleFIN = try ModelContext(harness.container).fetch(FetchDescriptor<AccountEntity>())
        #expect(afterSimpleFIN.allSatisfy { $0.institutionName != "Demo Bank" })
        #expect(afterSimpleFIN.contains(where: { $0.providerAccountID == "sf-checking" }))

        let status = await harness.sync.connectionStatus()
        #expect(status.providerName == "SimpleFIN")
        #expect(status.isLinked)
    }

    @Test("replaceAndLink with deleteLocalData false keeps CSV accounts")
    func replaceAndLinkKeepsLocal() async throws {
        let harness = try await makeHarness()
        _ = try await harness.lifecycle.replaceAndLink(withSetupToken: "demo", deleteLocalData: true)

        let context = ModelContext(harness.container)
        context.insert(
            AccountEntity(
                id: UUID().uuidString,
                externalID: "csv:keep-me",
                name: "Cash",
                institutionName: "CSV Import",
                currencyCode: "USD",
                balance: 0,
                balanceDate: .now,
                createdByImportBatchID: "batch-1"
            )
        )
        try context.save()

        _ = try await harness.lifecycle.replaceAndLink(
            withSetupToken: makeSetupToken(),
            deleteLocalData: false
        )
        let after = try ModelContext(harness.container).fetch(FetchDescriptor<AccountEntity>())
        #expect(after.contains(where: { $0.externalID == "csv:keep-me" }))
        #expect(after.contains(where: { $0.providerAccountID == "sf-checking" }))
    }

    @Test("Disconnect keep leaves accounts; eraseEverything clears orphan state")
    func disconnectKeepThenErase() async throws {
        let harness = try await makeHarness()
        _ = try await harness.lifecycle.replaceAndLink(withSetupToken: "demo", deleteLocalData: true)
        _ = try await harness.lifecycle.disconnect(deleteLocalData: false)

        let status = await harness.sync.connectionStatus()
        #expect(!status.isLinked)

        let remaining = try ModelContext(harness.container).fetch(FetchDescriptor<AccountEntity>())
        #expect(!remaining.isEmpty)

        try await harness.lifecycle.eraseEverything()
        let cleared = try ModelContext(harness.container).fetch(FetchDescriptor<AccountEntity>())
        #expect(cleared.isEmpty)
        #expect(try harness.accessURLStore.load() == nil)
    }

    @Test("Unauthorized sync persists needsReauth on ConnectionEntity")
    func unauthorizedNeedsReauthSurvives() async throws {
        let accessStore = InMemoryAccessURLStore()
        try accessStore.saveTestAccessURL("https://user:pass@example.com/simplefin")

        let http = SimpleFINStubHTTPClient(mode: .succeedThenUnauthorized)
        let simpleFIN = SimpleFINBankLinkingService(
            client: SimpleFINClient(http: http),
            accessURLStore: accessStore
        )
        let demo = DemoBankLinkingService()
        let linking = CompositeBankLinkingService(
            demo: demo,
            simpleFIN: simpleFIN,
            initialMode: .simpleFIN
        )
        let container = try ModelContainerFactory.make(inMemory: true)
        let sync = SyncCoordinator(modelContainer: container, bankLinking: linking)

        _ = try await sync.syncNow()
        await http.armUnauthorized()
        var didFail = false
        do {
            _ = try await sync.syncNow()
        } catch CashFlowError.unauthorized {
            didFail = true
        }
        #expect(didFail)

        let relaunchedLinking = CompositeBankLinkingService(
            demo: DemoBankLinkingService(),
            simpleFIN: SimpleFINBankLinkingService(
                client: SimpleFINClient(http: SimpleFINStubHTTPClient(mode: .accountsOnly)),
                accessURLStore: accessStore
            )
        )
        let relaunchedSync = SyncCoordinator(
            modelContainer: container,
            bankLinking: relaunchedLinking
        )
        let status = await relaunchedSync.connectionStatus()
        #expect(status.isLinked)
        #expect(status.needsReauth)
        #expect(status.providerName == "SimpleFIN")
    }

    @Test("resetLocalDataKeepingLink clears rows but keeps SimpleFIN credentials")
    func resetKeepsLink() async throws {
        let harness = try await makeHarness()
        _ = try await harness.lifecycle.replaceAndLink(withSetupToken: makeSetupToken(), deleteLocalData: true)
        _ = try await harness.lifecycle.resetLocalDataKeepingLink()

        let status = await harness.sync.connectionStatus()
        #expect(status.isLinked)
        #expect(status.providerName == "SimpleFIN")
        #expect(status.lastSuccessfulSyncAt == nil)

        let accounts = try ModelContext(harness.container).fetch(FetchDescriptor<AccountEntity>())
        #expect(accounts.isEmpty)
        #expect(try harness.accessURLStore.load() != nil)
    }

    @Test("Reconnect preserving namespace reuses the Keychain namespace")
    func reconnectPreservesNamespace() async throws {
        let harness = try await makeHarness()
        _ = try await harness.lifecycle.replaceAndLink(
            withSetupToken: makeSetupToken(),
            deleteLocalData: true
        )
        let original = try #require(try harness.accessURLStore.loadEnvelope()?.linkNamespace)
        _ = try await harness.lifecycle.replaceAndLink(
            withSetupToken: makeSetupToken(),
            deleteLocalData: false,
            preservingLinkNamespace: true
        )
        let reused = try #require(try harness.accessURLStore.loadEnvelope()?.linkNamespace)
        #expect(reused == original)
    }

    @Test("Keep-local without preserving mints a new namespace")
    func keepLocalMintsNewNamespace() async throws {
        let harness = try await makeHarness()
        _ = try await harness.lifecycle.replaceAndLink(
            withSetupToken: makeSetupToken(),
            deleteLocalData: true
        )
        let original = try #require(try harness.accessURLStore.loadEnvelope()?.linkNamespace)
        _ = try await harness.lifecycle.replaceAndLink(
            withSetupToken: makeSetupToken(),
            deleteLocalData: false,
            preservingLinkNamespace: false
        )
        let minted = try #require(try harness.accessURLStore.loadEnvelope()?.linkNamespace)
        #expect(minted != original)
    }

    @Test("Successful sync persists lastSyncIssuesData")
    func persistsLastSyncIssues() async throws {
        let accessStore = InMemoryAccessURLStore()
        try accessStore.saveTestAccessURL("https://user:pass@example.com/simplefin")
        let http = IssuesAccountsHTTPClient()
        let linking = CompositeBankLinkingService(
            demo: DemoBankLinkingService(),
            simpleFIN: SimpleFINBankLinkingService(
                client: SimpleFINClient(http: http),
                accessURLStore: accessStore
            ),
            initialMode: .simpleFIN
        )
        let container = try ModelContainerFactory.make(inMemory: true)
        let sync = SyncCoordinator(modelContainer: container, bankLinking: linking)
        _ = try await sync.syncNow()
        let connection = try #require(
            try ModelContext(container).fetch(FetchDescriptor<ConnectionEntity>()).first
        )
        let data = try #require(connection.lastSyncIssuesData)
        let issues = try JSONDecoder().decode([RemoteProviderIssue].self, from: data)
        #expect(issues.contains(where: { $0.message == "Bank needs attention" }))
    }
}

// MARK: - Harness

private struct LifecycleHarness {
    let container: ModelContainer
    let accessURLStore: InMemoryAccessURLStore
    let sync: SyncCoordinator
    let lifecycle: ConnectionLifecycleService
}

private func makeHarness(
    container: ModelContainer? = nil,
    accessURLStore: InMemoryAccessURLStore? = nil
) async throws -> LifecycleHarness {
    let store = accessURLStore ?? InMemoryAccessURLStore()
    let model = try container ?? ModelContainerFactory.make(inMemory: true)
    let http = SimpleFINStubHTTPClient(mode: .claimAndAccounts)
    let simpleFIN = SimpleFINBankLinkingService(
        client: SimpleFINClient(http: http),
        accessURLStore: store
    )
    let demo = DemoBankLinkingService()
    let linking = CompositeBankLinkingService(demo: demo, simpleFIN: simpleFIN)
    let sync = SyncCoordinator(modelContainer: model, bankLinking: linking)
    let resetter = LocalDataResetter(modelContainer: model)
    let lifecycle = ConnectionLifecycleService(
        bankLinking: linking,
        sync: sync,
        resetter: resetter
    )
    return LifecycleHarness(
        container: model,
        accessURLStore: store,
        sync: sync,
        lifecycle: lifecycle
    )
}

private func makeSetupToken() -> String {
    Data("https://example.com/simplefin/claim/test-token".utf8).base64EncodedString()
}

private func accountsJSON(id: String, name: String) -> Data {
    Data("""
    {"errors":[],"errlist":[],"accounts":[{"id":"\(id)","name":"\(name)","currency":"USD","balance":"10.00","balance-date":1700000000,"org":{"name":"Real Bank"},"transactions":[]}]}
    """.utf8)
}

private actor SimpleFINStubHTTPClient: HTTPClient {
    enum Mode: Sendable {
        case claimAndAccounts
        case accountsOnly
        case succeedThenUnauthorized
    }

    private let mode: Mode
    private var unauthorizedArmed = false

    init(mode: Mode) {
        self.mode = mode
    }

    func armUnauthorized() {
        unauthorizedArmed = true
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(string: "https://example.com")!
        let path = url.path

        if unauthorizedArmed, path.contains("accounts") {
            return (
                Data(),
                HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
            )
        }

        if request.httpMethod == "POST" || path.contains("claim") {
            let data = Data("https://user:pass@example.com/simplefin".utf8)
            return (
                data,
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        if path.contains("info") {
            let data = Data("""
            {"versions":["1","2"]}
            """.utf8)
            return (
                data,
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        // Any accounts window
        return (
            accountsJSON(id: "sf-checking", name: "Checking"),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

private actor IssuesAccountsHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(string: "https://example.com")!
        let path = url.path
        if path.contains("info") {
            return (
                Data(#"{"versions":["1","2"]}"#.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let json = """
        {"errors":[],"errlist":[{"code":"con.auth","msg":"Bank needs attention","conn_id":"c1"}],"connections":[{"conn_id":"c1","name":"Bank","org_name":"Real Bank"}],"accounts":[{"id":"sf-checking","name":"Checking","currency":"USD","balance":"10.00","balance-date":1700000000,"conn_id":"c1","org":{"name":"Real Bank"},"transactions":[]}]}
        """
        return (
            Data(json.utf8),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
