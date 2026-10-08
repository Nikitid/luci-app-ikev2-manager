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
    var resolving: [String] = [], resolver = ""
    func setNameResolution(domains: [String], resolver: String) throws { sync { resolving = domains; self.resolver = resolver; log.append("names") } }
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
    func release(endpoint: URL, deviceToken: String) async throws -> String { "2.3.0" }
    var reportWanted = false, reports: [Data] = []
    func reportWanted(endpoint: URL, deviceToken: String) async -> Bool { sync { reportWanted } }
    func sendReport(endpoint: URL, deviceToken: String, report: Data) async -> Bool { sync { reports.append(report); reportWanted = false }; return true }
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
    #expect(status.release == "2.3.0" && ClientStatusReport.newer("2.3.0", than: "2.2.9") && ClientStatusReport.newer("2.10.0", than: "2.9.9"))
    #expect(!ClientStatusReport.newer("2.3.0", than: "2.3.0") && !ClientStatusReport.newer("2.2.0", than: "2.3.0") && !ClientStatusReport.newer("", than: "1.0.0"))
    #expect(throws: DeviceError.invalidResponse) { try DeviceTransport.decodeRelease(Data(#"{"version":1,"release":"2.3.0","url":"https://example.com"}"#.utf8)) }
    #expect(try DeviceTransport.decodeRelease(Data(#"{"version":1,"release":"2.3.0"}"#.utf8)) == "2.3.0")
    #expect(machine.rules == "block drop out quick inet from any to 172.31.254.0/24\n")
    #expect(machine.hosts.contains("172.31.254.1 api.example.com"))
    #expect(machine.log.firstIndex(of: "filter")! < machine.log.firstIndex(of: "hosts")!)
    #expect(machine.log.firstIndex(of: "filter")! < machine.log.firstIndex(of: "names")!, "names are asked through the tunnel only once the filter holds the resolver")
    #expect(machine.resolving == ["api.example.com"] && machine.resolver == "172.31.254.127")
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
    #expect(await runtime.status().state == "connecting" && machine.started == 1, "switching access on asks the system to connect")
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
    #expect(machine.rules == "pass out quick on ipsec0 inet from any to 172.31.254.0/24 keep state\nblock drop out quick inet from any to 172.31.254.0/24\n")
    // A missed answer keeps permission briefly; a lasting one ends it.
    router.sync { router.ready = .failure(.pathUnavailable) }
    await runtime.tick(now: now)
    #expect(await runtime.status().protected)
    now += 7
    await runtime.tick(now: now)
    #expect(await runtime.status().protected, "one unanswered question within the lease changes nothing")
    now += 21
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().state == "tunnel_connected" && !machine.rules.contains("pass"))
    // An answer for another address or revision is a refusal, at once.
    router.sync { router.ready = .success(DeviceReadiness(id: "office-mac", address: "10.20.0.7", revision: 1)) }
    await runtime.tick(now: now); now += 7
    #expect(await runtime.status().protected)
    router.sync { router.ready = .success(DeviceReadiness(id: "office-mac", address: "10.20.0.8", revision: 1)) }
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().error == "path_differentPolicy" && !machine.rules.contains("pass"))
    // Switching access off is remembered, closes the filter and disconnects.
    router.sync { router.ready = .success(DeviceReadiness(id: "office-mac", address: "10.20.0.7", revision: 1)) }
    await runtime.tick(now: now); now += 2
    #expect(machine.rules.contains("pass"))
    try await runtime.setWanted(false)
    #expect(!machine.rules.contains("pass"), "switching off closes at once, before the next step")
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
    #expect(machine.resolving.isEmpty)
    #expect(!machine.installed && machine.log.contains { $0.hasPrefix("io.github.nikitid.ikev2-manager-client.") })
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
}

@Test func reportGoesOnlyWhenAskedAndSaysWhatFailed() async throws {
    var (runtime, _, router, _, now) = try await registered()
    now += 31
    await runtime.tick(now: now); now += 2
    #expect(router.reports.isEmpty, "nothing is sent unasked")
    // A device the router refuses is the one worth hearing from.
    router.sync { router.policyFailure = .accessRejected }
    now += 31
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().state == "access_closed")
    router.sync { router.reportWanted = true }
    now += 31
    await runtime.tick(now: now); now += 2
    #expect(router.reports.count == 1)
    let sent = try #require(try JSONSerialization.jsonObject(with: router.reports[0]) as? [String: Any])
    #expect(sent["platform"] as? String == "macos" && sent["state"] as? String == "access_closed" && sent["access_closed"] as? Bool == true)
    #expect((sent["faults"] as? [String])?.contains { $0.hasSuffix("access_closed synchronization") } == true)
    #expect(router.reports[0].count <= DeviceTransport.reportLimit && !String(decoding: router.reports[0], as: UTF8.self).contains(secret))
    now += 31
    await runtime.tick(now: now)
    #expect(router.reports.count == 1, "one request, one report")
}

