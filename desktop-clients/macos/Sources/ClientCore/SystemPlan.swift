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

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static let browserProfileIdentifier = "io.github.nikitid.ikev2-manager-client.browsers"

    /// The browsers this program knows how to tell, by the name of their settings.
    public static let browserDomains = ["com.google.Chrome", "com.microsoft.Edge", "com.brave.Browser", "ru.yandex.desktop.yandex-browser", "org.mozilla.firefox"]

    /// A browser set to resolve names over its own encrypted channel never
    /// asks the system and reaches a service around the tunnel. Each browser
    /// has a managed setting to ask the system instead. It reaches beyond this
    /// program's services, so it is its own profile, made only when the person
    /// at the window asks for it and installed by them; removing the profile
    /// takes the setting back.
    public static func browserProfile() -> Data {
        var payloads = ""
        for (index, domain) in browserDomains.enumerated() {
            let settings = domain == "org.mozilla.firefox"
                ? "<key>EnterprisePoliciesEnabled</key><true/><key>DNSOverHTTPS</key><dict><key>Enabled</key><false/><key>Locked</key><true/></dict>"
                : "<key>DnsOverHttpsMode</key><string>off</string>"
            payloads += """
                    <dict>
                        <key>PayloadType</key><string>\(domain)</string>
                        <key>PayloadVersion</key><integer>1</integer>
                        <key>PayloadIdentifier</key><string>\(browserProfileIdentifier).\(index)</string>
                        <key>PayloadUUID</key><string>\(UUID().uuidString)</string>
                        <key>PayloadDisplayName</key><string>Name resolution through the system</string>
                        \(settings)
                    </dict>

            """
        }
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadType</key><string>Configuration</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadScope</key><string>System</string>
            <key>PayloadIdentifier</key><string>\(browserProfileIdentifier)</string>
            <key>PayloadUUID</key><string>\(UUID().uuidString)</string>
            <key>PayloadDisplayName</key><string>\(serviceName): browsers</string>
            <key>PayloadDescription</key><string>Tells Chrome, Edge, Brave, Yandex Browser and Firefox to resolve names through the system, so the services of \(serviceName) go through its tunnel. Remove this profile to give the browsers their own setting back.</string>
            <key>PayloadContent</key>
            <array>
        \(payloads)
            </array>
        </dict>
        </plist>

        """
        return Data(text.utf8)
    }

    /// Which of the given browsers resolve names by themselves, from the
    /// settings of the person at the window: `support` is their Application
    /// Support folder, `managed` where the system keeps settings a profile
    /// set. Read, never written. "Automatic" is not such a setting.
    public static func selfResolvingBrowsers(support: URL, managed: URL) -> [String] {
        let chromium: [(String, String, String)] = [("Chrome", "Google/Chrome", "com.google.Chrome"), ("Edge", "Microsoft Edge", "com.microsoft.Edge"),
            ("Brave", "BraveSoftware/Brave-Browser", "com.brave.Browser"), ("Яндекс Браузер", "Yandex/YandexBrowser", "ru.yandex.desktop.yandex-browser")]
        func told(_ domain: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: managed.appendingPathComponent(domain + ".plist")) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        var found: [String] = []
        for (name, folder, domain) in chromium {
            if told(domain)?["DnsOverHttpsMode"] as? String == "off" { continue }
            let file = support.appendingPathComponent(folder).appendingPathComponent("Local State")
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 8_388_608,
                  let data = try? Data(contentsOf: file), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let settings = root["dns_over_https"] as? [String: Any], settings["mode"] as? String == "secure" else { continue }
            found.append(name)
        }
        if (told("org.mozilla.firefox")?["DNSOverHTTPS"] as? [String: Any])?["Enabled"] as? Bool != false {
            let profiles = support.appendingPathComponent("Firefox/Profiles")
            for profile in (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? [] {
                let file = profile.appendingPathComponent("prefs.js")
                guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 8_388_608,
                      let text = try? String(contentsOf: file, encoding: .utf8),
                      text.range(of: #"user_pref\("network\.trr\.mode",\s*[23]\)"#, options: .regularExpression) != nil else { continue }
                found.append("Firefox"); break
            }
        }
        return found
    }

    /// Whether the browsers were told by this program's profile.
    public static func browsersTold(managed: URL) -> Bool {
        guard let data = try? Data(contentsOf: managed.appendingPathComponent("com.google.Chrome.plist")),
              let settings = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
        return settings["DnsOverHttpsMode"] as? String == "off"
    }

    /// A configuration profile with one IKEv2 service for this device. The
    /// device names itself in the managed domain, so the server offers it the
    /// virtual subnet alone and the system routes nothing else into the tunnel.
    /// `full`: the device sends everything into the tunnel. It then names
    /// itself plainly and the server offers it what any VPN user gets.
    public static func vpnProfile(policy: ClientPolicy, password: String, identifier: UUID, serviceIdentifier: UUID, full: Bool = false) throws -> Data {
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
                        <key>LocalIdentifier</key><string>\(full ? policy.id : policy.id + "@" + managedDomain)</string>
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
