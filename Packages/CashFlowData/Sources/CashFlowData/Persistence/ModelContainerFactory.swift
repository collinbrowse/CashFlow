import Foundation
import SwiftData
import os

public enum ModelContainerFactory {
    private static let logger = Logger(subsystem: "com.expensetracking", category: "persistence")
    /// Shared marker: once set, V3 store is authoritative and Keychain credentials are preserved.
    public static let storeEpochKey = "cashflow.storeEpoch.v3"
    public static let storeEpochValue = "3"

    /// Creates the app ModelContainer. Disk failures fall back without silently wiping after V3.
    public static func make(
        inMemory: Bool = false,
        appGroupID: String? = nil
    ) throws -> ModelContainer {
        if inMemory {
            return try makeInMemoryContainer()
        }
        return makeResilient(appGroupID: appGroupID)
    }

    /// Non-throwing entry point for app launch.
    public static func makeResilient(appGroupID: String? = nil) -> ModelContainer {
        let schema = Schema(versionedSchema: CashFlowSchemaV3.self)
        performOneTimeV3LedgerResetIfNeeded(appGroupID: appGroupID)

        if let appGroupID, isAppGroupAvailable(appGroupID) {
            if let container = attemptLoad(schema: schema, configuration: appGroupConfiguration(schema: schema, appGroupID: appGroupID)) {
                markV3StoreReady(appGroupID: appGroupID)
                return container
            }
            logger.error("App Group store failed to load; preserving files and falling back to local Application Support")
        } else if appGroupID != nil {
            logger.error("App Group container unavailable; using local Application Support")
        }

        if let container = attemptLoad(schema: schema, configuration: localConfiguration(schema: schema)) {
            markV3StoreReady(appGroupID: appGroupID)
            return container
        }

        logger.fault("Persistent stores unusable; launching with in-memory SwiftData (ledger preserved on disk)")
        do {
            return try makeInMemoryContainer()
        } catch {
            preconditionFailure("In-memory ModelContainer failed: \(error)")
        }
    }

    private static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CashFlowSchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: schema,
            migrationPlan: CashFlowMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private static func attemptLoad(
        schema: Schema,
        configuration: ModelConfiguration
    ) -> ModelContainer? {
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: CashFlowMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            logger.error("ModelContainer load failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func appGroupConfiguration(schema: Schema, appGroupID: String) -> ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(appGroupID)
        )
    }

    private static func localConfiguration(schema: Schema) -> ModelConfiguration {
        ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    }

    /// Opens only the shared App Group store. Returns `nil` when the group is missing,
    /// the V3 epoch marker is absent, or the store cannot load.
    public static func makeSharedStoreIfAvailable(appGroupID: String) -> ModelContainer? {
        guard isAppGroupAvailable(appGroupID) else { return nil }
        guard isV3StoreReady(appGroupID: appGroupID) else {
            logger.info("Widget waiting for app to complete V3 store reset")
            return nil
        }
        let schema = Schema(versionedSchema: CashFlowSchemaV3.self)
        return attemptLoad(
            schema: schema,
            configuration: appGroupConfiguration(schema: schema, appGroupID: appGroupID)
        )
    }

    public static func isAppGroupAvailable(_ appGroupID: String) -> Bool {
        guard !appGroupID.isEmpty else { return false }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    /// One-time wipe of the local ledger for the V3 identity redesign. Keychain is untouched.
    public static func performOneTimeV3LedgerResetIfNeeded(appGroupID: String?) {
        guard !isV3StoreReady(appGroupID: appGroupID) else { return }
        logger.notice("Performing one-time V3 ledger reset (Keychain credentials preserved)")
        destroyPersistentStores(appGroupID: appGroupID)
    }

    public static func isV3StoreReady(appGroupID: String?) -> Bool {
        defaults(for: appGroupID).string(forKey: storeEpochKey) == storeEpochValue
    }

    public static func markV3StoreReady(appGroupID: String?) {
        defaults(for: appGroupID).set(storeEpochValue, forKey: storeEpochKey)
    }

    /// Test helper: clears the V3 epoch marker so the next launch resets the ledger.
    public static func clearV3StoreEpochMarker(appGroupID: String?) {
        defaults(for: appGroupID).removeObject(forKey: storeEpochKey)
    }

    private static func defaults(for appGroupID: String?) -> UserDefaults {
        if let appGroupID, let defaults = UserDefaults(suiteName: appGroupID) {
            return defaults
        }
        return .standard
    }

    /// Removes SwiftData/SQLite store files from App Group + local Application Support.
    public static func destroyPersistentStores(appGroupID: String?) {
        let fm = FileManager.default
        for directory in storeDirectories(appGroupID: appGroupID) {
            deleteStoreArtifacts(in: directory, fileManager: fm)
        }
    }

    static func storeDirectories(appGroupID: String?) -> [URL] {
        var directories: [URL] = []
        if let appGroupID,
           let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        {
            directories.append(root.appending(path: "Library/Application Support", directoryHint: .isDirectory))
            directories.append(root)
        }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(appSupport)
        }
        var seen = Set<String>()
        return directories.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func deleteStoreArtifacts(in directory: URL, fileManager fm: FileManager) {
        guard fm.fileExists(atPath: directory.path) else { return }

        let knownBases = ["default.store", "default.sqlite", "CashFlow.store"]
        for base in knownBases {
            let baseURL = directory.appending(path: base)
            removeSQLiteBundle(at: baseURL, fileManager: fm)
        }

        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents {
            let name = url.lastPathComponent
            let isStore = name.hasSuffix(".store")
                || name.contains(".store-")
                || name.hasSuffix(".sqlite")
                || name.contains(".sqlite-")
            if isStore {
                removeSQLiteBundle(at: url, fileManager: fm)
            }
        }
    }

    private static func removeSQLiteBundle(at url: URL, fileManager fm: FileManager) {
        let path = url.path
        for candidate in [path, path + "-shm", path + "-wal", path + ".shm", path + ".wal"] {
            if fm.fileExists(atPath: candidate) {
                try? fm.removeItem(at: URL(fileURLWithPath: candidate))
            }
        }
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(at: url)
        }
    }
}
