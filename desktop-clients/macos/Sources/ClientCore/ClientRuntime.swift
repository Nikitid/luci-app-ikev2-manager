import Foundation
import Security

public struct TunnelObservation: Sendable, Equatable {
    public let interface: String
    public let address: String
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
    func vpnInstalled() -> Bool
    /// The tunnel interface and its address once every address is routed
    /// through it and nothing else is; nil while the system is still settling.
    func observeTunnel(addresses: [String]) throws -> TunnelObservation?
    /// Uninstallation: takes the VPN profile this client asked the owner to install.
    func removeVPNProfile(identifier: String)
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
    private var nextPolicyPoll = Date.distantPast
    private var nextEnrollmentStep = Date.distantPast
    private var retryConnectionAt = Date.distantPast
    private var synchronizationFailed = false
    private var accessClosed = false
    private var release = ""
    private var names: DeviceServices?
    private var connectionError = "none"

    public init(store: ClientStore, system: any SystemActions, transport: any DeviceRequests = DeviceTransport()) {
        self.store = store
        self.system = system
        self.transport = transport
        report = ClientStatusReport(state: "starting", guardInstalled: false, protected: false, routed: false, wanted: false,
                                    profileInstalled: false, error: "none", services: [], available: [], domains: 0,
                                    revision: 0, release: "", updatedAt: 0)
    }

    public func status() -> ClientStatusReport { report }

    private func publish(_ state: String, now: Date) {
        let history = try? store.loadHistory()
        report = ClientStatusReport(
            state: state, guardInstalled: guardInstalled, protected: state == "protected" && permitted != nil && guardInstalled,
            routed: state == "tunnel_connected" || state == "protected", wanted: (try? store.loadIntent()) ?? false,
            profileInstalled: system.vpnInstalled(), error: connectionError,
            services: Array((names?.selected ?? []).prefix(64)), available: Array((names?.available ?? []).prefix(64)),
            domains: Set(history?.current.resources.map(\.domain) ?? []).count,
            revision: history?.current.revision ?? 0, release: release, blockWithoutTunnel: names?.block ?? true,
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
            connectionError = "registration_" + error.rawValue
            publish("registration_error", now: now)
        } catch {
            connectionError = "registration_storage"
            publish("registration_error", now: now)
        }
    }

    // MARK: protection

    private func rules(for history: PolicyHistory) throws -> String {
        try SystemPlan.packetFilter(subnet: history.current.virtualSubnet, permit: permitted?.interface)
    }

    /// Denial first, names second: a name never points at a virtual address
    /// that the packet filter does not already hold.
    private func ensureGuard(_ registration: Registration) throws -> PolicyHistory {
        guard let bootstrap = registration.policy else { throw StoreError.invalid }
        let history: PolicyHistory
        if let stored = try store.loadHistory() { history = stored } else {
            history = PolicyHistory(policy: try ClientPolicy(data: bootstrap))
            try store.save(history)
        }
        // Read back from the system, in the words it prints its rules in.
        let subnet = history.current.virtualSubnet
        func denied() throws -> Bool {
            try system.packetFilterRules().split(separator: "\n").contains {
                $0.hasPrefix("block drop out quick") && $0.hasSuffix(" to " + subnet)
            }
        }
        if !(try denied()) {
            permitted = nil
            try system.loadPacketFilter(try rules(for: history))
            guard try denied() else { throw StoreError.unsafe }
        }
        // Names point into the tunnel always, unless the administrator let
        // this device's services go the ordinary way while the tunnel is
        // down: then they point there only while access is confirmed.
        let pointed = (names?.block ?? true) || permitted != nil
        let hosts = try system.readHosts()
        let wanted = pointed ? try history.reconcileHosts(hosts) : try ManagedHosts.reconcile(hosts, entries: [])
        if wanted != hosts { try system.writeHosts(wanted) }
        // Everything under a selected domain is asked through the tunnel; the
        // address that answers is inside the subnet the filter already holds.
        try system.setNameResolution(domains: pointed ? history.current.resources.map(\.domain).sorted() : [],
                                     resolver: pointed ? try SystemPlan.layout(subnet).resolver : "")
        guardInstalled = true
        return history
    }

    private func closePermission(_ history: PolicyHistory?) {
        guard permitted != nil else { return }
        permitted = nil
        if let history, let closed = try? rules(for: history) {
            do { try system.loadPacketFilter(closed) } catch { guardInstalled = false }
        }
    }

