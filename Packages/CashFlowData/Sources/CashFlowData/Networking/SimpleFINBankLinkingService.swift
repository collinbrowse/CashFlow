import Foundation
import CashFlowKit

public actor SimpleFINBankLinkingService: BankLinkingServing {
    public let providerName = "SimpleFIN"

    private let client: SimpleFINClient
    private let accessURLStore: any AccessURLStoring
    private var needsReauth = false

    public init(
        client: SimpleFINClient = SimpleFINClient(),
        accessURLStore: any AccessURLStoring = KeychainAccessURLStore()
    ) {
        self.client = client
        self.accessURLStore = accessURLStore
    }

    public func connectionStatus() async -> LinkedConnection {
        let envelope = try? accessURLStore.loadEnvelope()
        return LinkedConnection(
            isLinked: envelope != nil,
            providerName: providerName,
            needsReauth: needsReauth,
            lastSuccessfulSyncAt: nil,
            linkNamespace: envelope?.linkNamespace
        )
    }

    @discardableResult
    public func link(
        withSetupToken token: String,
        preservingLinkNamespace: String?
    ) async throws -> BankLinkReceipt {
        let accessURL = try await client.claimAccessURL(setupToken: token)
        let reused = preservingLinkNamespace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let linkNamespace = reused.isEmpty ? UUID().uuidString : reused
        let envelope = SimpleFINCredentialEnvelope(
            accessURL: accessURL,
            linkNamespace: linkNamespace
        )
        try accessURLStore.save(envelope)
        needsReauth = false
        _ = try? await client.fetchInfo(accessURL: accessURL)
        return BankLinkReceipt(
            link: ProviderLinkIdentity(source: .simpleFIN, linkNamespace: linkNamespace),
            providerName: providerName
        )
    }

    public func unlink(removeLocalData: Bool) async throws {
        _ = removeLocalData
        try accessURLStore.delete()
        needsReauth = false
    }

    public func fetchAccounts(
        startDate: Date?,
        endDate: Date?
    ) async throws -> RemoteSyncPayload {
        try await fetchAccounts(startDate: startDate, endDate: endDate, onWindowProgress: nil)
    }

    public func fetchAccounts(
        startDate: Date?,
        endDate: Date?,
        onWindowProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async throws -> RemoteSyncPayload {
        try await fetchAccountsWindowed(
            startDate: startDate,
            endDate: endDate,
            maxWindows: nil,
            stopAfterConsecutiveEmpty: nil,
            onWindowProgress: onWindowProgress
        ).payload
    }

    public func fetchAccountsWindowed(
        startDate: Date?,
        endDate: Date?,
        maxWindows: Int?,
        stopAfterConsecutiveEmpty: Int?,
        onWindowProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async throws -> SimpleFINClient.WindowedFetchResult {
        guard let envelope = try accessURLStore.loadEnvelope() else {
            throw CashFlowError.notLinked
        }
        let link = ProviderLinkIdentity(
            source: .simpleFIN,
            linkNamespace: envelope.linkNamespace
        )
        do {
            let result = try await client.fetchAccountsWindowed(
                accessURL: envelope.accessURL,
                link: link,
                startDate: startDate,
                endDate: endDate,
                maxWindows: maxWindows,
                stopAfterConsecutiveEmpty: stopAfterConsecutiveEmpty,
                onWindowProgress: onWindowProgress
            )
            needsReauth = false
            return result
        } catch CashFlowError.unauthorized {
            needsReauth = true
            throw CashFlowError.unauthorized
        }
    }
}
