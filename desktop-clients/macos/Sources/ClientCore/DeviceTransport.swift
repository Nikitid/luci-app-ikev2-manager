import Foundation
import Security

public enum DeviceError: String, Error, Sendable, CaseIterable {
    case invalidEndpoint, connectionFailed, accessRejected, noServices, httpRejected, invalidResponse
    case pathUnavailable, differentPolicy
    /// The router did not take the person's own addresses: not valid, not allowed, too often.
    case ownRefused, ownNotAllowed, ownTooOften
}

/// "Check now" was not taken: asked again too soon (and how many seconds are
/// left), or another check of this device is in progress.
public enum CheckRefusal: Error, Equatable, Sendable {
    case tooOften(Int)
    case busy
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

/// One service a person was offered, as this device has it: on or off,
/// required or not, blocked without the tunnel or not and whether that is the
/// person's to choose, and which of the policy's resources and networks it
/// holds. It grants nothing; the router decides what passes.
/// Whether a service works now, as the router routes it. A router that does
/// not say is `unknown`, and nothing is drawn for it.
public struct ServiceHealth: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable { case ok, down, direct, unknown }
    public var state: State
    /// Why it is down: "no_tunnel" or "silent".
    public var reason: String?
    /// Since when it works, seconds since 1970.
    public var since: Int?
    public init(state: State, reason: String? = nil, since: Int? = nil) { self.state = state; self.reason = reason; self.since = since }
    public static let unknown = ServiceHealth(state: .unknown)
}

public struct ServiceEntry: Sendable, Equatable, Codable {
    public let id: String
    /// The name to show; the identifier where the router gives none.
    public var label: String
    public let required: Bool
    public let on: Bool
    public let closed: Bool
    public let chooseClosed: Bool
    public let domains: Int
    public let networks: Int
    public let resources: [String]
    public let cidrs: [String]
    public var health = ServiceHealth.unknown
    /// Where it goes now on this device: "tunnel", "direct" or "blocked"; nil while it is off.
    public var path: String? = nil
    public init(id: String, required: Bool, on: Bool, closed: Bool, chooseClosed: Bool, domains: Int, networks: Int, resources: [String], cidrs: [String]) {
        self.id = id; self.label = id; self.required = required; self.on = on; self.closed = closed; self.chooseClosed = chooseClosed
        self.domains = domains; self.networks = networks; self.resources = resources; self.cidrs = cidrs
    }
}

/// Sites and networks the person added for this device, and how many and on
/// which ports the administrator allows. The router checks every one again.
public struct OwnAddresses: Sendable, Equatable, Codable {
    public let limit: Int
    public let ports: [Int]
    public let domains: [String]
    public let networks: [String]
    public init(limit: Int, ports: [Int], domains: [String], networks: [String]) {
        self.limit = limit; self.ports = ports; self.domains = domains; self.networks = networks
    }
    /// The service the router makes of them, which the window shows apart.
    public static func isService(_ id: String) -> Bool { id.hasPrefix("own-") }

