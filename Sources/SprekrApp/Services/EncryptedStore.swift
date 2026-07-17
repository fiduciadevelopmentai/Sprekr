import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SprekrCore

private final class KeychainQueryBox: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}

private final class KeychainQueryResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (status: OSStatus, data: Data?)?

    func finish(status: OSStatus, item: CFTypeRef?) {
        lock.lock()
        value = (status, item as? Data)
        lock.unlock()
    }

    func snapshot() -> (status: OSStatus, data: Data?)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Keeps an already unlocked encryption key available for the lifetime of the
/// process. macOS may otherwise show the login-keychain ACL prompt every time a
/// repository reloads after dictation, even though the owner already approved
/// access. The cache never touches disk and disappears when Sprekr quits.
final class KeychainDataCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for account: String) -> Data? {
        lock.withLock { values[account] }
    }

    func store(_ data: Data, for account: String) {
        lock.withLock { values[account] = data }
    }

    func remove(account: String) {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

enum RuntimeSigningIdentity {
    static func isCertificateBound() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate]
        else { return false }
        return !certificates.isEmpty
    }
}

enum KeychainAccountPolicy {
    static let version2Suffix = ".v2"

    static func activeAccount(baseAccount: String, certificateBound: Bool) -> String {
        certificateBound ? baseAccount + version2Suffix : baseAccount
    }
}

enum KeychainMigrationDecision: Equatable {
    case useActive
    case copyLegacyToVersion2
    case createActive
    case rejectMissingKey
}

enum KeychainMigrationPolicy {
    static func decision(
        certificateBound: Bool,
        activeKeyExists: Bool,
        legacyKeyExists: Bool,
        encryptedDataExists: Bool
    ) -> KeychainMigrationDecision {
        if activeKeyExists { return .useActive }
        if certificateBound && legacyKeyExists { return .copyLegacyToVersion2 }
        if encryptedDataExists { return .rejectMissingKey }
        return .createActive
    }
}

enum EncryptedStoreError: LocalizedError {
    case missingKeyForExistingData
    case keyMigrationVerificationFailed

    var errorDescription: String? {
        switch self {
        case .missingKeyForExistingData:
            "Encrypted Sprekr data exists, but its Keychain key is unavailable. The app will not replace it with a new key."
        case .keyMigrationVerificationFailed:
            "Sprekr could not safely migrate the encryption key. The original Keychain item was kept."
        }
    }
}

struct ResolvedEncryptionKey {
    let account: String
    let keyData: Data
    let legacyAccountPendingDeletion: String?

    var key: SymmetricKey { SymmetricKey(data: keyData) }
}

enum PrivateFilePermissions {
    static let directoryMode = 0o700
    static let fileMode = 0o600

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryMode]
        )
        try set(directoryMode, at: url)
    }

    static func secureFile(_ url: URL) throws {
        try set(fileMode, at: url)
    }

    static func set(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path
        )
    }
}

enum KeychainStore {
    // Raw value of the long-standing Security.framework
    // `kSecUseAuthenticationUIFail` constant. Referencing the symbol directly
    // emits a deprecation warning even though the modern LAContext-only path
    // still blocks on legacy login-keychain ACL prompts on current macOS.
    static let authenticationUIFailValue = "u_AuthUIF"
    private static let keyCache = KeychainDataCache()

    static func data(for account: String, allowingUserInteraction: Bool) throws -> Data? {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = !allowingUserInteraction
        let query = dataQuery(
            account: account,
            authenticationContext: authenticationContext,
            allowingUserInteraction: allowingUserInteraction
        )
        return try copyData(
            matching: query,
            timeout: allowingUserInteraction ? nil : 1
        )
    }

