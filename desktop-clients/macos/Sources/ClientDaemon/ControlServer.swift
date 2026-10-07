import ClientCore
import Foundation

/// Answers the window. Any local user may ask for the status and switch the
/// connection; registering the device and reading its VPN profile, which
/// carries the device's credential, is for administrators.
final class ControlServer: @unchecked Sendable {
    private let listener: Int32
    private let runtime: ClientRuntime

    init(path: String, runtime: ClientRuntime) throws {
        self.runtime = runtime
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Control.Failure.unavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Control.Failure.invalid }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o666) == 0, listen(listener, 8) == 0 else { throw Control.Failure.unavailable }
    }

    static func administrator(_ user: uid_t) -> Bool {
        if user == 0 || user == geteuid() { return true }
        guard let entry = getpwuid(user) else { return false }
        var groups = [Int32](repeating: 0, count: 64), count = Int32(64)
        guard getgrouplist(entry.pointee.pw_name, Int32(entry.pointee.pw_gid), &groups, &count) >= 0 else { return false }
        return groups.prefix(Int(count)).contains(80)
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var user: uid_t = 0, group: gid_t = 0
                guard getpeereid(client, &user, &group) == 0, let line = Control.readLine(client),
                      let request = try? JSONDecoder().decode(Control.Request.self, from: line) else { close(client); continue }
                let privileged = Self.administrator(user)
                Task { [runtime] in
                    let response = await Self.answer(request, privileged: privileged, runtime: runtime)
                    if let data = try? JSONEncoder().encode(response) { _ = Control.writeLine(client, data) }
                    close(client)
                }
            }
        }
    }

    static func answer(_ request: Control.Request, privileged: Bool, runtime: ClientRuntime) async -> Control.Response {
        do {
            switch request.op {
            case "status": return Control.Response(result: "ok", status: await runtime.status())
            case "connect": try await runtime.setWanted(true)
            case "disconnect": try await runtime.setWanted(false)
            case "begin":
                guard privileged else { return Control.Response(result: "administrator_required") }
                guard let invitation = request.invitation else { return Control.Response(result: "refused") }
                try await runtime.begin(invitation: invitation)
            case "reset":
                guard privileged else { return Control.Response(result: "administrator_required") }
                try await runtime.reset()
            case "profile":
                guard privileged else { return Control.Response(result: "administrator_required") }
                return Control.Response(result: "ok", profile: try await runtime.profile().base64EncodedString())
            default: return Control.Response(result: "refused")
            }
            await runtime.tick()
            return Control.Response(result: "ok", status: await runtime.status())
        } catch { return Control.Response(result: "refused") }
    }
}
