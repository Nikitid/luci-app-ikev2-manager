import ClientCore
import Foundation

/// Installs a verified package. The package's own scripts stop and start the
/// daemon, so the installer runs as a one-off launchd job of its own and not
/// as a child of the daemon, which would be stopped with it.
struct SystemInstaller: PackageInstaller {
    static let label = "io.github.nikitid.ikev2-manager-client.update"
    static let plist = "/Library/LaunchDaemons/\(label).plist"

    func packageInfo(_ file: URL) throws -> String {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-pkg-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        guard try Tool.run("/usr/bin/xar", ["-x", "-f", file.path, "-C", work.path, "PackageInfo"]).status == 0 else { throw StoreError.invalid }
        return try String(contentsOf: work.appendingPathComponent("PackageInfo"), encoding: .utf8)
    }

    func install(_ file: URL) throws {
        Self.clear()
        let job: [String: Any] = ["Label": Self.label, "ProgramArguments": ["/usr/sbin/installer", "-pkg", file.path, "-target", "/"],
                                  "RunAtLoad": true, "LaunchOnlyOnce": true]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        guard FileManager.default.createFile(atPath: Self.plist, contents: data, attributes: [.posixPermissions: 0o644]) else { throw StoreError.unsafe }
        guard try Tool.run("/bin/launchctl", ["bootstrap", "system", Self.plist]).status == 0 else { throw StoreError.unsafe }
    }

    /// The job of the last update, once the new daemon runs.
    static func clear() {
        _ = try? Tool.run("/bin/launchctl", ["bootout", "system/" + label])
        unlink(plist)
    }
}
