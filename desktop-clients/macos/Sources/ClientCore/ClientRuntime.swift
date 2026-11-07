import Foundation
import Security

public struct TunnelObservation: Sendable, Equatable {
    public let interface: String
    public let address: String
    /// Whether the default route goes through this tunnel.
    public var everything = false
    public init(interface: String, address: String) { self.interface = interface; self.address = address }
}

public enum TunnelFault: String, Error, Sendable {
    /// The tunnel carries the default route: the server offered everything.
    case takesEverything = "tunnel_takes_everything"
    case unavailable = "tunnel_unavailable"
}

/// Everything the runtime does to the machine. The daemon supplies the real
/// one; tests supply a recording one, so each decision is checked without root.
public protocol SystemActions: Sendable {
    func readHosts() throws -> String
    func writeHosts(_ text: String) throws
    /// Makes these domains, and every name under them, ask `resolver`; any
    /// other domain this client set up before stops doing so. Idempotent.
    func setNameResolution(domains: [String], resolver: String) throws
    /// Replaces the rules of the client's packet-filter anchor and enables the filter.
    func loadPacketFilter(_ rules: String) throws
    /// The rules the system currently holds in the anchor, as it prints them.
    func packetFilterRules() throws -> String
    /// Whether the packet filter applies the anchor at all: it is enabled and
    /// the main ruleset still reaches the anchor. Another program may switch
    /// the filter off or load a main ruleset of its own.
    func packetFilterEffective() throws -> Bool
    func vpnInstalled() -> Bool
    func vpnConnected() -> Bool
    func startVPN() throws
    func stopVPN() throws
    /// The tunnel interface and its address once every address is routed
    /// through it and nothing else is; nil while the system is still settling.
    func observeTunnel(addresses: [String]) throws -> TunnelObservation?
    /// Uninstallation: takes the VPN profile this client asked the owner to install.
    func removeVPNProfile(identifier: String)
    /// The network as the system shows it, for the report the administrator
    /// asks for: interfaces that are up, the default route, the resolvers.
    func describeNetwork() -> [String]
    /// Informational server address, resolved outside the readiness path.
    func serverIPv4(_ name: String) async -> String
    /// What on this machine lets a service be reached around the tunnel or
    /// keeps it from opening: "vpn" when another tunnel carries the route to
    /// the Internet, "proxy" when a system proxy is set. Named, not acted on.
    func observeConditions() -> [String]
    /// Switches the filter on again with this client's own reference and
    /// loads the anchor's rules: another program switched it off.
    func restorePacketFilter(_ rules: String) throws
    /// Configuration profiles installed on the machine; nil while unknown.
    func installedProfiles() -> Set<String>?
    /// The domains the system currently asks the tunnel's resolver for on this client's behalf.
    func heldNames() -> [String]
    /// Whether the Mac has a route to the Internet at all.
    func online() -> Bool
}

public extension SystemActions {
    func packetFilterEffective() throws -> Bool { true }
    func describeNetwork() -> [String] { [] }
    func serverIPv4(_ name: String) async -> String { "" }
    func observeConditions() -> [String] { [] }
    func restorePacketFilter(_ rules: String) throws { try loadPacketFilter(rules) }
    func installedProfiles() -> Set<String>? { nil }
    func heldNames() -> [String] { [] }
    func online() -> Bool { true }
}

/// The packet filter does not act and switching it on again did not help.
struct GuardFault: Error {
    let failures: Int
    var code: String { failures >= 5 ? "guard_unconfirmed" : "guard_restoring" }
}

public enum RuntimeError: Error, Equatable {
    /// A reset has steps left: a new registration waits until it is done.
    case resetIncomplete
}

public struct ClientStatusReport: Codable, Sendable, Equatable {
    public var version = 1
    public var state: String
    public var guardInstalled: Bool
    public var protected: Bool
    public var routed: Bool
    public var wanted: Bool
    public var profileInstalled: Bool
    public var error: String
    public var services: [String]
    public var available: [String]
    public var domains: Int
    public var revision: Int
    /// The router's release, or empty while unknown.
    public var release: String
    /// Whether services stay blocked while the tunnel is down.
    public var blockWithoutTunnel = true
    /// Whether everything goes into the tunnel.
    public var fullTunnel = false
    /// Conditions on this machine the user should know of: "vpn", "proxy".
    public var warnings: [String]? = nil
    /// What the person was offered and this device has of it, where the
    /// router gives an offer; the window shows and changes it.
    public var entries: [ServiceEntry]? = nil
    public var own: OwnAddresses? = nil
    public var addresses: ConnectionAddresses? = nil
    /// The last reset, while it has steps left or until the next registration.
    public var reset: ResetReport? = nil
    /// The one state the window and the menu show (`StatusView.visible`) and
    /// when the next attempt is, seconds since 1970, where one is due.
    public var visible: String? = nil
    public var next: Int? = nil
    public var updatedAt: Int

