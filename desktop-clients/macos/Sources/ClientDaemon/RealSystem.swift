import ClientCore
import Foundation

enum Tool {
    /// Runs one system tool by absolute path and returns what it printed.
    static func run(_ path: String, _ arguments: [String], input: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe(), feed = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : feed
        try process.run()
        if let input { feed.fileHandleForWriting.write(Data(input.utf8)); try? feed.fileHandleForWriting.close() }
        let limit = DispatchTime.now() + .seconds(10)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if finished.wait(timeout: limit) == .timedOut { process.terminate(); throw TunnelFault.unavailable }
        return (process.terminationStatus, String(data: data.prefix(1_048_576), encoding: .utf8) ?? "")
    }
}

/// The machine itself: the hosts file, the packet filter and the system's VPN service.
struct RealSystem: SystemActions {
    let hostsPath = "/etc/hosts"

    private final class Seen: @unchecked Sendable { var present = false, until = Date.distantPast }
    private let profile = Seen()
    func readHosts() throws -> String {
        guard let data = FileManager.default.contents(atPath: hostsPath), let text = String(data: data, encoding: .utf8)
        else { throw StoreError.unsafe }
        return text
    }

    func writeHosts(_ text: String) throws {
        // Same directory, so the rename is one step; the file keeps its mode.
        let staged = hostsPath + ".ikev2-manager-client.new"
        unlink(staged)
        let descriptor = open(staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw StoreError.unsafe }
        let data = Data(text.utf8)
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        let flushed = fsync(descriptor) == 0
        fchmod(descriptor, 0o644)
        close(descriptor)
        guard written == data.count, flushed, rename(staged, hostsPath) == 0 else { unlink(staged); throw StoreError.unsafe }
        _ = try? Tool.run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = try? Tool.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    /// One file per domain in /etc/resolver, which the system reads for that
    /// domain and everything under it. Files are told apart by their first line.
    func setNameResolution(domains: [String], resolver: String) throws {
        let directory = "/etc/resolver", marker = "# IKEv2 Manager Client"
        let wanted = Set(domains)
        guard wanted.allSatisfy({ $0.range(of: #"\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\z"#, options: .regularExpression) != nil })
        else { throw StoreError.invalid }
        var changed = false
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where !wanted.contains(name) {
            let path = directory + "/" + name
            if (try? String(contentsOfFile: path, encoding: .utf8))?.hasPrefix(marker) == true { unlink(path); changed = true }
        }
        guard !wanted.isEmpty else { if changed { flushNames() }; return }
        guard SystemPlan.ipv4Address(resolver) else { throw StoreError.invalid }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let content = marker + "\nnameserver " + resolver + "\n"
        for name in wanted {
            let path = directory + "/" + name
            let existing = try? String(contentsOfFile: path, encoding: .utf8)
            if existing == content { continue }
            // A file somebody else put there for this domain is theirs.
            if let existing, !existing.hasPrefix(marker) { throw StoreError.unsafe }
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o644)
            changed = true
        }
        if changed { flushNames() }
    }

    private func flushNames() {
        _ = try? Tool.run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = try? Tool.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    func loadPacketFilter(_ rules: String) throws {
        if rules.isEmpty {
            _ = try Tool.run("/sbin/pfctl", ["-a", SystemPlan.anchor, "-F", "rules"])
            return
        }
        // Enabling is reference counted by the system; asking again is harmless.
        _ = try Tool.run("/sbin/pfctl", ["-E"])
        guard try Tool.run("/sbin/pfctl", ["-a", SystemPlan.anchor, "-f", "-"], input: rules).status == 0
        else { throw StoreError.unsafe }
    }

    func packetFilterRules() throws -> String {
        try Tool.run("/sbin/pfctl", ["-a", SystemPlan.anchor, "-s", "rules"]).output
    }

    /// The profile is the system's own; its list of installed profiles says
    /// whether the owner approved it. Asked at most every five seconds.
    func vpnInstalled() -> Bool {
        if Date() < profile.until { return profile.present }
        let listed = (try? Tool.run("/usr/bin/profiles", ["list", "-all"]).output) ?? ""
        profile.present = listed.contains(SystemPlan.profilePrefix)
        profile.until = Date().addingTimeInterval(5)
        return profile.present
    }

    func removeVPNProfile(identifier: String) {
        _ = try? Tool.run("/usr/bin/profiles", ["remove", "-identifier", identifier])
    }

    private func routeInterface(_ destination: String) throws -> String? {
        try Tool.run("/sbin/route", ["-n", "get", destination]).output.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }?
            .split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func observeTunnel(addresses: [String]) throws -> TunnelObservation? {
        guard let first = addresses.first, let interface = try routeInterface(first),
              interface.range(of: #"\Aipsec[0-9]{1,4}\z"#, options: .regularExpression) != nil else { return nil }
        for address in addresses.dropFirst() where try routeInterface(address) != interface { return nil }
        // Everything else must keep the route it had.
        if try routeInterface("default") == interface { throw TunnelFault.takesEverything }
        let lines = try Tool.run("/sbin/ifconfig", [interface]).output.split(separator: "\n")
        guard let line = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("inet ") }) else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return TunnelObservation(interface: interface, address: String(fields[1]))
    }
}

/// The same decisions against files in one directory, for running the daemon
/// without privileges against a test router. It touches nothing of the system.
final class DrySystem: SystemActions, @unchecked Sendable {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private func text(_ name: String) -> String { (try? String(contentsOf: file(name), encoding: .utf8)) ?? "" }
    func readHosts() throws -> String { text("hosts") }
    func writeHosts(_ text: String) throws { try text.write(to: file("hosts"), atomically: true, encoding: .utf8) }
    func setNameResolution(domains: [String], resolver: String) throws {
        let wanted = domains.isEmpty ? "" : resolver + " " + domains.joined(separator: " ") + "\n"
        if wanted != text("resolvers") { try wanted.write(to: file("resolvers"), atomically: true, encoding: .utf8) }
    }
    func loadPacketFilter(_ rules: String) throws { try rules.write(to: file("pf.rules"), atomically: true, encoding: .utf8) }
    func packetFilterRules() throws -> String { text("pf.rules") }
    func vpnInstalled() -> Bool { FileManager.default.fileExists(atPath: file("vpn-installed").path) }
    func removeVPNProfile(identifier: String) { try? FileManager.default.removeItem(at: file("vpn-installed")) }
    func observeTunnel(addresses: [String]) throws -> TunnelObservation? {
        let fields = text("tunnel").split(separator: " ").map(String.init)
        return fields.count == 2 ? TunnelObservation(interface: fields[0], address: fields[1].trimmingCharacters(in: .newlines)) : nil
    }
}