    static func dataQuery(
        account: String,
        authenticationContext: LAContext,
        allowingUserInteraction: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SprekrIdentity.Compatibility.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext,
        ]
        if !allowingUserInteraction {
            // `LAContext.interactionNotAllowed` alone does not stop the legacy
            // macOS Keychain API from waiting on an ACL prompt. This explicit
            // Security.framework flag makes startup fail fast instead, allowing
            // the app to present its deliberate "Unlock history" recovery UI.
            query[kSecUseAuthenticationUI as String] = authenticationUIFailValue
        }
        return query
    }

    private static func copyData(
        matching query: [String: Any],
        timeout: TimeInterval?
    ) throws -> Data? {
        let status: OSStatus
        let data: Data?

        if let timeout {
            let queryBox = KeychainQueryBox(query)
            let result = KeychainQueryResult()
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                var item: CFTypeRef?
                let status = SecItemCopyMatching(queryBox.value as CFDictionary, &item)
                result.finish(status: status, item: item)
                semaphore.signal()
            }

            guard semaphore.wait(timeout: .now() + timeout) == .success,
                  let snapshot = result.snapshot()
            else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(errSecInteractionNotAllowed)
                )
            }
            status = snapshot.status
            data = snapshot.data
        } else {
            var item: CFTypeRef?
            status = SecItemCopyMatching(query as CFDictionary, &item)
            data = item as? Data
        }

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    static func resolveKey(
        baseAccount: String,
        existingEncryptedData: Bool,
        allowingUserInteraction: Bool = true,
        certificateBound: Bool = RuntimeSigningIdentity.isCertificateBound()
    ) throws -> ResolvedEncryptionKey {
        let activeAccount = KeychainAccountPolicy.activeAccount(
            baseAccount: baseAccount,
            certificateBound: certificateBound
        )
        if let cached = keyCache.data(for: activeAccount) {
            return ResolvedEncryptionKey(
                account: activeAccount,
                keyData: cached,
                legacyAccountPendingDeletion: nil
            )
        }
        let activeData = try data(
            for: activeAccount,
            allowingUserInteraction: allowingUserInteraction
        )
        let legacyData = certificateBound
            ? try data(for: baseAccount, allowingUserInteraction: allowingUserInteraction)
            : nil
        let decision = KeychainMigrationPolicy.decision(
            certificateBound: certificateBound,
            activeKeyExists: activeData != nil,
            legacyKeyExists: legacyData != nil,
            encryptedDataExists: existingEncryptedData
        )

        if case .useActive = decision, let activeData {
            keyCache.store(activeData, for: activeAccount)
            return ResolvedEncryptionKey(
                account: activeAccount,
                keyData: activeData,
                legacyAccountPendingDeletion: nil
            )
        }

        if case .copyLegacyToVersion2 = decision, let legacy = legacyData {
            try add(
                legacy,
                account: activeAccount,
                accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            )
            guard let verified = try data(
                for: activeAccount,
                allowingUserInteraction: allowingUserInteraction
            ), verified == legacy else {
                try? delete(account: activeAccount)
                throw EncryptedStoreError.keyMigrationVerificationFailed
            }
            keyCache.store(legacy, for: activeAccount)
            return ResolvedEncryptionKey(
                account: activeAccount,
                keyData: legacy,
                legacyAccountPendingDeletion: baseAccount
            )
        }

        guard decision != .rejectMissingKey else {
            throw EncryptedStoreError.missingKeyForExistingData
        }

        let keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try add(
            keyData,
            account: activeAccount,
            accessibility: certificateBound
                ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        keyCache.store(keyData, for: activeAccount)
        return ResolvedEncryptionKey(
            account: activeAccount,
            keyData: keyData,
            legacyAccountPendingDeletion: nil
        )
    }

    private static func add(
        _ keyData: Data,
        account: String,
        accessibility: CFString
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SprekrIdentity.Compatibility.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: accessibility,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func finalizeMigration(
        _ resolved: ResolvedEncryptionKey,
        allowingUserInteraction: Bool = true
    ) throws {
        guard let legacy = resolved.legacyAccountPendingDeletion else { return }
        guard let verified = try data(
            for: resolved.account,
            allowingUserInteraction: allowingUserInteraction
        ), verified == resolved.keyData else {
            throw EncryptedStoreError.keyMigrationVerificationFailed
        }
        try delete(account: legacy)
        keyCache.remove(account: legacy)
    }

    static func rollbackMigration(_ resolved: ResolvedEncryptionKey) {
        guard resolved.legacyAccountPendingDeletion != nil else { return }
        try? delete(account: resolved.account)
        keyCache.remove(account: resolved.account)
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SprekrIdentity.Compatibility.keychainService,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

struct EncryptedJSONStore<Value: Codable> {
    private let fileURL: URL
    private let keyAccount: String

    init(filename: String, keyAccount: String) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                SprekrIdentity.Compatibility.applicationSupportDirectoryName,
                isDirectory: true
            )
        self.fileURL = root.appendingPathComponent(filename)
        self.keyAccount = keyAccount
    }

    func load(default defaultValue: Value, allowingKeychainInteraction: Bool = true) throws -> Value {
        try PrivateFilePermissions.ensureDirectory(fileURL.deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return defaultValue }
        try PrivateFilePermissions.secureFile(fileURL)
        let encryptedData = try Data(contentsOf: fileURL)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let resolved = try KeychainStore.resolveKey(
            baseAccount: keyAccount,
            existingEncryptedData: true,
            allowingUserInteraction: allowingKeychainInteraction
        )
        do {
            let plaintext = try AES.GCM.open(sealedBox, using: resolved.key)
            let value = try JSONDecoder.sprekr.decode(Value.self, from: plaintext)
            try KeychainStore.finalizeMigration(
                resolved,
                allowingUserInteraction: allowingKeychainInteraction
            )
            return value
        } catch {
            KeychainStore.rollbackMigration(resolved)
            throw error
        }
    }

    func save(_ value: Value) throws {
        let root = fileURL.deletingLastPathComponent()
        try PrivateFilePermissions.ensureDirectory(root)
        let hadEncryptedData = FileManager.default.fileExists(atPath: fileURL.path)
        let resolved = try KeychainStore.resolveKey(
            baseAccount: keyAccount,
            existingEncryptedData: hadEncryptedData
        )
        let plaintext = try JSONEncoder.sprekr.encode(value)
        let sealedBox = try AES.GCM.seal(plaintext, using: resolved.key)
        guard let encryptedData = sealedBox.combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try encryptedData.write(to: fileURL, options: [.atomic])
            try PrivateFilePermissions.secureFile(fileURL)
            let reloaded = try Data(contentsOf: fileURL)
            let verifiedBox = try AES.GCM.SealedBox(combined: reloaded)
            let verifiedPlaintext = try AES.GCM.open(verifiedBox, using: resolved.key)
            _ = try JSONDecoder.sprekr.decode(Value.self, from: verifiedPlaintext)
            try KeychainStore.finalizeMigration(resolved)
        } catch {
            KeychainStore.rollbackMigration(resolved)
            throw error
        }
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

extension JSONEncoder {
    static let sprekr: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let sprekr: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
