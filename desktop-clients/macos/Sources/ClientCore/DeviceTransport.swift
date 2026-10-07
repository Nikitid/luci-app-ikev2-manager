import Foundation
import Security

public enum DeviceError: String, Error, Sendable {
    case invalidEndpoint, connectionFailed, accessRejected, httpRejected, invalidResponse
    case pathUnavailable, differentPolicy
}

/// A registration that is still waiting for the router, or its result.
public struct EnrollmentAnswer: Sendable {
    public let id: String
    public let policy: Data?
    public let password: String?
    public init(id: String, policy: Data?, password: String?) { self.id = id; self.policy = policy; self.password = password }
    public var pending: Bool { policy == nil }
}

/// What the router attests for one device at one tunnel address.
public struct DeviceReadiness: Sendable, Equatable {
    public let id: String
    public let address: String
    public let revision: Int
    public init(id: String, address: String, revision: Int) { self.id = id; self.address = address; self.revision = revision }
}

/// The names a device shows its user. It grants nothing and carries no addresses.
public struct DeviceServices: Sendable, Equatable {
    public let selected: [String]
    public let available: [String]
    public let domains: Int
    public init(selected: [String], available: [String], domains: Int) { self.selected = selected; self.available = available; self.domains = domains }
}

/// What the runtime asks of the router. The network implementation is below.
public protocol DeviceRequests: Sendable {
    func claim(endpoint: URL, invitation: String, deviceToken: String) async throws -> EnrollmentAnswer
    func poll(endpoint: URL, deviceToken: String) async throws -> EnrollmentAnswer
    func policy(endpoint: URL, deviceToken: String) async throws -> Data
    func readiness(endpoint: URL, deviceToken: String, tunnelAddress: String) async throws -> DeviceReadiness
    func services(endpoint: URL, deviceToken: String, id: String) async throws -> DeviceServices
    func release(endpoint: URL, deviceToken: String) async throws -> String
}

/// Requests of an enrolled or enrolling device. Platform certificate and
/// hostname validation always applies; an additional anchor exists only for
/// a disposable test router and is never set by the installed daemon.
public struct DeviceTransport: DeviceRequests {
    public let additionalAnchor: Data?

    public init(additionalAnchor: Data? = nil) { self.additionalAnchor = additionalAnchor }

    static let token = #"\A[a-f0-9]{64}\z"#
    static let identifier = #"\A[a-z][a-z0-9-]{0,47}\z"#
    static let service = #"\A[a-z0-9][a-z0-9_-]{0,47}\z"#

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The enrolled server's URL for one of the device paths.
    public static func endpoint(_ base: URL, path: String) throws -> URL {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, host.count <= 253, host.contains("."),
              matches(host, #"\A[a-zA-Z0-9.-]+\z"#), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              base.absoluteString.count <= 2048,
              ["/client/v1/enroll", "/client/v1/enrollment", "/client/v1/policy",
               "/client/v1/readiness", "/client/v1/services", "/client/v1/release"].contains(parts.percentEncodedPath),
              path.hasPrefix("/client/v1/")
        else { throw DeviceError.invalidEndpoint }
        parts.percentEncodedPath = path
        guard let url = parts.url else { throw DeviceError.invalidEndpoint }
        return url
    }

    /// Splits `https://host[:port]/client/v1/enroll#<token>` without keeping the token in a URL.
    public static func parseInvitation(_ text: String) throws -> (endpoint: URL, token: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.components(separatedBy: "#")
        guard pieces.count == 2, matches(pieces[1], token), let url = URL(string: pieces[0]),
              url.path == "/client/v1/enroll" else { throw DeviceError.invalidEndpoint }
        return (try endpoint(url, path: "/client/v1/enroll"), pieces[1])
    }

    private func send(_ url: URL, method: String, headers: [String: String], limit: Int, timeout: TimeInterval)
        async throws -> (status: Int, data: Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: DeviceSessionDelegate(anchor: additionalAnchor), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if method == "POST" { request.httpBody = Data() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DeviceError.invalidResponse }
            if http.statusCode == 200 || http.statusCode == 202 {
                guard data.count <= limit, !data.isEmpty, String(data: data, encoding: .utf8) != nil,
                      http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
                        .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
                else { throw DeviceError.invalidResponse }
            }
            return (http.statusCode, data)
        } catch let error as DeviceError { throw error }
        catch { throw DeviceError.connectionFailed }
    }

