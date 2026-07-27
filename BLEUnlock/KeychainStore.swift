import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        String(format: t("telegram_error_keychain_status"), statusCode)
    }

    private var statusCode: OSStatus {
        switch self {
        case .status(let status): return status
        }
    }
}

final class KeychainStore: SecretStoring {
    let service: String
    let accessGroup: String?

    init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(for account: String) -> [CFString: Any] {
        var result: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if let accessGroup = accessGroup {
            result[kSecAttrAccessGroup] = accessGroup
        }
        return result
    }

    func string(for account: String) throws -> String? {
        var query = query(for: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.status(status)
        }
        return value
    }

    func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(for: account) as CFDictionary,
                                   [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainStoreError.status(status) }
        var attributes = query(for: account)
        attributes[kSecValueData] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainStoreError.status(addStatus) }
    }

    func removeValue(for account: String) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }
}
