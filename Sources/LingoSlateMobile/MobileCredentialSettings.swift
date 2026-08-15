#if os(iOS)
import Combine
import Foundation
import Security

@MainActor
public final class MobileCredentialSettings: ObservableObject {
    @Published public var endpointText: String
    @Published public var brokerToken: String
    @Published public private(set) var errorMessage: String?

    private static let endpointKey = "LingoSlate.Mobile.CredentialEndpoint"
    private static let keychainService = "com.timmor51z.LingoSlate"
    private static let keychainAccount = "soniox-broker-token"

    public init() {
        endpointText = UserDefaults.standard.string(forKey: Self.endpointKey)
            ?? "https://lingoslate-soniox-key-broker.timmor51z.workers.dev/v1/soniox/temporary-key"
        brokerToken = Self.readToken() ?? ""
    }

    public var isConfigured: Bool {
        validatedEndpoint != nil
            && !brokerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    public func save() -> Bool {
        guard let endpoint = validatedEndpoint else {
            errorMessage = "请输入有效的 HTTPS 服务地址"
            return false
        }
        let token = brokerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "请输入 broker token"
            return false
        }
        do {
            try Self.writeToken(token)
            endpointText = endpoint.absoluteString
            brokerToken = token
            UserDefaults.standard.set(endpoint.absoluteString, forKey: Self.endpointKey)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func temporaryAPIKey() async throws -> String {
        guard let endpoint = validatedEndpoint else {
            throw MobileCredentialError.invalidEndpoint
        }
        let token = brokerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw MobileCredentialError.missingToken }
        return try await MobileAPIKeyProvider.temporaryKey(
            endpoint: endpoint,
            bearerToken: token
        )()
    }

    private var validatedEndpoint: URL? {
        guard let endpoint = URL(
            string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        ), endpoint.scheme == "https", endpoint.host != nil else { return nil }
        return endpoint
    }

    private static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw MobileCredentialError.keychain(updateStatus)
        }
        var insertion = query
        insertion[kSecValueData as String] = data
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MobileCredentialError.keychain(addStatus)
        }
    }
}

private enum MobileCredentialError: LocalizedError {
    case invalidEndpoint
    case missingToken
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "尚未配置临时凭证服务"
        case .missingToken:
            return "尚未配置 broker token"
        case let .keychain(status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "无法保存 broker token"
        }
    }
}
#endif
