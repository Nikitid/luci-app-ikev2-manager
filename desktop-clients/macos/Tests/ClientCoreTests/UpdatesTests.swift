import CryptoKit
import Foundation
import Testing
@testable import ClientCore

/// A release page made up in the test, signed with a throwaway key.
private final class Page: UpdateSource, @unchecked Sendable {
    var files: [String: Data] = [:]
    var asked: [String] = []
    func fetch(_ url: URL) async throws -> Data {
        asked.append(url.lastPathComponent)
        guard let data = files[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

private final class Installer: PackageInstaller, @unchecked Sendable {
    var version = "3.0.1", installed: [URL] = []
    func packageInfo(_ file: URL) throws -> String {
        #"<?xml version="1.0"?><pkg-info format-version="2" identifier="io.github.nikitid.ikev2-manager-client" version="\#(version)" install-location="/" auth="root"></pkg-info>"#
    }
    func install(_ file: URL) throws { installed.append(file) }
}

private let signer = P256.Signing.PrivateKey()
private let package = Data("the package".utf8)

private func page(list: String? = nil, signature: Data? = nil, packageData: Data = package) -> Page {
    let page = Page()
    let text = list ?? SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined() + "  Waypoint-3.0.1.pkg\n"
    page.files["Waypoint-SHA256SUMS"] = Data(text.utf8)
    page.files["Waypoint-SHA256SUMS.sig"] = signature ?? (try! signer.signature(for: Data(text.utf8)).derRepresentation)
    page.files["Waypoint-3.0.1.pkg"] = packageData
    return page
}

private func updater(_ page: Page, _ installer: Installer, key: P256.Signing.PublicKey? = signer.publicKey, failures: Failures = Failures()) -> Updater {
    Updater(key: key, source: page, installer: installer,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("updates-" + UUID().uuidString),
            ownVersion: "3.0.0", failed: { code in failures.add(code) })
}

private final class Failures: @unchecked Sendable {
    let lock = NSLock(); var codes: [String] = []
    func add(_ code: String) { lock.lock(); codes.append(code); lock.unlock() }
}

private let day = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15, daytime in most zones

@Test(arguments: ["no_signature", "foreign", "other_file", "other_version", "no_key"])
func aPackageThatFailsTheCheckIsNeverInstalled(_ case: String) async {
    let installer = Installer(), failures = Failures()
    var source = page()
    var key: P256.Signing.PublicKey? = signer.publicKey
    switch `case` {
    case "no_signature": source.files["Waypoint-SHA256SUMS.sig"] = nil
    case "foreign": source = page(signature: try! P256.Signing.PrivateKey().signature(for: source.files["Waypoint-SHA256SUMS"]!).derRepresentation)
    case "other_file": source.files["Waypoint-3.0.1.pkg"] = Data("another package".utf8)
    case "other_version": installer.version = "2.9.0"
    default: key = nil
    }
    let update = updater(source, installer, key: key, failures: failures)
    await update.consider(release: "3.0.1", now: day, tunnelNeeded: false, auto: true, now: true)
    #expect(installer.installed.isEmpty, "\(`case`)")
    let state = await update.state
    #expect(state?.phase == .failed && state?.retryAt == Int(day.timeIntervalSince1970) + 6 * 3600)
    #expect(failures.codes.count == 1, "a failed check is reported")
    // Not again before six hours.
    let asked = source.asked.count
    await update.consider(release: "3.0.1", now: day + 3600, tunnelNeeded: false, auto: true)
    #expect(source.asked.count == asked)
}

@Test func aVerifiedPackageWaitsUntilTheTunnelIsNotNeeded() async {
    let installer = Installer(), source = page()
    let update = updater(source, installer)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
    await update.consider(release: "3.0.1", now: noon, tunnelNeeded: true, auto: true)
    #expect(installer.installed.isEmpty && source.asked.isEmpty, "in the working day with the tunnel on nothing is fetched or installed")
    await update.consider(release: "3.0.1", now: noon, tunnelNeeded: true, auto: false, now: true)
    #expect(installer.installed.count == 1, "the button installs at once")
    #expect(await update.state?.phase == .installing)

    let other = Installer()
    let quiet = updater(page(), other)
    await quiet.consider(release: "3.0.1", now: noon, tunnelNeeded: false, auto: true)
    #expect(other.installed.count == 1, "with access off it installs by itself")
    let off = Installer()
    let manual = updater(page(), off)
    await manual.consider(release: "3.0.1", now: noon, tunnelNeeded: false, auto: false)
    #expect(off.installed.isEmpty, "with self-install switched off only the button installs")
    let night = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: day)!
    let late = Installer()
    await updater(page(), late).consider(release: "3.0.1", now: night, tunnelNeeded: true, auto: true)
    #expect(late.installed.count == 1, "at night it installs by itself")
    let older = Installer()
    await updater(page(), older).consider(release: "2.9.9", now: night, tunnelNeeded: false, auto: true, now: true)
    #expect(older.installed.isEmpty)
}

@Test func packageInfoNamesItsVersion() {
    #expect(ReleaseVerifier.packageVersion(packageInfo: #"<pkg-info format-version="2" identifier="x" version="3.0.1" auth="root">"#) == "3.0.1")
    #expect(ReleaseVerifier.packageVersion(packageInfo: "<pkg-info identifier=\"x\">") == nil)
}