    static func object(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(root.keys) == keys
        else { throw DeviceError.invalidResponse }
        return root
    }

    static func integer(_ value: Any?, _ range: ClosedRange<Int>) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue), range.contains(number.intValue)
        else { throw DeviceError.invalidResponse }
        return number.intValue
    }

    static func decodeEnrollment(status: Int, data: Data) throws -> EnrollmentAnswer {
        if status == 202 {
            let root = try object(data, keys: ["version", "state", "id"])
            guard try integer(root["version"], 1...1) == 1, root["state"] as? String == "pending",
                  let id = root["id"] as? String, matches(id, identifier) else { throw DeviceError.invalidResponse }
            return EnrollmentAnswer(id: id, policy: nil, password: nil)
        }
        guard status == 200 else { throw DeviceError.httpRejected }
        let root = try object(data, keys: ["version", "state", "policy", "credentials"])
        guard try integer(root["version"], 1...1) == 1, root["state"] as? String == "enrolled",
              let document = root["policy"], JSONSerialization.isValidJSONObject(document),
              let credentials = root["credentials"] as? [String: Any], Set(credentials.keys) == ["username", "password"],
              let username = credentials["username"] as? String, let password = credentials["password"] as? String,
              matches(password, token)
        else { throw DeviceError.invalidResponse }
        let raw = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        guard let policy = try? ClientPolicy(data: raw), policy.id == username else { throw DeviceError.invalidResponse }
        return EnrollmentAnswer(id: username, policy: raw, password: password)
    }

    /// Binds the invitation to this device's own key. A repeat with the same pair is harmless.
    public func claim(endpoint: URL, invitation: String, deviceToken: String) async throws -> EnrollmentAnswer {
        guard Self.matches(invitation, Self.token), Self.matches(deviceToken, Self.token), invitation != deviceToken
        else { throw DeviceError.invalidEndpoint }
        let answer = try await send(try Self.endpoint(endpoint, path: "/client/v1/enroll"), method: "POST",
            headers: ["Authorization": "Bearer " + invitation, "X-Device-Token": deviceToken], limit: 1_048_576, timeout: 10)
        if answer.status == 401 { throw DeviceError.accessRejected }
        guard answer.status == 202 else { throw DeviceError.httpRejected }
        return try Self.decodeEnrollment(status: 202, data: answer.data)
    }

    public func poll(endpoint: URL, deviceToken: String) async throws -> EnrollmentAnswer {
        guard Self.matches(deviceToken, Self.token) else { throw DeviceError.invalidEndpoint }
        let answer = try await send(try Self.endpoint(endpoint, path: "/client/v1/enrollment"), method: "GET",
            headers: ["Authorization": "Bearer " + deviceToken], limit: 1_048_576, timeout: 10)
        if answer.status == 401 { throw DeviceError.accessRejected }
        return try Self.decodeEnrollment(status: answer.status, data: answer.data)
    }

    public func policy(endpoint: URL, deviceToken: String) async throws -> Data {
        guard Self.matches(deviceToken, Self.token) else { throw DeviceError.invalidEndpoint }
        let answer = try await send(try Self.endpoint(endpoint, path: "/client/v1/policy"), method: "GET",
            headers: ["Authorization": "Bearer " + deviceToken], limit: 1_048_576, timeout: 10)
        if answer.status == 401 { throw DeviceError.accessRejected }
        guard answer.status == 200 else { throw DeviceError.httpRejected }
        return answer.data
    }

    static func decodeReadiness(_ data: Data) throws -> DeviceReadiness {
        let root = try object(data, keys: ["version", "state", "id", "revision", "policy_sha256", "address", "generation", "expires_at"])
        guard try integer(root["version"], 1...1) == 1, root["state"] as? String == "ready",
              let id = root["id"] as? String, matches(id, identifier),
              let digest = root["policy_sha256"] as? String, matches(digest, token),
              let address = root["address"] as? String,
              matches(address, #"\A(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\z"#)
        else { throw DeviceError.invalidResponse }
        _ = try integer(root["generation"], 1...Int(Int32.max))
        _ = try integer(root["expires_at"], 1...Int.max)
        return DeviceReadiness(id: id, address: address, revision: try integer(root["revision"], 1...Int(Int32.max)))
    }

    /// The router's answer to "is my path in effect for this tunnel address now".
    public func readiness(endpoint: URL, deviceToken: String, tunnelAddress: String) async throws -> DeviceReadiness {
        guard Self.matches(deviceToken, Self.token) else { throw DeviceError.invalidEndpoint }
        let answer = try await send(try Self.endpoint(endpoint, path: "/client/v1/readiness"), method: "GET",
            headers: ["Authorization": "Bearer " + deviceToken, "X-Client-Address": tunnelAddress], limit: 4096, timeout: 3)
        if answer.status == 401 { throw DeviceError.accessRejected }
        guard answer.status == 200 else { throw DeviceError.pathUnavailable }
        return try Self.decodeReadiness(answer.data)
    }

    static func decodeServices(_ data: Data, id: String) throws -> DeviceServices {
        let root = try object(data, keys: ["version", "id", "revision", "selected", "available"])
        guard try integer(root["version"], 1...1) == 1, root["id"] as? String == id else { throw DeviceError.invalidResponse }
        _ = try integer(root["revision"], 1...Int(Int32.max))
        var lists: [[String]] = [], domains = 0
        for key in ["selected", "available"] {
            guard let items = root[key] as? [[String: Any]], items.count <= 512 else { throw DeviceError.invalidResponse }
            var names: [String] = []
            for item in items {
                guard Set(item.keys) == ["id", "domains"], let name = item["id"] as? String,
                      matches(name, service), !names.contains(name) else { throw DeviceError.invalidResponse }
                let count = try integer(item["domains"], 0...65536)
                if key == "selected" { domains += count }
                names.append(name)
            }
            lists.append(names)
        }
        return DeviceServices(selected: lists[0], available: lists[1], domains: domains)
    }

    static func decodeRelease(_ data: Data) throws -> String {
        let root = try object(data, keys: ["version", "release"])
        guard try integer(root["version"], 1...1) == 1, let release = root["release"] as? String,
              matches(release, #"\A[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}\z"#) else { throw DeviceError.invalidResponse }
        return release
    }

    /// The version of the router's package, which the clients are released
    /// with. A number only: where to download is the client's own knowledge.
    public func release(endpoint: URL, deviceToken: String) async throws -> String {
        guard Self.matches(deviceToken, Self.token) else { throw DeviceError.invalidEndpoint }
        let answer = try await send(try Self.endpoint(endpoint, path: "/client/v1/release"), method: "GET",
            headers: ["Authorization": "Bearer " + deviceToken], limit: 1024, timeout: 5)
        guard answer.status == 200 else { throw DeviceError.httpRejected }
        return try Self.decodeRelease(answer.data)
    }

    public func services(endpoint: URL, deviceToken: String, id: String) async throws -> DeviceServices {
        guard Self.matches(deviceToken, Self.token) else { throw DeviceError.invalidEndpoint }
        let answer = try await send(try Self.endpoint(endpoint, path: "/client/v1/services"), method: "GET",
            headers: ["Authorization": "Bearer " + deviceToken], limit: 65536, timeout: 5)
        guard answer.status == 200 else { throw DeviceError.httpRejected }
        return try Self.decodeServices(answer.data, id: id)
    }
}

private final class DeviceSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    private let anchor: Data?
    init(anchor: Data?) { self.anchor = anchor }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let anchor, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecCertificateCreateWithData(nil, anchor as CFData) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // The hostname policy stays; only the set of roots grows by one.
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        completionHandler(SecTrustEvaluateWithError(trust, nil) ? .useCredential : .cancelAuthenticationChallenge,
                          SecTrustEvaluateWithError(trust, nil) ? URLCredential(trust: trust) : nil)
    }
}
