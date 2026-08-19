import CryptoKit
import Foundation
import Security

enum PasswordVault {
    private static let folderName = "Unarchive"
    private static let keychainService = "com.shambhala222.unarchive"
    private static let keychainAccount = "recent-passwords"

    static func recent() -> [String] {
        migrateFromKeychainIfNeeded()
        guard let data = decrypt(read(vaultURL)),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values.filter { !$0.isEmpty }
    }

    static func remember(_ password: String) {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var values = recent().filter { $0 != trimmed }
        values.insert(trimmed, at: 0)
        writeEncrypted(values)
    }

    static func remove(_ password: String) {
        writeEncrypted(recent().filter { $0 != password })
    }

    static func clear() {
        try? FileManager.default.removeItem(at: vaultURL)
        deleteKeychainItem()
    }

    static var count: Int { recent().count }

    private static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    private static var vaultURL: URL {
        supportFolder.appendingPathComponent("password-vault.dat")
    }

    private static var keyURL: URL {
        supportFolder.appendingPathComponent("password-vault.key")
    }

    private static func ensureFolder() throws {
        try FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: supportFolder.path
        )
    }

    private static func vaultKey() throws -> SymmetricKey {
        try ensureFolder()
        if let existing = read(keyURL), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return SymmetricKey(size: .bits256)
        }
        let data = Data(bytes)
        try data.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return SymmetricKey(data: data)
    }

    private static func writeEncrypted(_ values: [String]) {
        guard let plain = try? JSONEncoder().encode(values),
              let key = try? vaultKey(),
              let sealed = try? AES.GCM.seal(plain, using: key),
              let combined = sealed.combined else { return }
        try? combined.write(to: vaultURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
    }

    private static func decrypt(_ data: Data?) -> Data? {
        guard let data, let key = try? vaultKey() else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else {
            return nil
        }
        return plain
    }

    private static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    private static func migrateFromKeychainIfNeeded() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return }
        let imported = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        deleteKeychainItem()
        guard !imported.isEmpty else { return }
        var merged = imported
        if let existing = decrypt(read(vaultURL)),
           let current = try? JSONDecoder().decode([String].self, from: existing) {
            for value in current.reversed() where !merged.contains(value) {
                merged.insert(value, at: 0)
            }
        }
        writeEncrypted(merged)
    }

    private static func deleteKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
