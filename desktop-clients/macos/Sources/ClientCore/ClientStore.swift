import Foundation

public enum StoreError: Error { case unsafe, invalid }

/// What the device keeps between runs. Everything lives in one directory that
/// only its owner may enter; each file is replaced whole, never edited.
public struct Registration: Sendable, Equatable {
    public var endpoint: URL
    public var deviceToken: String
    /// Present only until the router has accepted the claim.
    public var invitation: String?
    public var id: String?
    public var password: String?
    public var policy: Data?
    public var profile: UUID
    public var profileService: UUID

    public var complete: Bool { policy != nil && password != nil && id != nil }
}

public struct ClientStore: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try verifyDirectory()
    }

    private func verifyDirectory() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw StoreError.unsafe }
    }

    private func read(_ name: String, limit: Int) throws -> Data? {
        try verifyDirectory()
        let path = directory.appendingPathComponent(name).path
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= limit,
              let data = FileManager.default.contents(atPath: path) else { throw StoreError.unsafe }
        return data
    }

    private func write(_ name: String, _ data: Data) throws {
        try verifyDirectory()
        let staged = directory.appendingPathComponent(name + "." + UUID().uuidString + ".new").path
        let descriptor = open(staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StoreError.unsafe }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let flushed = fsync(descriptor) == 0
        close(descriptor)
        guard written == data.count, flushed, rename(staged, directory.appendingPathComponent(name).path) == 0 else {
            unlink(staged)
            throw StoreError.unsafe
        }
    }

    public func loadRegistration() throws -> Registration? {
        guard let data = try read("enrollment.json", limit: 2_097_152) else { return nil }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == 1, let endpoint = (root["endpoint"] as? String).flatMap(URL.init(string:)),
              let token = root["device_token"] as? String, DeviceTransport.matches(token, DeviceTransport.token),
              let profile = (root["profile"] as? String).flatMap(UUID.init(uuidString:)),
              let service = (root["profile_service"] as? String).flatMap(UUID.init(uuidString:))
        else { throw StoreError.invalid }
        _ = try DeviceTransport.endpoint(endpoint, path: "/client/v1/policy")
        let policy = (root["policy"] as? String).flatMap { Data(base64Encoded: $0) }
        if let policy { _ = try ClientPolicy(data: policy) }
        return Registration(endpoint: endpoint, deviceToken: token, invitation: root["invitation"] as? String,
                            id: root["id"] as? String, password: root["password"] as? String, policy: policy,
                            profile: profile, profileService: service)
    }

    public func save(_ registration: Registration) throws {
        var root: [String: Any] = ["version": 1, "endpoint": registration.endpoint.absoluteString,
                                   "device_token": registration.deviceToken, "profile": registration.profile.uuidString,
                                   "profile_service": registration.profileService.uuidString]
        if let value = registration.invitation { root["invitation"] = value }
        if let value = registration.id { root["id"] = value }
        if let value = registration.password { root["password"] = value }
        if let value = registration.policy { root["policy"] = value.base64EncodedString() }
        try write("enrollment.json", JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]))
    }

    public func loadHistory() throws -> PolicyHistory? {
        guard let data = try read("policy.json", limit: 2_097_152) else { return nil }
        return try PolicyHistory(restoring: data)
    }

    /// A stored history is only ever replaced by one that continues it.
    public func save(_ history: PolicyHistory) throws {
        if let previous = try loadHistory(), try previous.proposing(history.current).export() != (try history.export()) {
            throw StoreError.invalid
        }
        try write("policy.json", history.export())
    }

    public func loadIntent() throws -> Bool {
        guard let data = try read("connection.json", limit: 64) else { return false }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == 1, let wanted = root["wanted"] as? Bool else { throw StoreError.invalid }
        return wanted
    }

    public func saveIntent(_ wanted: Bool) throws {
        try write("connection.json", Data(#"{"version":1,"wanted":\#(wanted)}"#.utf8))
    }

    /// Uninstallation only: forget the device.
    public func erase() throws {
        try verifyDirectory()
        try FileManager.default.removeItem(at: directory)
    }
}
