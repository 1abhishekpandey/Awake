import Foundation
import Security

/// The plug's device ID, local key and LAN address. They live only in the login
/// Keychain of this Mac, never in the repo or the app bundle.
///
/// Stored as one generic password (service `keychainService`, account
/// `keychainAccount`) whose value is JSON:
///
///     {"deviceId": "...", "localKey": "...", "host": "192.168.1.50", "switchDP": 1}
///
/// `Scripts/set-plug-credentials.sh` writes it.
struct PlugCredentials: Sendable, Equatable {
    static let keychainService = "com.abhishek.awake.smart-plug"
    static let keychainAccount = "plug"

    var deviceID: String
    /// AES-128 key: the 16-character local key as bytes.
    var key: Data
    var host: String
    var switchDP: Int

    /// Parses the Keychain JSON. Nil when a field is missing or the key isn't 16 bytes.
    init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let deviceID = object["deviceId"] as? String, !deviceID.isEmpty,
              let localKey = object["localKey"] as? String, localKey.utf8.count == 16,
              let host = object["host"] as? String, !host.isEmpty
        else { return nil }
        self.deviceID = deviceID
        self.key = Data(localKey.utf8)
        self.host = host
        self.switchDP = object["switchDP"] as? Int ?? 1
    }

    /// Reads the credentials from the Keychain, or nil if they aren't set up.
    static func load() -> PlugCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return PlugCredentials(json: data)
    }
}
