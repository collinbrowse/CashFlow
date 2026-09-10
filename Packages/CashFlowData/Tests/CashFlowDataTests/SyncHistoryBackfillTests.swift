import Foundation
import SwiftData
import Testing
import CashFlowKit
@testable import CashFlowData

@Suite("Sync history backfill")
struct SyncHistoryBackfillTests {
    @Test("Incomplete history walks backward instead of using incremental watermark")
    func incompleteBackfillIgnoresWatermark() async throws {
        let accessStore = InMemoryAccessURLStore()
        try accessStore.saveTestAccessURL("https://user:pass@example.com/simplefin")

        let http = RecordingAccountsHTTPClient()
        let linking = CompositeBankLinkingService(
            demo: DemoBankLinkingService(),
            simpleFIN: SimpleFINBankLinkingService(
                client: SimpleFINClient(http: http),
                accessURLStore: accessStore
            ),
            initialMode: .simpleFIN
        )
        let container = try ModelContainerFactory.make(inMemory: true)

        let seed = ModelContext(container)
        seed.insert(
            ConnectionEntity(
                providerName: "SimpleFIN",
                needsReauth: false,
                lastSuccessfulSyncAt: .now,
                isDemo: false,
                historyComplete: false,
                historyBackfillComplete: false
            )
        )
        try seed.save()

        let sync = SyncCoordinator(modelContainer: container, bankLinking: linking)
        _ = try await sync.syncNow()

        let windows = await http.windowCount()
        #expect(windows <= SyncCoordinator.maxBackfillWindowsPerSync)
        #expect(windows >= SyncCoordinator.consecutiveEmptyWindowsToStop)

        let afterBackfill = try ModelContext(container).fetch(FetchDescriptor<ConnectionEntity>())
        #expect(afterBackfill.first?.historyComplete == true || afterBackfill.first?.historyBackfillComplete == true)

        await http.reset()
        _ = try await sync.syncNow()

        let incrementalStart = await http.earliestRequestedStart()
        let expected = Calendar.current.date(
            byAdding: .day,
            value: -SyncCoordinator.incrementalLookbackDays,
            to: .now
        )!
        #expect(incrementalStart != nil)
        #expect(abs(incrementalStart!.timeIntervalSince(expected)) < 172_800)
    }

    @Test("resetLocalDataKeepingLink clears historyBackfillComplete")
    func resetClearsBackfillFlag() async throws {
        let accessStore = InMemoryAccessURLStore()
        try accessStore.saveTestAccessURL("https://user:pass@example.com/simplefin")
        let http = RecordingAccountsHTTPClient()
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
        let lifecycle = ConnectionLifecycleService(
            bankLinking: linking,
            sync: sync,
            resetter: LocalDataResetter(modelContainer: container)
        )

        _ = try await sync.syncNow()
        let afterSync = try ModelContext(container).fetch(FetchDescriptor<ConnectionEntity>()).first
        #expect(afterSync?.historyComplete == true || afterSync?.historyBackfillComplete == true)

        _ = try await lifecycle.resetLocalDataKeepingLink()
        let after = try ModelContext(container).fetch(FetchDescriptor<ConnectionEntity>()).first
        #expect(after?.historyBackfillComplete == false)
        #expect(after?.historyComplete == false)
        #expect(after?.earliestFetchedDate == nil)
    }

    @Test("Incomplete inventory does not advance earliestFetchedDate or complete history")
    func incompleteDoesNotAdvanceWatermark() async throws {
        let accessStore = InMemoryAccessURLStore()
        try accessStore.saveTestAccessURL("https://user:pass@example.com/simplefin")
        let http = IncompleteInventoryHTTPClient()
        let linking = CompositeBankLinkingService(
            demo: DemoBankLinkingService(),
            simpleFIN: SimpleFINBankLinkingService(
                client: SimpleFINClient(http: http),
                accessURLStore: accessStore
            ),
            initialMode: .simpleFIN
        )
        let container = try ModelContainerFactory.make(inMemory: true)
        let watermark = Date(timeIntervalSince1970: 1_700_000_000)
        let seed = ModelContext(container)
        seed.insert(
            ConnectionEntity(
                providerName: "SimpleFIN",
                needsReauth: false,
                lastSuccessfulSyncAt: .now,
                isDemo: false,
                earliestFetchedDate: watermark,
                historyComplete: false,
                historyBackfillComplete: false
            )
        )
        try seed.save()

        let sync = SyncCoordinator(modelContainer: container, bankLinking: linking)
        _ = try await sync.syncNow()

        let after = try #require(try ModelContext(container).fetch(FetchDescriptor<ConnectionEntity>()).first)
        #expect(after.earliestFetchedDate == watermark)
        #expect(after.historyComplete == false)
        #expect(after.historyBackfillComplete == false)
    }
}

// MARK: - Stubs

private actor RecordingAccountsHTTPClient: HTTPClient {
    private var startDates: [Date] = []

    func earliestRequestedStart() -> Date? {
        startDates.min()
    }

    func windowCount() -> Int {
        startDates.count
    }

    func reset() {
        startDates.removeAll()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(string: "https://example.com")!
        let path = url.path

        if path.contains("info") {
            let data = Data("""
            {"versions":["1","2"]}
            """.utf8)
            return (
                data,
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        if path.contains("accounts") {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let raw = items.first(where: { $0.name == "start-date" })?.value,
               let epoch = TimeInterval(raw)
            {
                startDates.append(Date(timeIntervalSince1970: epoch))
            }
            let end = items.first(where: { $0.name == "end-date" })?.value ?? "0"
            let json = """
            {"errors":[],"errlist":[],"accounts":[{"id":"sf-checking","name":"Checking","currency":"USD","balance":"10.00","balance-date":\(end),"org":{"name":"Real Bank"},"transactions":[]}]}
            """
            return (
                Data(json.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        return (
            Data(),
            HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
        )
    }
}

private actor IncompleteInventoryHTTPClient: HTTPClient {
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
        {"errlist":[{"code":"gen.","msg":"No connections available."}],"accounts":[],"connections":[]}
        """
        return (
            Data(json.utf8),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