    private func refreshPolicy(_ registration: Registration, history: PolicyHistory, now: Date) async -> PolicyHistory {
        nextPolicyPoll = now.addingTimeInterval(30)
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
            release = (try? await transport.release(endpoint: registration.endpoint, deviceToken: registration.deviceToken)) ?? release
            if let id = registration.id {
                names = (try? await transport.services(endpoint: registration.endpoint, deviceToken: registration.deviceToken, id: id)) ?? names
            }
            return next
        } catch DeviceError.connectionFailed {
            // An unanswered poll changes nothing; readiness stays the live gate.
            return history
        } catch {
            // Known to the router and not let in: not enabled yet, or revoked.
            synchronizationFailed = true
            accessClosed = (error as? DeviceError) == .accessRejected
            return history
        }
    }

    public func setWanted(_ wanted: Bool) throws {
        let registered = try store.loadRegistration()?.complete == true
        guard !wanted || registered else { throw StoreError.invalid }
        try store.saveIntent(wanted)
        retryConnectionAt = .distantPast
        // Off means off now, not when the step in progress gets round to it.
        if !wanted { closePermission(try? store.loadHistory()) }
    }

    /// The profile for the system's VPN settings, for the administrator who registers the device.
    public func profile() throws -> Data {
        guard let registration = try store.loadRegistration(), let password = registration.password,
              let history = try store.loadHistory() else { throw StoreError.invalid }
        return try SystemPlan.vpnProfile(policy: history.current, password: password,
                                         identifier: registration.profile, serviceIdentifier: registration.profileService)
    }

    private func advanceConnection(_ registration: Registration, history: PolicyHistory, now: Date) async throws {
        guard system.vpnInstalled() else {
            closePermission(history); connectionError = "none"; publish("profile_required", now: now); return
        }
        // The tunnel is the system's: the user switches it on in the VPN
        // settings, since current macOS gives a program no way to start a
        // connection installed by a profile. It routes the virtual subnet
        // alone, and the packet filter decides whether anything may use it.
        // Switching access off closes the filter and leaves the connection.
        guard try store.loadIntent() else {
            closePermission(history)
            connectionError = "none"; publish("blocked", now: now); return
        }
        let seen: TunnelObservation?
        let layout = try SystemPlan.layout(history.current.virtualSubnet)
        do { seen = try system.observeTunnel(addresses: history.current.resources.map(\.address) + [layout.resolver]) }
        catch let fault as TunnelFault {
            closePermission(history)
            connectionError = fault.rawValue; publish("connection_error", now: now); return
        }
        guard let seen else { closePermission(history); publish("connecting", now: now); return }
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
            connectionError = "path_" + refusal.rawValue; publish("tunnel_connected", now: now); return
        }
        // The answer was awaited; access may have been switched off meanwhile.
        guard try store.loadIntent() else { closePermission(history); connectionError = "none"; publish("blocked", now: now); return }
        if permitted != seen {
            permitted = seen
            do { try system.loadPacketFilter(try rules(for: history)) }
            catch { permitted = nil; throw error }
        }
        readyUntil = now.addingTimeInterval(10)
        connectionError = "none"
        publish("protected", now: now)
    }

    /// One step. Called every two seconds by the daemon.
    public func tick(now: Date = Date()) async {
        var history: PolicyHistory?
        do {
            guard let registration = try store.loadRegistration() else {
                connectionError = "none"; publish("enrollment_required", now: now); return
            }
            guard registration.complete else { await advanceEnrollment(registration, now: now); return }
            var current = try ensureGuard(registration)
            history = current
            if now >= nextPolicyPoll {
                current = await refreshPolicy(registration, history: current, now: now)
                if current.current != history?.current { current = try ensureGuard(registration) }
                history = current
            }
            if synchronizationFailed {
                closePermission(current)
                connectionError = "synchronization"; publish(accessClosed ? "access_closed" : "error", now: now); return
            }
            try await advanceConnection(registration, history: current, now: now)
        } catch {
            closePermission(history)
            guardInstalled = false
            connectionError = "internal"
            publish("error", now: now)
        }
    }

    /// Uninstallation: names and rules go, then the stored device.
    public func remove() throws {
        permitted = nil
        if let registration = try? store.loadRegistration() {
            system.removeVPNProfile(identifier: SystemPlan.profileIdentifier(registration.profile))
        }
        let hosts = try system.readHosts(), cleared = try ManagedHosts.reconcile(hosts, entries: [])
        if cleared != hosts { try system.writeHosts(cleared) }
        try system.setNameResolution(domains: [], resolver: "")
        try system.loadPacketFilter("")
        try store.erase()
    }
}
