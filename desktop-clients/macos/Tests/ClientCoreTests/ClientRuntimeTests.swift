import Foundation
import Testing
@testable import ClientCore

private let policyText = #"{"version":1,"id":"office-mac","revision":1,"server":{"address":"vpn.example.com","remote_id":"vpn.example.com"},"virtual_subnet":"172.31.254.0/24","exit":"1","resources":[{"id":"host-1","domain":"api.example.com","address":"172.31.254.1","transports":[{"protocol":"tcp","ports":[443]}]}]}"#
private let secret = String(repeating: "b", count: 64)

/// Records what the runtime did to the machine and plays the machine's part.
private final class Machine: SystemActions, @unchecked Sendable {
    let lock = NSLock()
    var hosts = "127.0.0.1 localhost\n", rules = "", installed = true, connected = false
    var started = 0, stopped = 0, tunnel: TunnelObservation?, fault: TunnelFault?
    var log: [String] = []
    func sync<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    func readHosts() throws -> String { sync { hosts } }
    func writeHosts(_ text: String) throws { sync { hosts = text; log.append("hosts") } }
    func loadPacketFilter(_ text: String) throws { sync { rules = text; log.append("filter") } }
    func packetFilterRules() throws -> String { sync { rules } }
    func vpnInstalled() -> Bool { sync { installed } }
    func vpnConnected() -> Bool { sync { connected } }
    func startVPN() throws { sync { started += 1 } }
    func stopVPN() throws { sync { stopped += 1; connected = false } }
    func removeVPNProfile(identifier: String) { sync { installed = false; log.append(identifier) } }
    func observeTunnel(addresses: [String]) throws -> TunnelObservation? {
        try sync { if let fault { throw fault }; return tunnel }
    }
}

private final class Router: DeviceRequests, @unchecked Sendable {
    let lock = NSLock()
    var claimed = false, enrolled = false, policy = Data(policyText.utf8)
    var ready: Result<DeviceReadiness, DeviceError> = .failure(.pathUnavailable)
    var policyFailure: DeviceError?
    func sync<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    func claim(endpoint: URL, invitation: String, deviceToken: String) async throws -> EnrollmentAnswer {
        sync { claimed = true }; return EnrollmentAnswer(id: "office-mac", policy: nil, password: nil)
    }
    func poll(endpoint: URL, deviceToken: String) async throws -> EnrollmentAnswer {
        try sync {
            guard claimed else { throw DeviceError.accessRejected }
            return EnrollmentAnswer(id: "office-mac", policy: enrolled ? policy : nil, password: enrolled ? secret : nil)
        }
    }
    func policy(endpoint: URL, deviceToken: String) async throws -> Data {
        try sync { if let policyFailure { throw policyFailure }; return policy }
    }
    func readiness(endpoint: URL, deviceToken: String, tunnelAddress: String) async throws -> DeviceReadiness {
        try sync { try ready.get() }
    }
    func services(endpoint: URL, deviceToken: String, id: String) async throws -> DeviceServices {
        DeviceServices(selected: ["api"], available: ["wiki"], domains: 1)
    }
}

private func fixture() throws -> (ClientRuntime, Machine, Router, ClientStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikev2-client-" + UUID().uuidString)
    let store = try ClientStore(directory: directory), machine = Machine(), router = Router()
    return (ClientRuntime(store: store, system: machine, transport: router), machine, router, store)
}

private let invitation = "https://vpn.example.com:8443/client/v1/enroll#" + String(repeating: "a", count: 64)

@Test func registrationInstallsDenialBeforeNames() async throws {
    let (runtime, machine, router, store) = try fixture()
    var now = Date(timeIntervalSince1970: 1_000)
    await runtime.tick(now: now)
    #expect(await runtime.status().state == "enrollment_required")
    #expect(throws: (any Error).self) { try DeviceTransport.parseInvitation("https://vpn.example.com/client/v1/enroll#short") }
    try await runtime.begin(invitation: invitation)
    await runtime.tick(now: now)
    #expect(await runtime.status().state == "registration_pending")
    let pending = try #require(try store.loadRegistration())
    #expect(pending.id == "office-mac" && pending.invitation != nil && !pending.complete)
    router.sync { router.enrolled = true }
    now += 4
    await runtime.tick(now: now)
    let done = try #require(try store.loadRegistration())
    #expect(done.complete && done.invitation == nil && done.deviceToken == pending.deviceToken)
    now += 2
    await runtime.tick(now: now)
    let status = await runtime.status()
    #expect(status.state == "blocked" && status.guardInstalled && !status.protected && status.services == ["api"] && status.available == ["wiki"])
    #expect(machine.rules == "block drop out quick inet from any to 172.31.254.0/24\n")
    #expect(machine.hosts.contains("172.31.254.1 api.example.com"))
    #expect(machine.log.firstIndex(of: "filter")! < machine.log.firstIndex(of: "hosts")!)
    #expect(throws: (any Error).self) { try DeviceTransport.parseInvitation("x") }
    await #expect(throws: (any Error).self) { try await runtime.begin(invitation: invitation) }
    try? FileManager.default.removeItem(at: store.directory)
}