    /// The same check as the router's (`client-access-own.uc`, examples in
    /// `fixtures/own-addresses.json`): a site, or why it is refused.
    public static func checkDomain(_ text: String, server: [String] = []) -> Result<String, OwnRefusal> {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = name.range(of: #"\A[a-z][a-z0-9+.-]*://"#, options: .regularExpression) { name.removeSubrange(range) }
        if let cut = name.firstIndex(where: { "/?#:".contains($0) }) { name = String(name[..<cut]) }
        if name.hasSuffix(".") { name.removeLast() }
        let refused = OwnRefusal(reason: "invalid_site", entry: text)
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.utf8.count <= 253, labels.count >= 2, !name.allSatisfy({ $0.isNumber || $0 == "." }) else { return .failure(refused) }
        for label in labels where label.count > 63 || label.range(of: #"\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z"#, options: .regularExpression) == nil {
            return .failure(refused)
        }
        if ["local", "lan", "home", "internal", "localhost", "arpa", "test", "invalid", "example"].contains(String(labels.last!)) {
            return .failure(OwnRefusal(reason: "local_name", entry: text))
        }
        if server.contains(name) { return .failure(OwnRefusal(reason: "server_name", entry: text)) }
        return .success(name)
    }

    private static let reserved: [(UInt32, Int, String)] = [
        (0x0000_0000, 8, "local"), (0x0A00_0000, 8, "private"), (0x6440_0000, 10, "shared"), (0x7F00_0000, 8, "local"),
        (0xA9FE_0000, 16, "local"), (0xAC10_0000, 12, "private"), (0xC000_0000, 24, "local"), (0xC000_0200, 24, "documentation"),
        (0xC0A8_0000, 16, "private"), (0xC612_0000, 15, "fake_ip"), (0xC633_6400, 24, "documentation"),
        (0xCB00_7100, 24, "documentation"), (0xE000_0000, 3, "multicast")]

    /// A network as the router takes it: an address alone is the host, a
    /// range is set at its base, nothing wider than /16 and nothing reserved.
    public static func checkNetwork(_ text: String) -> Result<String, OwnRefusal> {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func refuse(_ reason: String) -> Result<String, OwnRefusal> { .failure(OwnRefusal(reason: reason, entry: text)) }
        guard value.utf8.count <= 18 else { return refuse("invalid_network") }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return refuse("invalid_network") }
        let prefix = parts.count == 2 ? (parts[1].range(of: #"\A[0-9]{1,2}\z"#, options: .regularExpression) != nil ? Int(parts[1])! : -1) : 32
        guard (16...32).contains(prefix) else { return refuse("network_size") }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return refuse("invalid_network") }
        var address: UInt32 = 0
        for octet in octets {
            guard octet.count <= 3, octet.range(of: #"\A(0|[1-9][0-9]*)\z"#, options: .regularExpression) != nil,
                  let number = UInt32(octet), number <= 255 else { return refuse("invalid_network") }
            address = address << 8 | number
        }
        let size = UInt64(1) << (32 - prefix)
        let first = UInt64(address) - UInt64(address) % size, last = first + size - 1
        for (base, bits, reason) in reserved {
            let end = UInt64(base) + (UInt64(1) << (32 - bits)) - 1
            if first <= end && last >= UInt64(base) { return refuse(reason) }
        }
        let text = (0..<4).map { String((first >> (24 - 8 * $0)) & 0xFF) }.joined(separator: ".")
        return .success("\(text)/\(prefix)")
    }

    /// One field for both: what looks like an address is a network.
    public static func check(_ text: String, server: [String] = []) -> Result<(domain: String?, network: String?), OwnRefusal> {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value.allSatisfy({ $0.isNumber || $0 == "." || $0 == "/" }) {
            return checkNetwork(value).map { (nil, $0) }
        }
        return checkDomain(value, server: server).map { ($0, nil) }
    }

    /// What the person typed or pasted: a link is taken for its host, an
    /// address alone is the host itself, a range is kept as written. Nil for
    /// anything else. The router checks what is sent again.
    public static func parse(_ text: String) -> (domain: String?, network: String?)? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if !value.isEmpty, value.allSatisfy({ $0.isNumber || $0 == "." || $0 == "/" }) {
            let network = value.contains("/") ? value : value + "/32"
            return (try? PolicyValue.network(network)) != nil ? (nil, network) : nil
        }
        if let cut = value.firstIndex(where: { "/?#:".contains($0) }) { value = String(value[..<cut]) }
        if value.hasSuffix(".") { value.removeLast() }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.last!.allSatisfy(\.isNumber),
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" } })
        else { return nil }
        return (value, nil)
    }
}

/// Why a site or network of the person's own is not taken, and which one as
/// written ("over_limit" names none). The router gives the same reasons.
public struct OwnRefusal: Error, Sendable, Equatable, Codable {
    public let reason: String
    public let entry: String
    public init(reason: String, entry: String) { self.reason = reason; self.entry = entry }
}

/// Informational service names and tunnel network. It grants no access.
public struct DeviceServices: Sendable, Equatable {
    public let selected: [String]
    public let available: [String]
    public let domains: Int
    /// Whether services stay blocked while the tunnel is down. That is the
    /// rule; a router that says nothing about it means the rule.
    public var block = true
    /// Whether everything goes into the tunnel, or the services alone.
    public var full = false
    public var tunnelSubnet = ""
    /// What the person was offered, where the router gives an offer.
    public var entries: [ServiceEntry]? = nil
    /// Present where the person may add addresses of their own.
    public var own: OwnAddresses? = nil
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
    /// Whether the administrator asked this device for a report. Any failure is "no".
    func reportWanted(endpoint: URL, deviceToken: String) async -> Bool
    /// Sends the report to the router that asked; whether it was taken.
    func sendReport(endpoint: URL, deviceToken: String, report: Data) async -> Bool
    /// What this device chose of its offer: the optional services it turns
    /// on, and those it blocks without the tunnel where that is its choice.
    func choose(endpoint: URL, deviceToken: String, on: [String], closed: [String]) async throws
    /// The sites and networks this device keeps of its own, as a whole list.
    func setOwn(endpoint: URL, deviceToken: String, domains: [String], networks: [String]) async throws
    /// Asks the router to check the services now; seconds until it may be asked again.
    func checkNow(endpoint: URL, deviceToken: String) async throws -> Int
}

public extension DeviceRequests {
    func reportWanted(endpoint: URL, deviceToken: String) async -> Bool { false }
    func sendReport(endpoint: URL, deviceToken: String, report: Data) async -> Bool { false }
    func choose(endpoint: URL, deviceToken: String, on: [String], closed: [String]) async throws { throw DeviceError.httpRejected }
    func setOwn(endpoint: URL, deviceToken: String, domains: [String], networks: [String]) async throws { throw DeviceError.httpRejected }
    func checkNow(endpoint: URL, deviceToken: String) async throws -> Int { throw DeviceError.httpRejected }
}

/// Requests of an enrolled or enrolling device. Platform certificate and
/// hostname validation always applies; an additional anchor exists only for
/// a disposable test router and is never set by the installed daemon.
public struct DeviceTransport: DeviceRequests {
    public let additionalAnchor: Data?
    /// Which computer this is, for the administrator's list of devices.
    /// Sent with the policy request; nothing depends on it.
    public let about: [String: String]

