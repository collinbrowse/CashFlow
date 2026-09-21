import Foundation
import Security
import CashFlowKit

/// Credential envelope for SimpleFIN Access URL + non-secret link lineage.
public struct SimpleFINCredentialEnvelope: Codable, Sendable, Equatable {
    public let accessURL: String
    public let linkNamespace: String

    public init(accessURL: String, linkNamespace: String) {
        self.accessURL = accessURL
        self.linkNamespace = linkNamespace
    }

    /// Parses JSON envelopes or a legacy plain-string Access URL.
    public static func parse(
        fromStored data: Data,
        mintedLinkNamespace: String = UUID().uuidString
    ) -> (envelope: SimpleFINCredentialEnvelope, upgradedFromLegacy: Bool)? {
        if let envelope = try? JSONDecoder().decode(SimpleFINCredentialEnvelope.self, from: data),
           !envelope.accessURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !envelope.linkNamespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return (envelope, false)
        }
        guard let legacyURL = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacyURL.isEmpty
        else {
            return nil
        }
        return (
            SimpleFINCredentialEnvelope(accessURL: legacyURL, linkNamespace: mintedLinkNamespace),
            true
        )
    }
}

public protocol AccessURLStoring: Sendable {
    func save(_ envelope: SimpleFINCredentialEnvelope) throws
    func loadEnvelope() throws -> SimpleFINCredentialEnvelope?
    func delete() throws
}

public extension AccessURLStoring {
    /// Convenience for call sites that only need the Access URL string.
    func load() throws -> String? {
        try loadEnvelope()?.accessURL
    }

    func save(accessURL: String, linkNamespace: String = UUID().uuidString) throws {
        try save(SimpleFINCredentialEnvelope(accessURL: accessURL, linkNamespace: linkNamespace))
    }
}

public struct KeychainAccessURLStore: AccessURLStoring, Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.expensetracking.simplefin",
        account: String = "accessURL"
    ) {
        self.service = service
        self.account = account
    }

    public func save(_ envelope: SimpleFINCredentialEnvelope) throws {
        try delete()
        let data = try JSONEncoder().encode(envelope)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CashFlowError.persistence(message: "Keychain save failed (\(status))")
        }
    }

    public func loadEnvelope() throws -> SimpleFINCredentialEnvelope? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CashFlowError.persistence(message: "Keychain load failed (\(status))")
        }

        guard let parsed = SimpleFINCredentialEnvelope.parse(fromStored: data) else {
            return nil
        }
        if parsed.upgradedFromLegacy {
            try save(parsed.envelope)
        }
        return parsed.envelope
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CashFlowError.persistence(message: "Keychain delete failed (\(status))")
        }
    }
}