private func registered() async throws -> (ClientRuntime, Machine, Router, ClientStore, Date) {
    let (runtime, machine, router, store) = try fixture()
    var now = Date(timeIntervalSince1970: 2_000)
    try await runtime.begin(invitation: invitation)
    router.sync { router.enrolled = true }
    await runtime.tick(now: now); now += 4
    await runtime.tick(now: now); now += 2
    await runtime.tick(now: now); now += 2
    return (runtime, machine, router, store, now)
}

@Test func permissionFollowsRouterReadiness() async throws {
    var (runtime, machine, router, store, now) = try await registered()
    machine.sync { machine.installed = false }
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().state == "profile_required")
    machine.sync { machine.installed = true }
    try await runtime.setWanted(true)
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().state == "connecting" && machine.started == 1)
    machine.sync { machine.connected = true }
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().state == "connecting", "a connected service without confirmed routes is not a tunnel yet")
    let tunnel = TunnelObservation(interface: "ipsec0", address: "10.20.0.7")
    machine.sync { machine.tunnel = tunnel }
    await runtime.tick(now: now); now += 2
    var status = await runtime.status()
    #expect(status.state == "tunnel_connected" && status.error == "path_pathUnavailable" && !status.protected && status.routed)
    #expect(!machine.rules.contains("pass"))
    router.sync { router.ready = .success(DeviceReadiness(id: "office-mac", address: "10.20.0.7", revision: 1)) }
    await runtime.tick(now: now); now += 2
    status = await runtime.status()
    #expect(status.state == "protected" && status.protected && status.error == "none")
    #expect(machine.rules == "pass out quick on ipsec0 inet from any to { 172.31.254.1 } keep state\nblock drop out quick inet from any to 172.31.254.0/24\n")
    // A missed answer keeps permission briefly; a lasting one ends it.
    router.sync { router.ready = .failure(.pathUnavailable) }
    await runtime.tick(now: now)
    #expect(await runtime.status().protected)
    now += 11
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().state == "tunnel_connected" && !machine.rules.contains("pass"))
    // An answer for another address or revision is a refusal, at once.
    router.sync { router.ready = .success(DeviceReadiness(id: "office-mac", address: "10.20.0.7", revision: 1)) }
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().protected)
    router.sync { router.ready = .success(DeviceReadiness(id: "office-mac", address: "10.20.0.8", revision: 1)) }
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().error == "path_differentPolicy" && !machine.rules.contains("pass"))
    // Disconnecting is remembered and closes the service.
    router.sync { router.ready = .success(DeviceReadiness(id: "office-mac", address: "10.20.0.7", revision: 1)) }
    await runtime.tick(now: now); now += 2
    try await runtime.setWanted(false)
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().state == "blocked" && machine.stopped == 1 && !machine.rules.contains("pass"))
    #expect(try store.loadIntent() == false)
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func tunnelThatTakesEverythingIsRefused() async throws {
    var (runtime, machine, _, store, now) = try await registered()
    try await runtime.setWanted(true)
    machine.sync { machine.connected = true; machine.fault = .takesEverything }
    await runtime.tick(now: now); now += 2
    let status = await runtime.status()
    #expect(status.state == "connection_error" && status.error == "tunnel_takes_everything" && machine.stopped == 1)
    #expect(!machine.rules.contains("pass"))
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func revocationClosesAndRemovalCleans() async throws {
    var (runtime, machine, router, store, now) = try await registered()
    try await runtime.setWanted(true)
    machine.sync { machine.connected = true; machine.tunnel = TunnelObservation(interface: "ipsec0", address: "10.20.0.7") }
    router.sync { router.ready = .success(DeviceReadiness(id: "office-mac", address: "10.20.0.7", revision: 1)) }
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().protected)
    // An unanswered policy poll changes nothing; a refused one closes.
    router.sync { router.policyFailure = .connectionFailed }
    now += 31
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().protected)
    router.sync { router.policyFailure = .accessRejected }
    now += 31
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().state == "access_closed" && machine.stopped == 1 && !machine.rules.contains("pass"))
    #expect(machine.rules.contains("block drop"), "revocation keeps the denial")
    #expect(machine.hosts.contains("api.example.com"), "revocation keeps the names on their virtual addresses")
    try await runtime.remove()
    #expect(machine.rules.isEmpty && !machine.hosts.contains("api.example.com") && machine.hosts.contains("localhost"))
    #expect(!machine.installed && machine.log.contains { $0.hasPrefix("io.github.nikitid.ikev2-manager-client.") })
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
}

