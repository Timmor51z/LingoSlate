import Combine
import Foundation
import Security

@MainActor
final class SonioxCredentialStore: ObservableObject {
    @Published private(set) var storedAPIKey = ""
    @Published private(set) var errorMessage: String?

    private static let service = "com.timmorzhu.LingoSlate.soniox"
    private static let account = "api-key"

    init() {
        storedAPIKey = Self.read() ?? ""
    }

    var effectiveAPIKey: String {
        if !storedAPIKey.isEmpty { return storedAPIKey }
        return ProcessInfo.processInfo.environment["SONIOX_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var hasAPIKey: Bool { !effectiveAPIKey.isEmpty }
    var usesEnvironment: Bool { storedAPIKey.isEmpty && hasAPIKey }

    func save(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            clear()
            return
        }
        let data = Data(value.utf8)
        let query = Self.baseQuery
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess {
            storedAPIKey = value
            errorMessage = nil
        } else {
            errorMessage = "Soniox API Key 保存失败（\(status)）"
        }
    }

    func clear() {
        let status = SecItemDelete(Self.baseQuery as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            storedAPIKey = ""
            errorMessage = nil
        } else {
            errorMessage = "Soniox API Key 删除失败（\(status)）"
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