    public init(additionalAnchor: Data? = nil, about: [String: String] = [:]) {
        self.additionalAnchor = additionalAnchor
        self.about = about
    }

    /// The headers a client describes itself with, each only in its expected shape.
    public static func describe(host: String, system: String, version: String) -> [String: String] {
        var result: [String: String] = [:]
        let name = host.components(separatedBy: ".").first ?? host
        if matches(name, #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z"#) { result["X-Client-Host"] = name }
        if matches(system, #"\AmacOS [0-9][0-9.]{0,30}\z"#) { result["X-Client-System"] = system }
        if matches(version, #"\A[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}\z"#) { result["X-Client-Version"] = version }
        return result
    }

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

    private func send(_ url: URL, method: String, headers: [String: String], limit: Int, timeout: TimeInterval, body: Data? = nil)
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
        if method == "POST" { request.httpBody = body ?? Data() }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
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
            headers: about.merging(["Authorization": "Bearer " + deviceToken]) { _, own in own }, limit: 1_048_576, timeout: 10)
        if answer.status == 401 { throw DeviceError.accessRejected }
        // Known to the router and not switched off, only without a service.
        if answer.status == 409 { throw DeviceError.noServices }
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
        // An older router does not say whether services stay blocked.
        let stated = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["block_without_tunnel"]
        // This answer describes; it grants nothing. A field a later router
        // adds is ignored, so an installed client keeps working with it.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(["version", "id", "revision", "selected", "available"]).isSubset(of: root.keys) else { throw DeviceError.invalidResponse }
        // A number is not an answer to a yes-or-no question.
        if let stated, CFGetTypeID(stated as CFTypeRef) != CFBooleanGetTypeID() { throw DeviceError.invalidResponse }
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
        var services = DeviceServices(selected: lists[0], available: lists[1], domains: domains)
        services.block = (stated as? Bool) ?? true
        if let mode = root["mode"] {
            guard let name = mode as? String, name == "services" || name == "full" else { throw DeviceError.invalidResponse }
            services.full = name == "full"
        }
        if let value = root["tunnel_subnet"] {
            guard let subnet = value as? String, ConnectionAddresses.validNetwork(subnet) else { throw DeviceError.invalidResponse }
            services.tunnelSubnet = subnet
        }
        if let value = root["entries"] { services.entries = try decodeEntries(value) }
        if let value = root["own"] { services.own = try decodeOwn(value) }
        return services
    }

    static func decodeOwn(_ value: Any) throws -> OwnAddresses {
        guard let item = value as? [String: Any], Set(item.keys) == ["limit", "ports", "domains", "networks"],
              let ports = item["ports"] as? [Any], (1...16).contains(ports.count),
              let domains = item["domains"] as? [String], let networks = item["networks"] as? [String],
              domains.count + networks.count <= 32 else { throw DeviceError.invalidResponse }
        let limit = try integer(item["limit"], 1...32)
        let numbers = try ports.map { try integer($0, 1...65535) }
        for name in domains { guard matches(name, #"\A[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?\z"#) else { throw DeviceError.invalidResponse } }
        for network in networks { guard (try? PolicyValue.network(network)) != nil else { throw DeviceError.invalidResponse } }
        return OwnAddresses(limit: limit, ports: numbers, domains: domains, networks: networks)
    }

    static func decodeEntries(_ value: Any) throws -> [ServiceEntry] {
        guard let items = value as? [[String: Any]], items.count <= 128 else { throw DeviceError.invalidResponse }
        var seen = Set<String>(), entries: [ServiceEntry] = []
        func flag(_ value: Any?) throws -> Bool {
            guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else { throw DeviceError.invalidResponse }
            return flag
        }
        for item in items {
            let keys: Set<String> = ["id", "required", "on", "closed", "choose_closed", "domains", "networks", "resources", "cidrs"]
            guard Set(item.keys).subtracting(["label", "health"]) == keys,
                  let id = item["id"] as? String, matches(id, service), seen.insert(id).inserted,
                  let resources = item["resources"] as? [String], resources.count <= 4096,
                  resources.allSatisfy({ matches($0, #"\Ahost-[0-9]{1,7}\z"#) }),
                  let cidrs = item["cidrs"] as? [String], cidrs.count <= 64 else { throw DeviceError.invalidResponse }
            for cidr in cidrs { guard (try? PolicyValue.network(cidr)) != nil else { throw DeviceError.invalidResponse } }
            let required = try flag(item["required"]), on = try flag(item["on"])
            guard !required || on else { throw DeviceError.invalidResponse }
            var entry = ServiceEntry(id: id, required: required, on: on, closed: try flag(item["closed"]),
                chooseClosed: try flag(item["choose_closed"]), domains: try integer(item["domains"], 0...65536),
                networks: try integer(item["networks"], 0...64), resources: resources, cidrs: cidrs)
            if let label = item["label"] {
                // Shown as text, never markup: one line of at most 64 characters.
                guard let text = label as? String, (1...64).contains(text.count),
                      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw DeviceError.invalidResponse }
                entry.label = text
            }
            if let value = item["health"] { entry.health = try decodeHealth(value) }
            entries.append(entry)
        }
        return entries
    }

    static func decodeHealth(_ value: Any) throws -> ServiceHealth {
        guard let item = value as? [String: Any], Set(item.keys).isSubset(of: ["state", "reason", "tunnel", "since"]),
              let name = item["state"] as? String, let state = ServiceHealth.State(rawValue: name) else { throw DeviceError.invalidResponse }
        var health = ServiceHealth(state: state)
        if let reason = item["reason"] {
            guard let text = reason as? String, matches(text, #"\A[a-z_]{1,32}\z"#) else { throw DeviceError.invalidResponse }
            health.reason = text
        }
        if let tunnel = item["tunnel"] { _ = try integer(tunnel, 0...4096) }
        if let since = item["since"] { health.since = try integer(since, 0...Int(Int32.max) * 2) }
        return health
    }

    public func choose(endpoint: URL, deviceToken: String, on: [String], closed: [String]) async throws {
        guard Self.matches(deviceToken, Self.token), on.count <= 128, closed.count <= 128,
              (on + closed).allSatisfy({ Self.matches($0, Self.service) }) else { throw DeviceError.invalidEndpoint }
        let body = try JSONSerialization.data(withJSONObject: ["on": on, "closed": closed], options: [.sortedKeys])
        let answer = try await send(try Self.endpoint(endpoint, path: "/client/v1/choices"), method: "POST",
            headers: ["Authorization": "Bearer " + deviceToken, "Content-Type": "application/json"], limit: 1024, timeout: 10, body: body)
        guard answer.status == 202 else { throw DeviceError.httpRejected }
    }

    public func setOwn(endpoint: URL, deviceToken: String, domains: [String], networks: [String]) async throws {
        guard Self.matches(deviceToken, Self.token), domains.count + networks.count <= 32,
              (domains + networks).allSatisfy({ $0.utf8.count <= 253 }) else { throw DeviceError.invalidEndpoint }
        let body = try JSONSerialization.data(withJSONObject: ["domains": domains, "networks": networks], options: [.sortedKeys])
        let answer = try await send(try Self.endpoint(endpoint, path: "/client/v1/own"), method: "POST",
            headers: ["Authorization": "Bearer " + deviceToken, "Content-Type": "application/json"], limit: 1024, timeout: 10, body: body)
        // What the router refused is said plainly: not allowed, not accepted, too often.
        switch answer.status {
        case 202: return
        case 400: throw Self.decodeOwnRefusal(answer.data) ?? DeviceError.ownRefused
        case 403: throw DeviceError.ownNotAllowed
        case 429: throw DeviceError.ownTooOften
        default: throw DeviceError.httpRejected
        }
    }

    /// 202 `{"version":1,"accepted":true,"next_after":30}`; 429 `check_too_often`
    /// with `retry_after`; 409 `check_busy`. The result comes in the next services answer.
    static func decodeCheck(status: Int, data: Data) throws -> Int {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch status {
        case 202:
            guard root?["accepted"] as? Bool == true else { throw DeviceError.invalidResponse }
            return try integer(root?["next_after"] ?? 30, 1...3600)
        case 429: throw CheckRefusal.tooOften((try? integer(root?["retry_after"], 1...3600)) ?? 30)
        case 409: throw CheckRefusal.busy
        case 401: throw DeviceError.accessRejected
        default: throw DeviceError.httpRejected
        }
    }

    public func checkNow(endpoint: URL, deviceToken: String) async throws -> Int {
        guard Self.matches(deviceToken, Self.token) else { throw DeviceError.invalidEndpoint }
        let answer = try await send(try Self.endpoint(endpoint, path: "/client/v1/check"), method: "POST",
            headers: ["Authorization": "Bearer " + deviceToken], limit: 1024, timeout: 10)
        return try Self.decodeCheck(status: answer.status, data: answer.data)
    }

    static func decodeOwnRefusal(_ data: Data) -> OwnRefusal? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] as? String == "invalid_own",
              let reason = root["reason"] as? String, matches(reason, #"\A[a-z_]{1,32}\z"#) else { return nil }
        let entry = (root["entry"] as? String).map { String($0.prefix(253)) } ?? ""
        return OwnRefusal(reason: reason, entry: entry)
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

    public static let reportLimit = 32768

    static func decodeReportWanted(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["version"] as? Int) == 1, let wanted = root["wanted"] as? Bool else { return false }
        return wanted
    }

    public func reportWanted(endpoint: URL, deviceToken: String) async -> Bool {
        guard Self.matches(deviceToken, Self.token), let url = try? Self.endpoint(endpoint, path: "/client/v1/report"),
              let answer = try? await send(url, method: "GET", headers: ["Authorization": "Bearer " + deviceToken], limit: 1024, timeout: 5),
              answer.status == 200 else { return false }
        return Self.decodeReportWanted(answer.data)
    }

    public func sendReport(endpoint: URL, deviceToken: String, report: Data) async -> Bool {
        guard Self.matches(deviceToken, Self.token), !report.isEmpty, report.count <= Self.reportLimit,
              let url = try? Self.endpoint(endpoint, path: "/client/v1/report"),
              let answer = try? await send(url, method: "POST", headers: ["Authorization": "Bearer " + deviceToken], limit: 1024, timeout: 10, body: report)
        else { return false }
        return answer.status == 200
    }

    /// The request for the services list names what this program understands.
    /// A router adds a field to its answer only for a client that listed it:
    /// Waypoint 2.2.8 refuses an answer with a field it does not know.
    static func servicesHeaders(deviceToken: String) -> [String: String] {
        ["Authorization": "Bearer " + deviceToken, "X-Waypoint-Features": "health"]
    }

    public func services(endpoint: URL, deviceToken: String, id: String) async throws -> DeviceServices {
        guard Self.matches(deviceToken, Self.token) else { throw DeviceError.invalidEndpoint }
        let answer = try await send(try Self.endpoint(endpoint, path: "/client/v1/services"), method: "GET",
            headers: Self.servicesHeaders(deviceToken: deviceToken), limit: 65536, timeout: 5)
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