@Test func systemTextIsWhatTheSystemAccepts() throws {
    let policy = try ClientPolicy(data: Data(policyText.utf8))
    #expect(throws: (any Error).self) { try SystemPlan.packetFilter(subnet: "172.31.254.0/24", permit: ("en0; pass all", ["172.31.254.1"])) }
    #expect(throws: (any Error).self) { try SystemPlan.packetFilter(subnet: "172.31.254.0/24", permit: ("ipsec0", ["any"])) }
    #expect(throws: (any Error).self) { try SystemPlan.packetFilter(subnet: "0.0.0.0/0 pass", permit: nil) }
    let profile = try SystemPlan.vpnProfile(policy: policy, password: secret, identifier: UUID(), serviceIdentifier: UUID())
    let root = try #require(try PropertyListSerialization.propertyList(from: profile, format: nil) as? [String: Any])
    let payload = try #require((root["PayloadContent"] as? [[String: Any]])?.first)
    let settings = try #require(payload["IKEv2"] as? [String: Any])
    #expect(payload["VPNType"] as? String == "IKEv2" && payload["UserDefinedName"] as? String == SystemPlan.serviceName)
    #expect(settings["RemoteAddress"] as? String == "vpn.example.com" && settings["AuthName"] as? String == "office-mac")
    #expect(settings["LocalIdentifier"] as? String == "office-mac@managed.ikev2-manager", "the server narrows by this name")
    #expect(settings["AuthPassword"] as? String == secret && settings["ExtendedAuthEnabled"] as? Int == 1)
    #expect(throws: (any Error).self) { try SystemPlan.vpnProfile(policy: policy, password: "short", identifier: UUID(), serviceIdentifier: UUID()) }
}

@Test func routerAnswersAreReadStrictly() throws {
    let ready = #"{"version":1,"state":"ready","id":"office-mac","revision":4,"policy_sha256":""# + String(repeating: "a", count: 64) + #"","address":"10.20.0.7","generation":3,"expires_at":1790000000}"#
    #expect(try DeviceTransport.decodeReadiness(Data(ready.utf8)) == DeviceReadiness(id: "office-mac", address: "10.20.0.7", revision: 4))
    for broken in [ready.replacingOccurrences(of: #""ready""#, with: #""pending""#), ready.replacingOccurrences(of: "10.20.0.7", with: "10.20.0.256"),
                   ready.replacingOccurrences(of: #""revision":4"#, with: #""revision":0"#), ready.replacingOccurrences(of: "}", with: #","extra":1}"#), "[]"] {
        #expect(throws: DeviceError.invalidResponse) { try DeviceTransport.decodeReadiness(Data(broken.utf8)) }
    }
    let names = #"{"version":1,"id":"office-mac","revision":4,"selected":[{"id":"api","domains":3}],"available":[{"id":"wiki","domains":9}]}"#
    #expect(try DeviceTransport.decodeServices(Data(names.utf8), id: "office-mac") == DeviceServices(selected: ["api"], available: ["wiki"], domains: 3))
    #expect(throws: DeviceError.invalidResponse) { try DeviceTransport.decodeServices(Data(names.utf8), id: "other") }
    #expect(throws: DeviceError.invalidResponse) { try DeviceTransport.decodeServices(Data(names.replacingOccurrences(of: "wiki", with: "../wiki").utf8), id: "office-mac") }
    let enrolled = #"{"version":1,"state":"enrolled","policy":"# + policyText + #","credentials":{"username":"office-mac","password":""# + secret + #""}}"#
    #expect(try DeviceTransport.decodeEnrollment(status: 200, data: Data(enrolled.utf8)).password == secret)
    #expect(throws: DeviceError.invalidResponse) {
        try DeviceTransport.decodeEnrollment(status: 200, data: Data(enrolled.replacingOccurrences(of: #""username":"office-mac""#, with: #""username":"other""#).utf8))
    }
    #expect(throws: DeviceError.invalidResponse) {
        try DeviceTransport.decodeEnrollment(status: 202, data: Data(enrolled.utf8))
    }
}

@Test func storeRefusesWhatOthersCouldTouch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikev2-store-" + UUID().uuidString)
    let store = try ClientStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try store.loadRegistration() == nil && store.loadIntent() == false)
    try store.saveIntent(true)
    #expect(try store.loadIntent())
    #expect(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("connection.json").path)[.posixPermissions] as? Int == 0o600)
    chmod(directory.appendingPathComponent("connection.json").path, 0o644)
    #expect(throws: (any Error).self) { try store.loadIntent() }
    chmod(directory.appendingPathComponent("connection.json").path, 0o600)
    chmod(directory.path, 0o755)
    #expect(throws: (any Error).self) { try store.loadIntent() }
}
