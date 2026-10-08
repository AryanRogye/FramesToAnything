#if os(macOS)
import Foundation
import Security

enum TrustedReceiverStore {
    nonisolated private static let service = "com.aryanrogye.macOSFramesToFireTV.remembered-receivers"
    nonisolated private static let serviceNameMapKey = "discovery.rememberedReceiverIDs"
    nonisolated private static let fallbackSecretPrefix = "discovery.rememberedReceiverSecret."

    nonisolated static func contains(_ receiverID: String) -> Bool {
        load(receiverID) != nil
    }

    nonisolated static func load(_ receiverID: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: receiverID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }
        guard let value = UserDefaults.standard.string(
            forKey: fallbackSecretPrefix + receiverID
        ) else { return nil }
        return Data(base64Encoded: value)
    }

    nonisolated static func save(_ secret: Data, for receiverID: String) {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: receiverID,
        ]
        let attributes = [kSecValueData as String: secret]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        let saveStatus: OSStatus
        if updateStatus == errSecItemNotFound {
            var item = lookup
            item[kSecValueData as String] = secret
            saveStatus = SecItemAdd(item as CFDictionary, nil)
        } else {
            saveStatus = updateStatus
        }
        if saveStatus == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackSecretPrefix + receiverID)
        } else {
            UserDefaults.standard.set(
                secret.base64EncodedString(),
                forKey: fallbackSecretPrefix + receiverID
            )
        }
    }

    nonisolated static func associate(receiverID: String, withServiceName serviceName: String) {
        var mappings = UserDefaults.standard.dictionary(forKey: serviceNameMapKey) as? [String: String]
            ?? [:]
        mappings[serviceName] = receiverID
        UserDefaults.standard.set(mappings, forKey: serviceNameMapKey)
    }

    nonisolated static func receiverID(forServiceName serviceName: String) -> String? {
        let mappings = UserDefaults.standard.dictionary(forKey: serviceNameMapKey) as? [String: String]
        return mappings?[serviceName]
    }

    nonisolated static func delete(_ receiverID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: receiverID,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackSecretPrefix + receiverID)
        if var mappings = UserDefaults.standard.dictionary(forKey: serviceNameMapKey)
            as? [String: String] {
            mappings = mappings.filter { $0.value != receiverID }
            UserDefaults.standard.set(mappings, forKey: serviceNameMapKey)
        }
    }
}
#endif
