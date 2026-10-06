import Foundation
import CoreFoundation

public enum PolicyError: Error {
    case invalidPolicy, changedIdentity, revisionConflict, changedAllocation, historyFull
}

public struct PolicyTransport: Sendable, Equatable {
    public let protocolName: String
    public let ports: [Int]
}

public struct PolicyResource: Sendable, Equatable {
    public let id: String
    public let domain: String
    public let address: String
    public let transports: [PolicyTransport]
}

/// Parsing validates content, not origin. Authenticate the enrolled source
/// before accepting a policy or persisting its proposed history.
public struct ClientPolicy: Sendable, Equatable {
    public let id: String
    public let revision: Int
    public let serverAddress: String
    public let remoteID: String
    public let virtualSubnet: String
    public let exit: String
    public let resources: [PolicyResource]

    fileprivate var document: [String: Any] {
        ["version": 1, "id": id, "revision": revision,
         "server": ["address": serverAddress, "remote_id": remoteID],
         "virtual_subnet": virtualSubnet, "exit": exit,
         "resources": resources.map { resource in
             ["id": resource.id, "domain": resource.domain, "address": resource.address,
              "transports": resource.transports.map { ["protocol": $0.protocolName, "ports": $0.ports] as [String: Any] }]
         }]
    }

    public init(data: Data) throws {
        guard data.count <= 1_048_576 else { throw PolicyError.invalidPolicy }
        let root = try PolicyValue.object(JSONSerialization.jsonObject(with: data),
            keys: ["version", "id", "revision", "server", "virtual_subnet", "exit", "resources"])
        _ = try PolicyValue.integer(root["version"], range: 1...1)
        id = try PolicyValue.identifier(root["id"])
        revision = try PolicyValue.integer(root["revision"], range: 1...2_147_483_647)
        let server = try PolicyValue.object(root["server"], keys: ["address", "remote_id"])
        serverAddress = try PolicyValue.domain(server["address"])
        remoteID = try PolicyValue.domain(server["remote_id"])
        exit = try PolicyValue.text(root["exit"])
        guard PolicyValue.matches(exit, #"\A[1-7]s?\z"#) else { throw PolicyError.invalidPolicy }
        virtualSubnet = try PolicyValue.text(root["virtual_subnet"])
        let subnet = virtualSubnet.components(separatedBy: "/")
        guard subnet.count == 2, PolicyValue.matches(subnet[1], #"\A(?:1[6-9]|2[0-8])\z"#),
              let prefix = Int(subnet[1]) else { throw PolicyError.invalidPolicy }
        let first = try PolicyValue.address(subnet[0])
        let size = UInt32(1) << (32 - prefix)
        guard first >> 24 == 10 || first >> 20 == 0xAC1 || first >> 16 == 0xC0A8,
              first % size == 0 else { throw PolicyError.invalidPolicy }
        var ids = Set<String>(), domains = Set<String>(), addresses = Set<String>()
        var parsed: [PolicyResource] = []
        for item in try PolicyValue.array(root["resources"], count: 1...4096) {
            let resource = try PolicyValue.object(item, keys: ["id", "domain", "address", "transports"])
            let resourceID = try PolicyValue.identifier(resource["id"])
            let domain = try PolicyValue.domain(resource["domain"])
            let address = try PolicyValue.text(resource["address"])
            let number = try PolicyValue.address(address)
            guard number > first, number < first + size - 1,
                  ids.insert(resourceID).inserted, domains.insert(domain).inserted,
                  addresses.insert(address).inserted, domain != serverAddress, domain != remoteID
            else { throw PolicyError.invalidPolicy }
            var protocols = Set<String>()
            var transports: [PolicyTransport] = []
            for entry in try PolicyValue.array(resource["transports"], count: 1...2) {
                let transport = try PolicyValue.object(entry, keys: ["protocol", "ports"])
                let name = try PolicyValue.text(transport["protocol"])
                guard name == "tcp" || name == "udp", protocols.insert(name).inserted
                else { throw PolicyError.invalidPolicy }
                var ports = Set<Int>()
                for value in try PolicyValue.array(transport["ports"], count: 1...64) {
                    guard ports.insert(try PolicyValue.integer(value, range: 1...65535)).inserted
                    else { throw PolicyError.invalidPolicy }
                }
                transports.append(PolicyTransport(protocolName: name, ports: ports.sorted()))
            }
            parsed.append(PolicyResource(id: resourceID, domain: domain, address: address,
                transports: transports.sorted { $0.protocolName < $1.protocolName }))
        }
        resources = parsed.sorted { $0.domain < $1.domain }
    }
}

/// A proposed value does not advance committed state. The privileged caller
/// must persist history together with the activation transaction.
public struct PolicyHistory: Sendable {
    public let current: ClientPolicy
    private let allocations: [String: String]

    public init(policy: ClientPolicy) {
        current = policy
        allocations = Dictionary(uniqueKeysWithValues: policy.resources.map { ($0.domain, $0.address) })
    }

    private init(current: ClientPolicy, allocations: [String: String]) {
        self.current = current
        self.allocations = allocations
    }

    public func proposing(_ next: ClientPolicy) throws -> PolicyHistory {
        guard next.id == current.id, next.serverAddress == current.serverAddress,
              next.remoteID == current.remoteID, next.virtualSubnet == current.virtualSubnet
        else { throw PolicyError.changedIdentity }
        guard next.revision >= current.revision,
              next.revision != current.revision || next == current else { throw PolicyError.revisionConflict }
        var history = allocations
        var reverse = Dictionary(uniqueKeysWithValues: history.map { ($0.value, $0.key) })
        for resource in next.resources {
            if let previous = history[resource.domain], previous != resource.address { throw PolicyError.changedAllocation }
            if let owner = reverse[resource.address], owner != resource.domain { throw PolicyError.changedAllocation }
            history[resource.domain] = resource.address
            reverse[resource.address] = resource.domain
        }
        guard history.count <= 4096 else { throw PolicyError.historyFull }
        return PolicyHistory(current: next, allocations: history)
    }

    public func export() throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "current": current.document,
            "allocations": allocations.sorted { $0.key < $1.key }.map { ["domain": $0.key, "address": $0.value] }],
            options: [.sortedKeys])
        guard data.count <= 2_097_152 else { throw PolicyError.historyFull }
        return data
    }

    public init(restoring data: Data) throws {
        guard data.count <= 2_097_152 else { throw PolicyError.invalidPolicy }
        let root = try PolicyValue.object(JSONSerialization.jsonObject(with: data), keys: ["version", "current", "allocations"])
        _ = try PolicyValue.integer(root["version"], range: 1...1)
        let document = try PolicyValue.object(root["current"],
            keys: ["version", "id", "revision", "server", "virtual_subnet", "exit", "resources"])
        current = try ClientPolicy(data: JSONSerialization.data(withJSONObject: document))
        let subnet = current.virtualSubnet.components(separatedBy: "/")
        // ClientPolicy has already checked the subnet syntax and range.
        guard let prefix = Int(subnet[1]) else { throw PolicyError.invalidPolicy }
        let first = try PolicyValue.address(subnet[0]), size = UInt32(1) << (32 - prefix)
        var history: [String: String] = [:]
        var addresses = Set<String>()
        for value in try PolicyValue.array(root["allocations"], count: 1...4096) {
            let entry = try PolicyValue.object(value, keys: ["domain", "address"])
            let domain = try PolicyValue.domain(entry["domain"]), address = try PolicyValue.text(entry["address"])
            let number = try PolicyValue.address(address)
            guard number > first, number < first + size - 1,
                  domain != current.serverAddress, domain != current.remoteID,
                  history[domain] == nil, addresses.insert(address).inserted
            else { throw PolicyError.changedAllocation }
            history[domain] = address
        }
        guard current.resources.allSatisfy({ history[$0.domain] == $0.address }) else { throw PolicyError.changedAllocation }
        allocations = history
    }

    public func reconcileHosts(_ original: String) throws -> String {
        // Retain revoked mappings so public DNS cannot become a fallback.
        let entries = allocations.sorted { $0.key < $1.key }
            .map { HostEntry(address: $0.value, domain: $0.key) }
        return try ManagedHosts.reconcile(original, entries: entries)
    }

    public var protectedAddresses: [String] { allocations.values.sorted() }
}

