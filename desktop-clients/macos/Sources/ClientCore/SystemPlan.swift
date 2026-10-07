import Foundation

/// Text handed to the operating system. Building it has no side effects, so
/// every rule and every profile key can be checked without privileges.
public enum SystemPlan {
    public static let anchor = "com.apple/250.IKEv2ManagerClient"
    public static let serviceName = "Waypoint"
    public static let managedDomain = "managed.ikev2-manager"

    public static let profilePrefix = "io.github.nikitid.ikev2-manager-client."
    public static func profileIdentifier(_ identifier: UUID) -> String {
        profilePrefix + identifier.uuidString
    }

    /// The layout every party derives from the virtual subnet alone: the last
    /// address of its lower half answers names, and its upper half is handed
    /// out by the router, one address per name asked for.
    public static func layout(_ subnet: String) throws -> (resolver: String, names: String) {
        let parts = subnet.components(separatedBy: "/")
        guard parts.count == 2, ipv4(parts[0]), let prefix = Int(parts[1]), (16...28).contains(prefix)
        else { throw PolicyError.invalidPolicy }
        let first = parts[0].split(separator: ".").reduce(UInt32(0)) { $0 << 8 | UInt32($1)! }
        let half = UInt32(1) << UInt32(31 - prefix)
        guard first % (half * 2) == 0 else { throw PolicyError.invalidPolicy }
        func text(_ value: UInt32) -> String { "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)" }
        return (text(first + half - 1), text(first + half) + "/\(prefix + 1)")
    }

    public static func ipv4Address(_ text: String) -> Bool { ipv4(text) }

    static func ipv4(_ text: String) -> Bool {
        text.range(of: #"\A(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\z"#,
                   options: .regularExpression) != nil
    }

    /// Packet-filter rules for the client's anchor. The virtual subnet is
    /// denied on every path; a confirmed tunnel interface is let through for
    /// the selected addresses only, ahead of the denial.
    public static func packetFilter(subnet: String, permit interface: String?) throws -> String {
        _ = try layout(subnet)
        var rules = ""
        if let interface {
            // The whole subnet: fixed addresses, the resolver and the names
            // network. Which of them this device may reach is the router's call.
            guard interface.range(of: #"\A(?:ipsec|utun)[0-9]{1,4}\z"#, options: .regularExpression) != nil
            else { throw PolicyError.invalidPolicy }
            rules += "pass out quick on \(interface) inet from any to \(subnet) keep state\n"
        }
        rules += "block drop out quick inet from any to \(subnet)\n"
        return rules
    }

    /// A browser that resolves names over its own encrypted channel never
    /// asks the system and would reach a selected service around the tunnel.
    /// Each browser has a managed setting for this; the profile carries it.
    static func browserPayloads(_ profile: String) -> String {
        let chromium = ["com.google.Chrome", "com.microsoft.Edge", "com.brave.Browser", "ru.yandex.desktop.yandex-browser"]
        var text = ""
        for (index, domain) in (chromium + ["org.mozilla.firefox"]).enumerated() {
            let settings = domain == "org.mozilla.firefox"
                ? "<key>EnterprisePoliciesEnabled</key><true/><key>DNSOverHTTPS</key><dict><key>Enabled</key><false/><key>Locked</key><true/></dict>"
                : "<key>DnsOverHttpsMode</key><string>off</string>"
            text += """
                    <dict>
                        <key>PayloadType</key><string>\(domain)</string>
                        <key>PayloadVersion</key><integer>1</integer>
                        <key>PayloadIdentifier</key><string>io.github.nikitid.ikev2-manager-client.\(profile).browser\(index)</string>
                        <key>PayloadUUID</key><string>\(UUID().uuidString)</string>
                        <key>PayloadDisplayName</key><string>Name resolution through the system</string>
                        \(settings)
                    </dict>

            """
        }
        return text
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A configuration profile with one IKEv2 service for this device. The
    /// device names itself in the managed domain, so the server offers it the
    /// virtual subnet alone and the system routes nothing else into the tunnel.
    public static func vpnProfile(policy: ClientPolicy, password: String, identifier: UUID, serviceIdentifier: UUID) throws -> Data {
        guard password.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil
        else { throw PolicyError.invalidPolicy }
        let proposal = """
                <dict>
                    <key>EncryptionAlgorithm</key><string>AES-256</string>
                    <key>IntegrityAlgorithm</key><string>SHA2-256</string>
                    <key>DiffieHellmanGroup</key><integer>14</integer>
                    <key>LifeTimeInMinutes</key><integer>1440</integer>
                </dict>
        """
        let id = identifier.uuidString
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadType</key><string>Configuration</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadScope</key><string>System</string>
            <key>PayloadIdentifier</key><string>\(profileIdentifier(identifier))</string>
            <key>PayloadUUID</key><string>\(id)</string>
            <key>PayloadDisplayName</key><string>\(serviceName)</string>
            <key>PayloadDescription</key><string>Sends the services assigned to this device through \(escape(policy.serverAddress)).</string>
            <key>PayloadContent</key>
            <array>
        \(browserPayloads(id))
                <dict>
                    <key>PayloadType</key><string>com.apple.vpn.managed</string>
                    <key>PayloadVersion</key><integer>1</integer>
                    <key>PayloadIdentifier</key><string>io.github.nikitid.ikev2-manager-client.\(id).vpn</string>
                    <key>PayloadUUID</key><string>\(serviceIdentifier.uuidString)</string>
                    <key>PayloadDisplayName</key><string>\(serviceName)</string>
                    <key>UserDefinedName</key><string>\(serviceName)</string>
                    <key>VPNType</key><string>IKEv2</string>
                    <key>IKEv2</key>
                    <dict>
                        <key>RemoteAddress</key><string>\(escape(policy.serverAddress))</string>
                        <key>RemoteIdentifier</key><string>\(escape(policy.remoteID))</string>
                        <key>LocalIdentifier</key><string>\(policy.id)@\(managedDomain)</string>
                        <key>AuthenticationMethod</key><string>None</string>
                        <key>ExtendedAuthEnabled</key><integer>1</integer>
                        <key>AuthName</key><string>\(policy.id)</string>
                        <key>AuthPassword</key><string>\(password)</string>
                        <key>DeadPeerDetectionRate</key><string>Medium</string>
                        <key>DisableMOBIKE</key><integer>0</integer>
                        <key>DisableRedirect</key><integer>1</integer>
                        <key>EnablePFS</key><integer>1</integer>
                        <key>UseConfigurationAttributeInternalIPSubnet</key><integer>0</integer>
                        <key>IKESecurityAssociationParameters</key>
        \(proposal)
                        <key>ChildSecurityAssociationParameters</key>
        \(proposal)
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>

        """
        let data = Data(text.utf8)
        // The system must be able to read what it is asked to install.
        guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any]
        else { throw PolicyError.invalidPolicy }
        return data
    }
}
