import Foundation

public enum MobileAPIKeyProvider {
    public static func temporaryKey(
        endpoint: URL,
        bearerToken: String,
        session: URLSession = .shared
    ) -> MobileSessionController.APIKeyProvider {
        {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue(
                "Bearer \(bearerToken)",
                forHTTPHeaderField: "Authorization"
            )
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  200..<300 ~= response.statusCode else {
                throw TemporaryKeyError.requestFailed
            }
            let result = try JSONDecoder().decode(TemporaryKeyResponse.self, from: data)
            guard !result.apiKey.isEmpty else { throw TemporaryKeyError.invalidResponse }
            return result.apiKey
        }
    }
}

private struct TemporaryKeyResponse: Decodable {
    let apiKey: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
    }
}

private enum TemporaryKeyError: LocalizedError {
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return "无法获取临时 Soniox 凭证"
        case .invalidResponse:
            return "临时 Soniox 凭证格式无效"
        }
    }
}