private enum PolicyValue {
    static func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == keys else { throw PolicyError.invalidPolicy }
        return object
    }
    static func text(_ value: Any?) throws -> String {
        guard let text = value as? String else { throw PolicyError.invalidPolicy }
        return text
    }
    static func array(_ value: Any?, count: ClosedRange<Int>) throws -> [Any] {
        guard let array = value as? [Any], count.contains(array.count) else { throw PolicyError.invalidPolicy }
        return array
    }
    static func integer(_ value: Any?, range: ClosedRange<Int>) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)), range.contains(number.intValue)
        else { throw PolicyError.invalidPolicy }
        return number.intValue
    }
    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    static func identifier(_ value: Any?) throws -> String {
        let result = try text(value)
        guard matches(result, #"\A[a-z][a-z0-9-]{0,47}\z"#) else { throw PolicyError.invalidPolicy }
        return result
    }
    static func domain(_ value: Any?) throws -> String {
        let result = try text(value)
        guard result.utf8.count <= 253, result.contains("."), !matches(result, #"\A[0-9.]+\z"#),
              result.components(separatedBy: ".").allSatisfy({ matches($0, #"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z"#) })
        else { throw PolicyError.invalidPolicy }
        return result
    }
    static func address(_ value: String) throws -> UInt32 {
        let parts = value.components(separatedBy: ".")
        guard parts.count == 4 else { throw PolicyError.invalidPolicy }
        var result: UInt32 = 0
        for part in parts {
            guard matches(part, #"\A(?:0|[1-9][0-9]{0,2})\z"#), let number = UInt8(part)
            else { throw PolicyError.invalidPolicy }
            result = result << 8 | UInt32(number)
        }
        return result
    }
}
