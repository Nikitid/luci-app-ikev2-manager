import Foundation

/// Public connection details only; never credentials or invitation links.
public struct ConnectionAddresses: Codable, Sendable, Equatable {
    public var server: String
    public var serverIP: String
    public var services: String
    public var tunnel: String
    public init(server: String, serverIP: String, services: String, tunnel: String) {
        self.server = server; self.serverIP = serverIP; self.services = services; self.tunnel = tunnel
    }
    private static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part), String(octet) == part else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }
    static func validNetwork(_ text: String) -> Bool {
        if text.isEmpty { return true }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (1...32).contains(prefix),
              String(prefix) == parts[1], let address = ipv4(String(parts[0])) else { return false }
        let mask = UInt32.max << (32 - prefix)
        return address & mask == address
    }
}
