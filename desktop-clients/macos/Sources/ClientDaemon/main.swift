import ClientCore
import Foundation

// The privileged half of the client. It owns the stored device, the names,
// the packet-filter rules and the connection; the window only asks.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ikev2-manager-clientd: " + message + "\n").utf8))
    exit(1)
}

struct Options {
    var stateDirectory = "/Library/Application Support/IKEv2ManagerClient"
    var socketPath = Control.socketPath
    var dryDirectory: String?
    var anchorPath: String?
    var remove = false

    init(_ input: [String]) {
        var arguments = input
        func value(_ name: String) -> String {
            if arguments.isEmpty { fail(name + " needs a value") }
            return arguments.removeFirst()
        }
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--remove": remove = true
            case "--state-dir": stateDirectory = value(argument)
            case "--socket": socketPath = value(argument)
            case "--dry-system": dryDirectory = value(argument)
            case "--test-anchor": anchorPath = value(argument)
            default: fail("unknown argument")
            }
        }
    }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))
let stateDirectory = options.stateDirectory, socketPath = options.socketPath
let dryDirectory = options.dryDirectory, anchorPath = options.anchorPath, remove = options.remove
if dryDirectory == nil, geteuid() != 0 { fail("the daemon runs as root; use --dry-system for an unprivileged trial") }
// A test trust anchor never reaches the real system: it exists only together
// with the dry system and never for root.
if anchorPath != nil, dryDirectory == nil || geteuid() == 0 { fail("--test-anchor is for an unprivileged dry run only") }

var anchor: Data?
if let anchorPath {
    guard let pem = try? String(contentsOfFile: anchorPath, encoding: .utf8) else { fail("unreadable test anchor") }
    let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    guard let der = Data(base64Encoded: body) else { fail("invalid test anchor") }
    anchor = der
}
let system: any SystemActions = dryDirectory.map { DrySystem(directory: URL(fileURLWithPath: $0)) } ?? RealSystem()
guard let store = try? ClientStore(directory: URL(fileURLWithPath: stateDirectory)) else { fail("the state directory is not private to this user") }
let release = ProcessInfo.processInfo.operatingSystemVersion
// The window and the daemon are installed together; the window's bundle
// carries the version both were built as.
let installed = (NSDictionary(contentsOfFile: "/Applications/Waypoint.app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? ""
let about = DeviceTransport.describe(host: ProcessInfo.processInfo.hostName,
    system: "macOS \(release.majorVersion).\(release.minorVersion).\(release.patchVersion)", version: installed)
let runtime = ClientRuntime(store: store, system: system, transport: DeviceTransport(additionalAnchor: anchor, about: about), about: about)

if remove {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var left: [String] = []
    // Detached: the main thread is about to wait and must not be asked to run this.
    Task.detached {
        do { left = try await runtime.remove().failed.map(\.rawValue) } catch { left = ["registration"] }
        done.signal()
    }
    done.wait()
    unlink(socketPath)
    if !left.isEmpty { FileHandle.standardError.write(Data(("not removed: " + left.joined(separator: ", ") + "\n").utf8)) }
    exit(left.isEmpty ? 0 : 1)
}

signal(SIGPIPE, SIG_IGN)
guard let server = try? ControlServer(path: socketPath, runtime: runtime) else { fail("the control socket is unavailable") }
server.start()
// A step that has not finished in a minute is stalled: it is written down and
// the daemon exits, and launchd (KeepAlive) starts it again.
let watchdog = TickWatchdog { seconds in
    try? store.appendFault(FaultEvent(code: "tick_stalled", phase: "tick", at: Int(Date().timeIntervalSince1970)))
    FileHandle.standardError.write(Data("ikev2-manager-clientd: step stalled for \(Int(seconds)) s, restarting\n".utf8))
    exit(75)
}
// The timer lives in ClientCore, outside the main actor this file runs on.
watchdog.watch(every: 5)
let power = PowerWatch(runtime: runtime)
if dryDirectory == nil {
    SystemInstaller.clear()
    let updater = Updater(key: ReleaseKey.pem.flatMap(ReleaseVerifier.key), installer: SystemInstaller(),
                          directory: URL(fileURLWithPath: stateDirectory).appendingPathComponent("updates"), ownVersion: installed,
                          failed: { code in try? store.appendFault(FaultEvent(code: "update_signature", phase: "update", at: Int(Date().timeIntervalSince1970))) })
    Task { await runtime.attach(updater) }
}
Task {
    while true {
        watchdog.begin()
        await runtime.tick()
        watchdog.end()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
}
dispatchMain()
