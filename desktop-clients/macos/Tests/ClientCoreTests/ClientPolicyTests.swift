import Foundation
import Testing
@testable import ClientCore

private func policy(_ revision: Int, _ resources: [(String, String)]) throws -> ClientPolicy {
    try ClientPolicy(data: JSONSerialization.data(withJSONObject: [
        "version": 1, "id": "team", "revision": revision,
        "server": ["address": "vpn.example.com", "remote_id": "vpn.example.com"],
        "virtual_subnet": "172.31.254.0/24", "exit": "1",
        "resources": resources.map { name, address in
            ["id": name, "domain": "\(name).example.com", "address": address,
             "transports": [["protocol": "tcp", "ports": [443]]]] as [String: Any]
        }
    ]))
}

@Test func sharedPolicyFixtures() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("fixtures/policies.json"))
    let fixtures = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    for fixture in fixtures {
        let name = try #require(fixture["name"] as? String)
        let valid = try #require(fixture["valid"] as? Bool)
        let value = try #require(fixture["policy"])
        let serialized = try JSONSerialization.data(withJSONObject: value)
        do {
            _ = try ClientPolicy(data: serialized)
            #expect(valid, "\(name): should refuse")
        } catch {
            #expect(!valid, "\(name): unexpected error \(error)")
        }
    }
}

@Test func sharedHistoryFixtures() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("fixtures/policy-histories.json"))
    let fixtures = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    for fixture in fixtures {
        let name = try #require(fixture["name"] as? String)
        let valid = try #require(fixture["valid"] as? Bool)
        let value = try #require(fixture["history"])
        let serialized = try JSONSerialization.data(withJSONObject: value)
        do {
            _ = try PolicyHistory(restoring: serialized)
            #expect(valid, "\(name): should refuse")
        } catch {
            #expect(!valid, "\(name): unexpected error \(error)")
        }
    }
}

@Test func revisionsAndReservedAddresses() throws {
    let first = try policy(1, [("api", "172.31.254.1")])
    let original = PolicyHistory(policy: first)
    let second = try original.proposing(policy(2, [("api", "172.31.254.1"), ("chat", "172.31.254.2")]))
    #expect(original.current == first)
    #expect(original.protectedAddresses.count == 1)
    #expect(second.protectedAddresses.count == 2)
    #expect(try original.proposing(first).current == first)
    let reordered = try policy(2, [("chat", "172.31.254.2"), ("api", "172.31.254.1")])
    #expect(try second.proposing(reordered).current == second.current)
    let retired = try second.proposing(policy(3, [("chat", "172.31.254.2")]))
    #expect(retired.protectedAddresses.contains("172.31.254.1"))
    let hosts = try second.reconcileHosts("127.0.0.1 localhost\r\n")
    #expect(try retired.reconcileHosts(hosts) == hosts)
    #expect(hosts.contains("172.31.254.1 api.example.com\r\n"))
    #expect(throws: HostsError.self) { try retired.reconcileHosts("192.0.2.1 api.example.com\n") }
    let recovered = try PolicyHistory(restoring: retired.export())
    #expect(recovered.current == retired.current)
    #expect(try recovered.reconcileHosts(hosts) == hosts)
    #expect(recovered.protectedAddresses == retired.protectedAddresses)
    #expect(throws: PolicyError.self) { try recovered.proposing(first) }
    #expect(throws: PolicyError.self) { try recovered.proposing(policy(4, [("other", "172.31.254.1")])) }
    #expect(throws: PolicyError.self) { try retired.proposing(first) }
    #expect(throws: PolicyError.self) { try original.proposing(policy(1, [("chat", "172.31.254.2")])) }
    #expect(throws: PolicyError.self) { try retired.proposing(policy(4, [("other", "172.31.254.1")])) }
    #expect(throws: PolicyError.self) { try retired.proposing(policy(4, [("api", "172.31.254.3")])) }
    #expect(throws: PolicyError.self) { try ClientPolicy(data: Data(repeating: 32, count: 1_048_577)) }
}