@Test func resetTakesEverythingBackAndRegistersAgain() async throws {
    var (runtime, machine, router, store, now) = try await registered()
    try await runtime.setWanted(true)
    machine.sync { machine.connected = true; machine.tunnel = TunnelObservation(interface: "ipsec0", address: "10.20.0.7") }
    router.sync { router.ready = .success(DeviceReadiness(id: "office-mac", address: "10.20.0.7", revision: 1)) }
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().protected)
    try await runtime.reset(now: now)
    #expect(machine.rules.isEmpty && !machine.hosts.contains("api.example.com") && machine.resolving.isEmpty && !machine.installed && machine.stopped == 1)
    let after = await runtime.status()
    #expect(after.state == "enrollment_required" && !after.protected && !after.guardInstalled && after.services.isEmpty)
    #expect(try store.loadRegistration() == nil, "the device is forgotten")
    // The program stays and takes a new link.
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().state == "enrollment_required")
    router.sync { router.claimed = false; router.enrolled = false }
    try await runtime.begin(invitation: invitation)
    router.sync { router.enrolled = true }
    await runtime.tick(now: now); now += 4
    await runtime.tick(now: now); now += 2
    await runtime.tick(now: now)
    #expect(machine.rules.contains("block drop") && machine.hosts.contains("api.example.com"), "a new registration installs the denial again")
}

@Test func systemTextIsWhatTheSystemAccepts() throws {
    let policy = try ClientPolicy(data: Data(policyText.utf8))
    #expect(throws: (any Error).self) { try SystemPlan.packetFilter(subnet: "172.31.254.0/24", permit: "en0; pass all") }
    #expect(try SystemPlan.layout("172.31.254.0/24") == ("172.31.254.127", "172.31.254.128/25"))
    #expect(try SystemPlan.layout("172.31.240.0/20") == ("172.31.247.255", "172.31.248.0/21"))
    #expect(throws: (any Error).self) { try SystemPlan.layout("172.31.254.7/24") }
    #expect(throws: (any Error).self) { try SystemPlan.packetFilter(subnet: "0.0.0.0/0 pass", permit: nil) }
    let profile = try SystemPlan.vpnProfile(policy: policy, password: secret, identifier: UUID(), serviceIdentifier: UUID())
    let root = try #require(try PropertyListSerialization.propertyList(from: profile, format: nil) as? [String: Any])
    let payloads = try #require(root["PayloadContent"] as? [[String: Any]])
    let payload = try #require(payloads.first { $0["PayloadType"] as? String == "com.apple.vpn.managed" })
    // The profile carries the VPN and nothing else: no setting of any other program.
    #expect(payloads.count == 1)
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
    #expect(DeviceTransport.describe(host: "Alices-MacBook.local", system: "macOS 27.2.0", version: "2.3.0") ==
            ["X-Client-Host": "Alices-MacBook", "X-Client-System": "macOS 27.2.0", "X-Client-Version": "2.3.0"])
    #expect(DeviceTransport.describe(host: "<script>", system: "macOS 27; rm", version: "../1").isEmpty)
    let names = #"{"version":1,"id":"office-mac","revision":4,"selected":[{"id":"api","domains":3}],"available":[{"id":"wiki","domains":9}]}"#
    #expect(try DeviceTransport.decodeServices(Data(names.utf8), id: "office-mac") == DeviceServices(selected: ["api"], available: ["wiki"], domains: 3))
    // An older router says nothing about blocking, which means the rule; a
    // newer one may lift it, and a number is not an answer.
    let lifted = names.replacingOccurrences(of: #""version":1"#, with: #""version":1,"block_without_tunnel":false"#)
    let relaxed = try DeviceTransport.decodeServices(Data(lifted.utf8), id: "office-mac")
    #expect(lifted != names && !relaxed.block)
    #expect(throws: DeviceError.self) { try DeviceTransport.decodeServices(Data(lifted.replacingOccurrences(of: "false", with: "0").utf8), id: "office-mac") }
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
