import Foundation

/// The local conversation between the window and the daemon: one JSON line
/// each way over a Unix socket. Nothing here crosses the machine's boundary.
public enum Control {
    public static let socketPath = "/var/run/ikev2-manager-client.sock"
    public static let limit = 262_144

    public struct Request: Codable, Sendable {
        public var op: String
        public var invitation: String?
        public init(op: String, invitation: String? = nil) { self.op = op; self.invitation = invitation }
    }

    public struct Response: Codable, Sendable {
        public var result: String
        public var status: ClientStatusReport?
        /// The VPN profile, base64, for an administrator only.
        public var profile: String?
        public init(result: String, status: ClientStatusReport? = nil, profile: String? = nil) {
            self.result = result; self.status = status; self.profile = profile
        }
    }

    public enum Failure: Error { case unavailable, invalid }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.invalid }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    public static func readLine(_ descriptor: Int32) -> Data? {
        var data = Data(), byte: UInt8 = 0
        while data.count <= limit {
            let count = read(descriptor, &byte, 1)
            if count <= 0 { return nil }
            if byte == 0x0a { return data }
            data.append(byte)
        }
        return nil
    }

    public static func writeLine(_ descriptor: Int32, _ data: Data) -> Bool {
        var line = data
        line.append(0x0a)
        return line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == line.count
    }

    /// One request, one answer, bounded in size and time.
    public static func send(_ request: Request, socket path: String = socketPath) throws -> Response {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var target = try address(path)
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, writeLine(descriptor, try JSONEncoder().encode(request)),
              let answer = readLine(descriptor) else { throw Failure.unavailable }
        guard let response = try? JSONDecoder().decode(Response.self, from: answer) else { throw Failure.invalid }
        return response
    }
}