    /// Whether `release` is newer than the running program's own version.
    public static func newer(_ release: String, than own: String) -> Bool {
        let offered = release.split(separator: ".").compactMap { Int($0) }, running = own.split(separator: ".").compactMap { Int($0) }
        guard offered.count == 3, running.count == 3 else { return false }
        return offered.lexicographicallyPrecedes(running) == false && offered != running
    }
}

/// The device's state machine. One instance, one caller at a time.
public actor ClientRuntime {
    private let store: ClientStore
    private let system: any SystemActions
    private let transport: any DeviceRequests
    private var report: ClientStatusReport
    private var guardInstalled = false
    private var permitted: TunnelObservation?
    private var readyUntil = Date.distantPast
    private var nextReadinessAt = Date.distantPast
    private var noServices = false
    private var serverIP = ""
    private var addressLookup: Task<Void, Never>?
    private var nextPolicyPoll = Date.distantPast
    private var nextEnrollmentStep = Date.distantPast
    private var retryConnectionAt = Date.distantPast
    private var synchronizationFailed = false
    private var accessClosed = false
    private var release = ""
    private var names: DeviceServices?
    private var connectionError = "none"
    private var nextReportPoll = Date.distantPast
    private var conditions: [String] = []
    private var faults: [String] = []
    private var lastFault = ""
    private let startedAt = Date()
    private let about: [String: String]
    /// The last policy history that was read, to close with while it cannot be read.
    private var lastHistory: PolicyHistory?
    private var guardFailures = 0
    private var asleep = false
    private var lastReset: ResetReport?
    private var phase = "guard"
    private var recordedAt: [String: Date] = [:]
    private var connectingSince: Date?
    private var mismatchSince: Date?

    /// A failure of the daemon itself, kept for the program to report. The
    /// same code in the same phase is kept once in ten minutes.
    private func recordFailure(_ code: String, phase: String, now: Date) {
        let key = code + " " + phase
        if let last = recordedAt[key], now.timeIntervalSince(last) < 600 { return }
        recordedAt[key] = now
        try? store.appendFault(FaultEvent(code: code, phase: phase, at: Int(now.timeIntervalSince1970)))
    }

    /// What went wrong and when: each change of a failing state, the last forty.
    private func remember(_ state: String, now: Date) {
        let failing = ["error", "connection_error", "access_closed", "registration_error"].contains(state) ||
            (connectionError != "none" && state != "protected")
        let fault = state + " " + connectionError
        guard failing else { lastFault = ""; return }
        guard fault != lastFault else { return }
        lastFault = fault
        faults.append(ISO8601DateFormatter().string(from: now) + " " + fault)
        if faults.count > 40 { faults.removeFirst(faults.count - 40) }
    }

    /// The administrator asked this computer what is going on. It answers by
    /// itself: the state this service holds, what failed, and the network as
    /// the system shows it. No sites, programs or files, nothing the user did.
    func buildReport(now: Date) -> Data {
        var body: [String: Any] = [
            "version": 1, "platform": "macos", "client": about["X-Client-Version"] ?? "", "system": about["X-Client-System"] ?? "",
            "host": about["X-Client-Host"] ?? "", "created_at": ISO8601DateFormatter().string(from: now),
            "service_uptime_seconds": Int(now.timeIntervalSince(startedAt)), "system_uptime_seconds": Int(ProcessInfo.processInfo.systemUptime),
            "state": report.state, "connection_error": report.error, "connection_wanted": report.wanted,
            "guard_installed": report.guardInstalled, "tunnel_permitted": permitted != nil,
            "profile_installed": report.profileInstalled, "vpn_connected": system.vpnConnected(),
            "synchronization_failed": synchronizationFailed, "access_closed": accessClosed, "no_services": noServices,
            "mode": report.fullTunnel ? "full" : "services", "block_without_tunnel": report.blockWithoutTunnel,
            "services": report.services, "domains": report.domains, "policy_revision": report.revision, "router_release": release,
            "faults": faults, "warnings": conditions, "network": Array(system.describeNetwork().prefix(60)),
        ]
        if let tunnel = permitted { body["tunnel"] = tunnel.interface + " " + tunnel.address }
        var data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        if data.count > DeviceTransport.reportLimit {
            body["network"] = [String]()
            data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        }
        return data
    }

    private func answerReportRequest(_ registration: Registration, now: Date) async {
        nextReportPoll = now.addingTimeInterval(30)
        guard await transport.reportWanted(endpoint: registration.endpoint, deviceToken: registration.deviceToken) else { return }
        _ = await transport.sendReport(endpoint: registration.endpoint, deviceToken: registration.deviceToken, report: buildReport(now: now))
    }

    public init(store: ClientStore, system: any SystemActions, transport: any DeviceRequests = DeviceTransport(), about: [String: String] = [:]) {
        self.about = about
        self.store = store
        self.system = system
        self.transport = transport
        report = ClientStatusReport(state: "starting", guardInstalled: false, protected: false, routed: false, wanted: false,
                                    profileInstalled: false, error: "none", services: [], available: [], domains: 0,
                                    revision: 0, release: "", updatedAt: 0)
    }

    public func status() -> ClientStatusReport { report }

    private func publish(_ state: String, now: Date) {
        remember(state, now: now)
        if state != "connecting" && state != "connection_error" { connectingSince = nil }
        let history = try? store.loadHistory()
        report = ClientStatusReport(
            state: state, guardInstalled: guardInstalled, protected: state == "protected" && permitted != nil && guardInstalled,
            routed: state == "tunnel_connected" || state == "protected", wanted: (try? store.loadIntent()) ?? false,
            profileInstalled: system.vpnInstalled(), error: connectionError,
            services: Array((names?.selected ?? []).prefix(64)), available: Array((names?.available ?? []).prefix(64)),
            domains: Set(history?.current.resources.map(\.domain) ?? []).count,
            revision: history?.current.revision ?? 0, release: release, blockWithoutTunnel: names?.block ?? true, fullTunnel: names?.full ?? false,
            warnings: conditions, entries: names?.entries.map { StatusView.paths($0, protected: state == "protected" && permitted != nil) }, own: names?.own,
            addresses: history.map { ConnectionAddresses(server: $0.current.serverAddress, serverIP: serverIP,
                services: $0.current.virtualSubnet, tunnel: names?.tunnelSubnet ?? "") }, reset: lastReset,
            visible: StatusView.visible(state: state, error: connectionError),
            next: retryConnectionAt > now && retryConnectionAt != .distantFuture ? Int(retryConnectionAt.timeIntervalSince1970) : nil,
            updatedAt: Int(now.timeIntervalSince1970))
    }

    // MARK: registration

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw StoreError.unsafe }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Starts a registration from an invitation link. A device that is
    /// already registered keeps its registration.
    public func begin(invitation text: String) throws {
        let invitation = try DeviceTransport.parseInvitation(text)
        if (try? store.loadResetMark()) != nil { throw RuntimeError.resetIncomplete }
        if let existing = try store.loadRegistration(), existing.complete || existing.id != nil { throw StoreError.invalid }
        try store.save(Registration(endpoint: invitation.endpoint, deviceToken: try Self.randomToken(),
                                    invitation: invitation.token, id: nil, password: nil, policy: nil,
                                    profile: UUID(), profileService: UUID()))
        nextEnrollmentStep = .distantPast
    }

    private func advanceEnrollment(_ stored: Registration, now: Date) async {
        guard now >= nextEnrollmentStep else { return }
        nextEnrollmentStep = now.addingTimeInterval(3)
        var registration = stored
        do {
            var answer: EnrollmentAnswer
            if registration.id == nil, let invitation = registration.invitation {
                // A claim whose answer was lost has already bound this key: ask before claiming again.
                if let earlier = try? await transport.poll(endpoint: registration.endpoint, deviceToken: registration.deviceToken) {
                    answer = earlier
                } else {
                    answer = try await transport.claim(endpoint: registration.endpoint, invitation: invitation,
                                                       deviceToken: registration.deviceToken)
                }
                registration.id = answer.id
                try store.save(registration)
            }
            answer = try await transport.poll(endpoint: registration.endpoint, deviceToken: registration.deviceToken)
            guard answer.id == registration.id else { throw DeviceError.invalidResponse }
            if let policy = answer.policy, let password = answer.password {
                registration.policy = policy
                registration.password = password
                registration.invitation = nil
                try store.save(registration)
                connectionError = "none"
                publish("blocked", now: now)
                nextPolicyPoll = .distantPast
                return
            }
            connectionError = "none"
            publish("registration_pending", now: now)
        } catch let error as DeviceError {
            connectionError = StatusCodes.enrollment(error)
            publish("registration_error", now: now)
        } catch {
            connectionError = "enrollment_internal"
            publish("registration_error", now: now)
        }
    }

    // MARK: protection

    /// What is held back while the tunnel is not confirmed, and what goes the
    /// ordinary way then. With an offer each service says; without one every
    /// service follows the one rule the router gave.
    private func heldBack(_ history: PolicyHistory) -> (openDomains: Set<String>, closedNetworks: [String]) {
        let policy = history.current
        guard let entries = names?.entries else {
            let block = names?.block ?? true
            return (block ? [] : Set(policy.resources.map(\.domain)), block ? policy.networks.map(\.network) : [])
        }
        let domain = Dictionary(uniqueKeysWithValues: policy.resources.map { ($0.id, $0.domain) })
        var closed = Set<String>(), open = Set<String>(), closedNetworks = Set<String>()
        for entry in entries where entry.on {
            let names = entry.resources.compactMap { domain[$0] }
            if entry.closed { closed.formUnion(names); closedNetworks.formUnion(entry.cidrs) } else { open.formUnion(names) }
        }
        // A name or network another blocked service also holds stays blocked.
        let reached = Set(policy.networks.map(\.network))
        return (open.subtracting(closed), closedNetworks.intersection(reached).sorted())
    }

    private func rules(for history: PolicyHistory) throws -> String {
        try SystemPlan.packetFilter(subnet: history.current.virtualSubnet, permit: permitted?.interface,
                                    networks: history.current.networks.map(\.network), closed: heldBack(history).closedNetworks)
    }
    private var loadedRules = ""

    /// Denial first, names second: a name never points at a virtual address
    /// that the packet filter does not already hold.
    private func ensureGuard(_ registration: Registration, now: Date) throws -> PolicyHistory {
        phase = "guard"
        guard let bootstrap = registration.policy else { throw StoreError.invalid }
        let history: PolicyHistory
        if let stored = try store.loadHistory() { history = stored } else {
            history = PolicyHistory(policy: try ClientPolicy(data: bootstrap))
            try store.save(history)
        }
        lastHistory = history
        // Read back from the system, in the words it prints its rules in.
        let subnet = history.current.virtualSubnet
        func denied() throws -> Bool {
            try system.packetFilterRules().split(separator: "\n").contains {
                $0.hasPrefix("block drop out quick") && $0.hasSuffix(" to " + subnet)
            }
        }
        phase = "pf"
        if !(try denied()) {
            // Rules this client loaded and somebody flushed come back.
            if guardInstalled { recordFailure("guard_restored", phase: "pf", now: now) }
            permitted = nil
            loadedRules = try rules(for: history)
            try system.loadPacketFilter(loadedRules)
            guard try denied() else { throw StoreError.unsafe }
        } else if try rules(for: history) != loadedRules {
            // What is held back changed with the offer: the networks follow.
            loadedRules = try rules(for: history)
            try system.loadPacketFilter(loadedRules)
        }
        // Rules in the anchor deny nothing while the filter is off or no
        // longer reaches the anchor; that is no guard, and the state says so.
        // The permission goes with it, so nothing passes should the filter
        // come back on before the router confirms this tunnel again.
        // Another program may have switched the filter off: it is switched on
        // again with this client's own reference, the rules closed, and
        // permission waits for the router's word anew. Five failed tries in a
        // row and the guard is reported unconfirmed.
        if !(try system.packetFilterEffective()) {
            permitted = nil
            guardInstalled = false
            let closed = try rules(for: history)
            try? system.restorePacketFilter(closed)
            loadedRules = closed
            guard (try? system.packetFilterEffective()) == true, (try? denied()) == true else {
                guardFailures += 1
                throw GuardFault(failures: guardFailures)
            }
            recordFailure("guard_restored", phase: "pf", now: now)
        }
        guardFailures = 0
        phase = "names"
        // Names point into the tunnel always, except those of services that go
        // the ordinary way while the tunnel is down: they point there only
        // while access is confirmed.
        let ordinary = permitted != nil ? Set<String>() : heldBack(history).openDomains
        let hosts = try system.readHosts()
        let wanted = noServices ? try ManagedHosts.reconcile(hosts, entries: []) : try history.reconcileHosts(hosts, except: ordinary)
        if wanted != hosts { try system.writeHosts(wanted) }
        // Everything under a selected domain is asked through the tunnel; the
        // address that answers is inside the subnet the filter already holds.
        let asked = noServices ? [] : history.current.resources.map(\.domain).filter { !ordinary.contains($0) }.sorted()
        try system.setNameResolution(domains: asked, resolver: asked.isEmpty ? "" : try SystemPlan.layout(subnet).resolver)
        guardInstalled = true
        return history
    }

    private func closePermission(_ history: PolicyHistory?) {
        guard permitted != nil else { return }
        permitted = nil
        if let history, let closed = try? rules(for: history) {
            do { try system.loadPacketFilter(closed); loadedRules = closed } catch { guardInstalled = false }
        }
    }

    private func refreshPolicy(_ registration: Registration, history: PolicyHistory, now: Date) async -> PolicyHistory {
        phase = "policy"
        nextPolicyPoll = now.addingTimeInterval(30)
        // In full-tunnel mode the tunnel that carries everything is this one.
        conditions = system.observeConditions().filter { $0 != "vpn" || !((names?.full ?? false) && permitted != nil) }
        do {
            let data = try await transport.policy(endpoint: registration.endpoint, deviceToken: registration.deviceToken)
            let next = try history.proposing(try ClientPolicy(data: data))
            if next.current != history.current {
                // The denial covers the whole subnet, so new addresses are held before their names appear.
                closePermission(history)
                try store.save(next)
            }
            synchronizationFailed = false
            accessClosed = false
            noServices = false
            release = (try? await transport.release(endpoint: registration.endpoint, deviceToken: registration.deviceToken)) ?? release
            if let id = registration.id {
                names = (try? await transport.services(endpoint: registration.endpoint, deviceToken: registration.deviceToken, id: id)) ?? names
            }
            if addressLookup == nil {
                let server = next.current.serverAddress
                addressLookup = Task { [system] in
                    let resolved = await system.serverIPv4(server)
                    guard !Task.isCancelled else { return }
                    if !resolved.isEmpty { serverIP = resolved }
                    addressLookup = nil
                }
            }
            return next
        } catch DeviceError.connectionFailed {
            // An unanswered poll changes nothing; readiness stays the live gate.
            return history
        } catch {
            // Known to the router and not let in: not enabled yet, or revoked.
            synchronizationFailed = true
            // Without a single service there is nothing to hold names for:
            // they are let go, and come back with the first service.
            noServices = (error as? DeviceError) == .noServices
            accessClosed = noServices || (error as? DeviceError) == .accessRejected
            if noServices {
                // Nothing is assigned any more: the names of what was are not
                // shown as if it still were. The router still says which
                // release it runs, so a newer program is offered all the same.
                names = nil
                release = (try? await transport.release(endpoint: registration.endpoint, deviceToken: registration.deviceToken)) ?? release
            }
            return history
        }
    }

    /// The person's choice of their offer, sent to the router; the next policy
    /// poll, made at once, brings back what it allowed.
    public func choose(on: [String], closed: [String]) async throws {
        guard let registration = try store.loadRegistration(), registration.complete, names?.entries != nil
        else { throw StoreError.invalid }
        try await transport.choose(endpoint: registration.endpoint, deviceToken: registration.deviceToken, on: on, closed: closed)
        nextPolicyPoll = .distantPast
    }

    /// The person's own sites and networks for this device, sent whole; the
    /// next policy poll, made at once, brings back what the router took.
    public func setOwn(domains: [String], networks: [String]) async throws {
        guard let registration = try store.loadRegistration(), registration.complete, names?.own != nil
        else { throw StoreError.invalid }
        try await transport.setOwn(endpoint: registration.endpoint, deviceToken: registration.deviceToken, domains: domains, networks: networks)
        nextPolicyPoll = .distantPast
    }

    /// "Check now": the router probes its tunnels; the services answer a few
    /// seconds later says how each service is. Seconds until it may be asked again.
    public func checkNow() async throws -> Int {
        guard let registration = try store.loadRegistration(), registration.complete else { throw StoreError.invalid }
        let next = try await transport.checkNow(endpoint: registration.endpoint, deviceToken: registration.deviceToken)
        nextPolicyPoll = Date().addingTimeInterval(5)
        return next
    }

    /// The daemon's own failures, for the program to report.
    public func failures() -> [FaultEvent] { store.loadFaults() }

    public func setWanted(_ wanted: Bool) throws {
        let registered = try store.loadRegistration()?.complete == true
        guard !wanted || registered else { throw StoreError.invalid }
        try store.saveIntent(wanted)
        retryConnectionAt = .distantPast
        // Off means off now, not when the step in progress gets round to it.
        if !wanted { closePermission((try? store.loadHistory()) ?? lastHistory) }
    }

    /// The profile for the system's VPN settings, for the administrator who registers the device.
    public func profile() throws -> Data {
        guard let registration = try store.loadRegistration(), let password = registration.password,
              let history = try store.loadHistory() else { throw StoreError.invalid }
        return try SystemPlan.vpnProfile(policy: history.current, password: password,
                                         identifier: registration.profile, serviceIdentifier: registration.profileService, full: names?.full ?? false)
    }

    private func advanceConnection(_ registration: Registration, history: PolicyHistory, now: Date) async throws {
        phase = "connect"
        // A profile seen installed and missing now was removed by somebody.
        guard system.vpnInstalled() else {
            closePermission(history); connectionError = store.profileSeen() ? "profile_removed" : "none"
            publish("profile_required", now: now); return
        }
        try? store.saveProfileSeen()
        // Switching access on connects the VPN and switching it off
        // disconnects it: what the window says and what the system shows are
        // the same thing.
        guard try store.loadIntent() else {
            closePermission(history)
            if system.vpnConnected() { try system.stopVPN() }
            connectionError = "none"; publish("blocked", now: now); return
        }
        guard system.vpnConnected() else {
            closePermission(history)
            let since = connectingSince ?? now
            if now >= retryConnectionAt { retryConnectionAt = now.addingTimeInterval(10); try system.startVPN() }
            // Thirty seconds without a session: why, as far as this Mac can
            // tell - no network, a server name that does not resolve, or an
            // IKE exchange nobody answers (UDP 500 and 4500 closed on the way).
            if now.timeIntervalSince(since) >= 30 {
                if !system.online() { connectionError = "offline" }
                else if await system.serverIPv4(history.current.serverAddress).isEmpty { connectionError = "server_not_found" }
                else { connectionError = "ike_no_answer" }
                publish("connection_error", now: now); connectingSince = since; return
            }
            connectionError = "none"
            publish("connecting", now: now); connectingSince = since; return
        }
        let seen: TunnelObservation?
        let layout = try SystemPlan.layout(history.current.virtualSubnet)
        // A network counts only once the system routes it into the tunnel too.
        do { seen = try system.observeTunnel(addresses: history.current.resources.map(\.address) + [layout.resolver] +
                                             history.current.networks.map { try SystemPlan.probeAddress($0.network) }) }
        catch let fault as TunnelFault {
            closePermission(history)
            try? system.stopVPN()
            retryConnectionAt = now.addingTimeInterval(30)
            connectionError = fault.rawValue; publish("connection_error", now: now); return
        }
        guard let seen else { closePermission(history); connectionError = "none"; publish("connecting", now: now); return }
        // The installed profile decides what the system routes into the
        // tunnel, and it must agree with the mode the router set: a tunnel
        // that takes everything when only services were meant is refused, and
        // one that takes only services when everything was meant asks for the
        // profile to be installed again.
        let full = names?.full ?? false
        if seen.everything != full {
            closePermission(history)
            try? system.stopVPN()
            retryConnectionAt = now.addingTimeInterval(30)
            connectionError = full ? "profile_mode" : TunnelFault.takesEverything.rawValue
            publish("connection_error", now: now); return
        }
        // While access stands confirmed, the tunnel is still looked at every
        // step, but the router is asked again only every few seconds: each
        // question costs it a process, and its own admission does not wait.
        if permitted == seen, now < nextReadinessAt { publish("protected", now: now); return }
        do {
            guard let id = registration.id else { throw DeviceError.invalidResponse }
            let ready = try await transport.readiness(endpoint: registration.endpoint, deviceToken: registration.deviceToken,
                                                      tunnelAddress: seen.address)
            guard ready.id == id, ready.address == seen.address, ready.revision == history.current.revision
            else { throw DeviceError.differentPolicy }
        } catch let refusal as DeviceError {
            // One unanswered question is not a lost path; the router keeps its
            // own admission for fifteen seconds and permission outlives a
            // missed answer by less. A refusal naming this device ends it now.
            let transient = refusal == .pathUnavailable || refusal == .connectionFailed
            if transient, permitted == seen, now < readyUntil { publish("protected", now: now); return }
            closePermission(history)
            connectionError = StatusCodes.path(refusal)
            // The router and this Mac disagreeing on the policy for five
            // minutes is not the network: it is reported.
            if refusal == .differentPolicy {
                let since = mismatchSince ?? now
                mismatchSince = since
                if now.timeIntervalSince(since) >= 300 { recordFailure("policy_mismatch", phase: "readiness", now: now) }
            } else { mismatchSince = nil }
            publish("tunnel_connected", now: now); return
        }
        // The answer was awaited; access may have been switched off meanwhile.
        guard try store.loadIntent() else { closePermission(history); connectionError = "none"; publish("blocked", now: now); return }
        if permitted != seen {
            permitted = seen
            do { loadedRules = try rules(for: history); try system.loadPacketFilter(loadedRules) }
            catch { permitted = nil; throw error }
        }
        mismatchSince = nil
        readyUntil = now.addingTimeInterval(20)
        nextReadinessAt = now.addingTimeInterval(6)
        connectionError = "none"
        publish("protected", now: now)
    }

    private var ticking = false

    /// One step. Called every two seconds by the daemon, and by a command
    /// from the window. The actor lets a second call in while the first waits
    /// for the router; that one returns at once, so two steps never interleave
    /// and an answer awaited by one cannot open what the other just closed.
    public func tick(now: Date = Date()) async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        // A reset left unfinished is finished first, at every step.
        let mark: ResetMark?
        do { mark = try store.loadResetMark() } catch { mark = ResetMark(startedAt: Int(now.timeIntervalSince1970), pending: ResetStep.allCases, profile: nil) }
        if let mark {
            let done = runReset(mark, now: now)
            connectionError = "none"; publish(done.complete ? "enrollment_required" : "reset_incomplete", now: now); return
        }
        // Between "going to sleep" and sleep nothing is opened again.
        if asleep { closePermission(lastHistory); return }
        var history: PolicyHistory?
        // What cannot be read is never thrown away here: the link that made
        // it was single-use. The owner decides with "Reset...".
        let stored: Registration?
        do { stored = try store.loadRegistration() } catch { needsReset("registration_unreadable", now: now); return }
        do {
            guard let registration = stored else {
                connectionError = "none"; publish("enrollment_required", now: now); return
            }
            guard registration.complete else { await advanceEnrollment(registration, now: now); return }
            do { _ = try store.loadHistory() } catch { needsReset("policy_unreadable", now: now); return }
            // Asked in every registered state: a device that cannot get its
            // policy is the one worth hearing from.
            if now >= nextReportPoll { await answerReportRequest(registration, now: now) }
            var current = try ensureGuard(registration, now: now)
            history = current
            if now >= nextPolicyPoll {
                current = await refreshPolicy(registration, history: current, now: now)
                if current.current != history?.current { current = try ensureGuard(registration, now: now) }
                history = current
            }
            if synchronizationFailed {
                closePermission(current)
                if system.vpnConnected() { try? system.stopVPN() }
                connectionError = noServices ? "no_services" : "synchronization"; publish(accessClosed ? "access_closed" : "error", now: now); return
            }
            try await advanceConnection(registration, history: current, now: now)
        } catch let fault as GuardFault {
            closePermission(history ?? lastHistory)
            guardInstalled = false
            connectionError = fault.code
            if fault.failures >= 5 { recordFailure("guard_unconfirmed", phase: "pf", now: now) }
            publish("error", now: now)
        } catch {
            closePermission(history ?? lastHistory)
            guardInstalled = false
            connectionError = "internal"
            recordFailure("internal", phase: phase, now: now)
            publish("error", now: now)
        }
    }

    private func needsReset(_ cause: String, now: Date) {
        closePermission(lastHistory)
        if system.vpnConnected() { try? system.stopVPN() }
        connectionError = cause
        recordFailure("needs_reset", phase: "tick", now: now)
        publish("needs_reset", now: now)
    }

    // MARK: sleep

    /// The system is about to sleep: permission goes now, the denial stays,
    /// and nothing opens again until it has woken.
    public func willSleep() {
        asleep = true
        closePermission((try? store.loadHistory()) ?? lastHistory)
    }

    /// Awake: the next step connects and asks the router at once instead of
    /// waiting out the retry it was in before sleep.
    public func didWake() {
        asleep = false
        retryConnectionAt = .distantPast; nextReadinessAt = .distantPast
        nextPolicyPoll = .distantPast; readyUntil = .distantPast
    }

    /// Everything this program set up on the machine goes - the VPN profile,
    /// the blocking rules, the names, the registration - and the program
    /// stays, ready to register again with a new link. Each step is taken
    /// whatever became of the one before; what failed is left in a mark and
    /// taken again at every step until it is gone.
    @discardableResult public func reset(now: Date = Date()) -> ResetReport {
        let profile = (try? store.loadRegistration())??.profile
        let mark = ResetMark(startedAt: Int(now.timeIntervalSince1970), pending: ResetStep.allCases,
                             profile: profile.map(SystemPlan.profileIdentifier))
        try? store.saveResetMark(mark)
        permitted = nil
        lastReset = nil
        let done = runReset(mark, now: now)
        guardInstalled = false; readyUntil = .distantPast; nextReadinessAt = .distantPast
        noServices = false; synchronizationFailed = false; accessClosed = false; guardFailures = 0
        nextPolicyPoll = .distantPast; nextEnrollmentStep = .distantPast; retryConnectionAt = .distantPast
        addressLookup?.cancel(); addressLookup = nil
        names = nil; serverIP = ""; release = ""; connectionError = "none"; lastHistory = nil; loadedRules = ""
        publish(done.complete ? "enrollment_required" : "reset_incomplete", now: now)
        return done
    }

    /// Uninstallation: the same steps, then the daemon's directory itself.
    @discardableResult public func remove() throws -> ResetReport {
        let done = reset()
        guard done.complete else { return done }
        try store.erase()
        return done
    }

    private func runReset(_ mark: ResetMark, now: Date) -> ResetReport {
        var entries: [ResetReport.Entry] = []
        for step in ResetStep.allCases where mark.pending.contains(step) {
            let outcome = take(step, profile: mark.profile)
            entries.append(ResetReport.Entry(step: step, outcome: outcome, reason: outcome == .failed ? "refused" : nil))
        }
        // Read back: what the system shows, not what the steps said.
        entries = entries.map { entry in
            guard entry.outcome != .failed, remains(entry.step) else { return entry }
            return ResetReport.Entry(step: entry.step, outcome: .failed, reason: "still_present")
        }
        // A retry reports the steps it took over those done before.
        var merged = lastReset?.steps.filter { earlier in !entries.contains { $0.step == earlier.step } } ?? []
        merged += entries
        merged.sort { ResetStep.allCases.firstIndex(of: $0.step)! < ResetStep.allCases.firstIndex(of: $1.step)! }
        let done = ResetReport(steps: merged)
        lastReset = done
        if done.complete {
            try? store.clearResetMark()
        } else {
            var next = mark
            next.pending = done.failed
            try? store.saveResetMark(next)
            if now.timeIntervalSince1970 - Double(mark.startedAt) > 600 { recordFailure("reset_incomplete", phase: "reset", now: now) }
        }
        return done
    }

    private func take(_ step: ResetStep, profile: String?) -> ResetReport.Outcome {
        do {
            switch step {
            case .connection:
                guard system.vpnConnected() else { return .absent }
                try system.stopVPN()
            case .profile:
                guard system.vpnInstalled() else { return .absent }
                if let profile { system.removeVPNProfile(identifier: profile) }
                // Without the registration that named it, the profile is found by its prefix.
                for found in system.installedProfiles() ?? [] where found.hasPrefix(SystemPlan.profilePrefix) && found != SystemPlan.browserProfileIdentifier {
                    system.removeVPNProfile(identifier: found)
                }
            case .browsers:
                let id = SystemPlan.browserProfileIdentifier
                if let installed = system.installedProfiles(), !installed.contains(id) { return .absent }
                system.removeVPNProfile(identifier: id)
            case .hosts:
                let hosts = try system.readHosts(), cleared = try ManagedHosts.reconcile(hosts, entries: [])
                guard cleared != hosts else { return .absent }
                try system.writeHosts(cleared)
            case .names:
                let held = system.heldNames()
                try system.setNameResolution(domains: [], resolver: "")
                if held.isEmpty { return .absent }
            case .filter:
                guard !(try system.packetFilterRules()).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .absent }
                try system.loadPacketFilter("")
            case .registration:
                return try store.forget() ? .removed : .absent
            }
            return .removed
        } catch {
            return .failed
        }
    }

    /// Whether what a step removes is still there.
    private func remains(_ step: ResetStep) -> Bool {
        switch step {
        case .connection: return system.vpnConnected()
        case .profile: return system.vpnInstalled()
        case .browsers: return system.installedProfiles()?.contains(SystemPlan.browserProfileIdentifier) ?? false
        case .hosts:
            guard let hosts = try? system.readHosts(), let cleared = try? ManagedHosts.reconcile(hosts, entries: []) else { return true }
            return cleared != hosts
        case .names: return !system.heldNames().isEmpty
        case .filter: return !((try? system.packetFilterRules()) ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .registration: return ((try? store.loadRegistration()) ?? nil) != nil
        }
    }
}
