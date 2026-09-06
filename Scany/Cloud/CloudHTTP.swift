import Foundation

enum CloudHTTP {
    static func jsonObject(from data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudError.message("Invalid cloud response.")
        }
        return (data, http)
    }

    static func requireOK(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            let clipped = snippet.count > 280 ? String(snippet.prefix(280)) + "…" : snippet
            throw CloudError.http(response.statusCode, clipped)
        }
    }

    static func formEncode(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func queryItems(_ items: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery ?? ""
    }
}
