import Foundation

public enum PolicyFetchError: String, Error, Sendable {
    case invalidEndpoint, connectionFailed, httpRejected, deviceAccessRevoked
    case invalidResponse, responseTooLarge, updateRejected
}

/// Uses only the endpoint and device key authenticated during enrollment.
/// Fetching proposes a policy; the privileged activation transaction commits it.
public enum PolicyTransportClient {
    static let limit = 1_048_576

    static func validate(endpoint: URL, token: String) throws {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host,
              host.count <= 253, host.contains("."),
              host.range(of: #"\A[a-zA-Z0-9.-]+\z"#, options: .regularExpression) != nil,
              !host.allSatisfy({ $0.isNumber || $0 == "." }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/client/v1/policy", endpoint.absoluteString.count <= 2048,
              token.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil
        else { throw PolicyFetchError.invalidEndpoint }
    }

    static func decode(data: Data, contentType: String?, length: Int64) throws -> ClientPolicy {
        guard data.count <= limit else { throw PolicyFetchError.responseTooLarge }
        guard let contentType,
              contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
              !data.isEmpty, length < 0 || length == data.count,
              String(data: data, encoding: .utf8) != nil
        else { throw PolicyFetchError.invalidResponse }
        do { return try ClientPolicy(data: data) }
        catch { throw PolicyFetchError.invalidResponse }
    }

    public static func fetch(endpoint: URL, token: String, committed: PolicyHistory) async throws -> ClientPolicy {
        try validate(endpoint: endpoint, token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        // Default platform certificate and hostname validation remains enabled.
        let session = URLSession(configuration: configuration, delegate: PolicyRedirectRefusal(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw PolicyFetchError.invalidResponse }
            if http.statusCode == 401 { throw PolicyFetchError.deviceAccessRevoked }
            guard http.statusCode == 200 else { throw PolicyFetchError.httpRejected }
            guard http.expectedContentLength <= limit else { throw PolicyFetchError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw PolicyFetchError.responseTooLarge }
                data.append(byte)
            }
            let policy = try decode(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                    length: http.expectedContentLength)
            do { _ = try committed.proposing(policy) }
            catch { throw PolicyFetchError.updateRejected }
            return policy
        } catch let error as PolicyFetchError { throw error }
        catch { throw PolicyFetchError.connectionFailed }
    }
}

private final class PolicyRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
