import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case osStatus(OSStatus, String)
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case let .osStatus(status, operation):
            return "Keychain \(operation) failed (\(status))."
        case .invalidUTF8:
            return "Keychain returned invalid UTF-8 data."
        }
    }
}

final class KeychainStore {
    private let service: String

    init(service: String = "com.blawby.agent") {
        self.service = service
    }

    func read(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status, "read")
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidUTF8
        }
        return value
    }

    func write(_ value: String, account: String) throws {
        let payload = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let update: [String: Any] = [kSecValueData as String: payload]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.osStatus(updateStatus, "update")
        }

        var addQuery = query
        addQuery[kSecValueData as String] = payload
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.osStatus(addStatus, "write")
        }
    }

    func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess {
            return
        }
        throw KeychainError.osStatus(status, "delete")
    }
}
