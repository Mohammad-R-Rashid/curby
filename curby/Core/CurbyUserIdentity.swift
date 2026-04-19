//
//  CurbyUserIdentity.swift
//  curby
//
//  Persists a stable anonymous device user id for backend integration.
//

import Foundation
import Security

enum CurbyUserIdentity {
    private static let service = "com.hackmsa.curby"
    private static let account = "curby.user-id"

    static func loadOrCreateUserID() -> String {
        if let existing = readValue() {
            return existing
        }

        let newID = UUID().uuidString.lowercased()
        saveValue(newID)
        return newID
    }

    private static func readValue() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard
            status == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        else {
            return nil
        }

        return value
    }

    private static func saveValue(_ value: String) {
        let data = Data(value.utf8)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]

            let update: [String: Any] = [
                kSecValueData as String: data
            ]

            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
    }
}
