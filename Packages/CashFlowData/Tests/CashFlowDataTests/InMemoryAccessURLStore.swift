import Foundation
@testable import CashFlowData

final class InMemoryAccessURLStore: AccessURLStoring, @unchecked Sendable {
    static let testLinkNamespace = "test-ns"

    private let lock = NSLock()
    private var envelope: SimpleFINCredentialEnvelope?

    func save(_ envelope: SimpleFINCredentialEnvelope) throws {
        lock.lock()
        defer { lock.unlock() }
        self.envelope = envelope
    }

    func loadEnvelope() throws -> SimpleFINCredentialEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return envelope
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        envelope = nil
    }

    func saveTestAccessURL(_ accessURL: String) throws {
        try save(
            SimpleFINCredentialEnvelope(
                accessURL: accessURL,
                linkNamespace: Self.testLinkNamespace
            )
        )
    }
}
