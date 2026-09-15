import Foundation
import Security

/// Small Keychain wrapper for OAuth tokens and remembered folder destinations.
enum KeychainStore {
    static func set(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prnysoni.Scany.cloud",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CloudError.message("Keychain save failed (\(status)).")
        }
    }

    static func data(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prnysoni.Scany.cloud",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prnysoni.Scany.cloud",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func setJSON<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        try set(data, account: account)
    }

    static func json<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let data = data(account: account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date
    var tokenType: String

    var isExpired: Bool {
        expiry.timeIntervalSinceNow < 60
    }
}

enum CloudDestinationStore {
    private static let destinationsAccount = "destinations"

    struct Record: Codable {
        var google: Entry?
        var iCloud: Entry?
        var lastProvider: CloudProvider?

        enum CodingKeys: String, CodingKey {
            case google, iCloud, lastProvider
        }

        init(google: Entry? = nil, iCloud: Entry? = nil, lastProvider: CloudProvider? = nil) {
            self.google = google
            self.iCloud = iCloud
            self.lastProvider = lastProvider
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            google = try container.decodeIfPresent(Entry.self, forKey: .google)
            iCloud = try container.decodeIfPresent(Entry.self, forKey: .iCloud)
            if let raw = try container.decodeIfPresent(String.self, forKey: .lastProvider) {
                lastProvider = CloudProvider(rawValue: raw)
            }
        }
    }

    struct Entry: Codable {
        var account: CloudAccount
        var folder: CloudFolder?
        var isSimulated: Bool
    }

    static func load() -> Record {
        KeychainStore.json(Record.self, account: destinationsAccount) ?? Record()
    }

    static func save(_ record: Record) {
        try? KeychainStore.setJSON(record, account: destinationsAccount)
    }
}
