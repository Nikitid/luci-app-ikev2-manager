import CryptoKit
import Foundation

/// The release list the clients trust (docs/DEVELOPMENT.md, "Signed client
/// release list"): `Waypoint-SHA256SUMS`, signed with the client release key,
/// ECDSA P-256 over SHA-256, DER. A file is installed only if its name is in
/// the verified list and its SHA-256 is the one listed.
public enum ReleaseVerifier {
    public enum Failure: String, Error, Sendable { case noKey, noSignature, badSignature, notListed, digestMismatch, wrongVersion }

    public static func key(pem: String) -> P256.Signing.PublicKey? { try? P256.Signing.PublicKey(pemRepresentation: pem) }

    public static func verify(list: Data, signature: Data?, key: P256.Signing.PublicKey?, name: String, file: Data) throws {
        guard let key else { throw Failure.noKey }
        guard let signature, !signature.isEmpty else { throw Failure.noSignature }
        guard let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature), key.isValidSignature(parsed, for: list)
        else { throw Failure.badSignature }
        let digest = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
        var listed: String?
        for line in String(decoding: list, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            if parts[1].trimmingCharacters(in: .whitespaces) == name { listed = String(parts[0]) }
        }
        guard let listed else { throw Failure.notListed }
        guard listed == digest else { throw Failure.digestMismatch }
    }

    /// The version a component package says it installs, from its PackageInfo.
    public static func packageVersion(packageInfo: String) -> String? {
        guard let tag = packageInfo.range(of: "<pkg-info[^>]*>", options: .regularExpression).map({ String(packageInfo[$0]) }),
              let value = tag.range(of: #"version="([0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4})""#, options: .regularExpression)
        else { return nil }
        return String(tag[value].dropFirst(9).dropLast())
    }
}

/// Where an update stands, for the line on Overview.
public struct UpdateState: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case available, ready, installing, failed }
    public var version: String
    public var phase: Phase
    /// Why the last attempt failed, as a code.
    public var failure: String?
    public var retryAt: Int?
    public init(version: String, phase: Phase, failure: String? = nil, retryAt: Int? = nil) {
        self.version = version; self.phase = phase; self.failure = failure; self.retryAt = retryAt
    }
}

/// Downloads from the project's release page; the address is built here, the
/// router names only the version.
public protocol UpdateSource: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public protocol PackageInstaller: Sendable {
    /// PackageInfo of the package at this file.
    func packageInfo(_ file: URL) throws -> String
    /// Starts the installation outside the daemon's own job; it restarts the daemon.
    func install(_ file: URL) throws
}

public struct URLSessionUpdateSource: UpdateSource {
    public init() {}
    public func fetch(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 600
        let (data, response) = try await URLSession(configuration: configuration).data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Checks for a newer version, fetches and verifies it, and installs it only
/// when the tunnel is not needed: when access is off, at night, when the
/// person quits Waypoint, or at once when they press "Update". A file that
/// fails the check is never installed; the failure is reported and tried
/// again in six hours.
public actor Updater {
    public static let base = "https://github.com/Nikitid/luci-app-ikev2-manager/releases/download"
    public static let retry: TimeInterval = 6 * 3600

    private let key: P256.Signing.PublicKey?
    private let source: any UpdateSource
    private let installer: any PackageInstaller
    private let directory: URL
    private let own: String
    private let failed: @Sendable (String) -> Void
    public private(set) var state: UpdateState?
    private var prepared: URL?

    public init(key: P256.Signing.PublicKey?, source: any UpdateSource = URLSessionUpdateSource(), installer: any PackageInstaller,
                directory: URL, ownVersion: String, failed: @escaping @Sendable (String) -> Void = { _ in }) {
        self.key = key; self.source = source; self.installer = installer; self.directory = directory; self.own = ownVersion; self.failed = failed
    }

    public static func night(_ date: Date, calendar: Calendar = .current) -> Bool { (2..<5).contains(calendar.component(.hour, from: date)) }

    /// One look. WHEN: "auto" (the person lets it install by itself),
    /// "quit" (the program is quitting), "now" (the button).
    public func consider(release: String, now: Date, tunnelNeeded: Bool, auto: Bool, now force: Bool = false, quitting: Bool = false) async {
        guard ClientStatusReport.newer(release, than: own) else { state = nil; prepared = nil; return }
        if state?.version != release { state = UpdateState(version: release, phase: .available); prepared = nil }
        if state?.phase == .failed, let retry = state?.retryAt, now.timeIntervalSince1970 < Double(retry), !force { return }
        if state?.phase == .installing { return }
        let quiet = !tunnelNeeded || Self.night(now) || quitting
        guard force || (auto && quiet) else { return }
        if prepared == nil { await prepare(release, now: now) }
        guard let file = prepared else { return }
        do {
            state?.phase = .installing
            try installer.install(file)
        } catch {
            fail("install_failed", now: now)
        }
    }

    private func prepare(_ release: String, now: Date) async {
        let name = "Waypoint-\(release).pkg"
        guard let folder = URL(string: "\(Self.base)/v\(release)/") else { return }
        do {
            let list = try await source.fetch(folder.appendingPathComponent("Waypoint-SHA256SUMS"))
            let signature = try? await source.fetch(folder.appendingPathComponent("Waypoint-SHA256SUMS.sig"))
            let package = try await source.fetch(folder.appendingPathComponent(name))
            try ReleaseVerifier.verify(list: list, signature: signature, key: key, name: name, file: package)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: file)
            guard FileManager.default.createFile(atPath: file.path, contents: package, attributes: [.posixPermissions: 0o600])
            else { throw ReleaseVerifier.Failure.digestMismatch }
            guard ReleaseVerifier.packageVersion(packageInfo: try installer.packageInfo(file)) == release else {
                try? FileManager.default.removeItem(at: file)
                throw ReleaseVerifier.Failure.wrongVersion
            }
            prepared = file
            state = UpdateState(version: release, phase: .ready)
        } catch let failure as ReleaseVerifier.Failure {
            fail(failure.rawValue, now: now)
        } catch {
            // Not reachable: no failure of the program; tried again later.
            state = UpdateState(version: release, phase: .available, retryAt: Int(now.timeIntervalSince1970 + 3600))
        }
    }

    private func fail(_ code: String, now: Date) {
        state = UpdateState(version: state?.version ?? "", phase: .failed, failure: code, retryAt: Int(now.timeIntervalSince1970 + Self.retry))
        prepared = nil
        failed(code)
    }
}
