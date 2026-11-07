import Foundation

/// Failures of Waypoint itself, reported to the developer by the program on
/// its own (`fixtures/status-codes.json`, `auto_report`). Nothing goes before
/// the person has answered the question once and said yes; until then
/// failures wait here. The environment is never reported: only the codes the
/// table lists for macOS are taken.
public struct AutoReportQueue: Codable, Sendable, Equatable {
    public static let reportable: Set<String> = ["app_crash", "daemon_crash", "internal", "guard_unconfirmed", "tick_stalled",
                                                 "reset_incomplete", "needs_reset", "policy_mismatch", "profile_loop", "update_signature"]
    public static let queueLimit = 20, keepDays = 7.0, perDevicePerDay = 5
    public static let afterEvent: TimeInterval = 60, afterLaunch: TimeInterval = 10, day: TimeInterval = 86_400

    public struct Pending: Codable, Sendable, Equatable {
        public var code: String
        public var phase: String
        public var appVersion: String
        public var firstAt: Date
        public var occurrences: Int
        /// A crash report found for it, cleaned, as a file to attach.
        public var crashLog: String?
        public var fingerprint: String { code + "|" + phase + "|" + appVersion }
    }

    public struct Sent: Codable, Sendable, Equatable {
        public var fingerprint: String
        public var reportID: String
        public var claim: String
        public var sentAt: Date
        /// Repeats since the report or its last message.
        public var repeats: Int
        public var toldAt: Date
    }

    public var pending: [Pending] = []
    public var sent: [Sent] = []
    /// When each automatic report of the last day went: at most five a day.
    public var sentTimes: [Date] = []
    public var notBefore: Date?
    /// The newest fault of the daemon already taken, and the newest crash report.
    public var daemonFaultsSeen = 0
    public var crashLogsSeen = Date.distantPast

    public init() {}

    /// One failure. Codes the table does not list are not failures of the program.
    public mutating func record(code: String, phase: String, appVersion: String, at: Date, crashLog: String? = nil) {
        guard Self.reportable.contains(code) else { return }
        let item = Pending(code: code, phase: phase, appVersion: appVersion, firstAt: at, occurrences: 1, crashLog: crashLog)
        // One report a day per fingerprint: a repeat is counted against it.
        if let index = sent.firstIndex(where: { $0.fingerprint == item.fingerprint && at.timeIntervalSince($0.sentAt) < Self.day * 7 }) {
            sent[index].repeats += 1
            return
        }
        if let index = pending.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            pending[index].occurrences += 1
            return
        }
        pending.append(item)
        prune(at)
    }

    mutating func prune(_ now: Date) {
        pending.removeAll { now.timeIntervalSince($0.firstAt) > Self.keepDays * Self.day }
        if pending.count > Self.queueLimit { pending.removeFirst(pending.count - Self.queueLimit) }
        sent.removeAll { now.timeIntervalSince($0.sentAt) > Self.keepDays * Self.day && $0.repeats == 0 }
        sentTimes.removeAll { now.timeIntervalSince($0) >= Self.day }
    }

    public enum Action: Equatable, Sendable {
        case report(Pending)
        case repeats(Sent)
    }

    /// What may go now. Nothing without consent, in the first seconds after
    /// launch, inside a minute of the failure (so the outcome of mending it is
    /// known), past the service's Retry-After, or beyond five reports a day.
    public mutating func due(now: Date, launchedAt: Date, consent: Bool?) -> [Action] {
        prune(now)
        guard consent == true, now.timeIntervalSince(launchedAt) >= Self.afterLaunch, (notBefore ?? .distantPast) <= now else { return [] }
        var actions: [Action] = []
        var budget = Self.perDevicePerDay - sentTimes.count
        for item in pending where now.timeIntervalSince(item.firstAt) >= Self.afterEvent && budget > 0 {
            actions.append(.report(item)); budget -= 1
        }
        for item in sent where item.repeats > 0 && now.timeIntervalSince(item.toldAt) >= Self.day {
            actions.append(.repeats(item))
        }
        return actions
    }

    public mutating func reported(_ item: Pending, id: String, claim: String, at: Date) {
        pending.removeAll { $0.fingerprint == item.fingerprint }
        sent.removeAll { $0.fingerprint == item.fingerprint }
        sent.append(Sent(fingerprint: item.fingerprint, reportID: id, claim: claim, sentAt: at, repeats: 0, toldAt: at))
        sentTimes.append(at)
    }

    public mutating func told(_ fingerprint: String, at: Date) {
        guard let index = sent.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        sent[index].repeats = 0; sent[index].toldAt = at
    }

    /// The person said no, or switched reports off: nothing waits any more.
    public mutating func clear() { pending = []; sent = []; notBefore = nil }
}

/// The file that goes with an automatic report, made from a list of what may
/// go, never by striking out what may not: a field added to the status later
/// does not get in by itself. No name, address, service, domain or network.
public enum FaultFile {
    public static let keys: Set<String> = ["version", "state", "cause", "visible", "guard_installed", "profile_installed", "routed",
                                           "protected", "wanted", "mode", "services_on", "services_offered", "domains", "networks",
                                           "own_entries", "policy_revision", "router_release", "app_version", "faults", "warnings"]
    public static let limit = 32_768

    public static func make(status: ClientStatusReport?, faults: [FaultEvent], appVersion: String, now: Date) -> Data {
        var body: [String: Any] = ["version": 1, "app_version": appVersion]
        if let status {
            let entries = status.entries ?? []
            body["state"] = status.state
            body["cause"] = status.error
            body["visible"] = status.visible ?? StatusView.visible(state: status.state, error: status.error)
            body["guard_installed"] = status.guardInstalled
            body["profile_installed"] = status.profileInstalled
            body["routed"] = status.routed
            body["protected"] = status.protected
            body["wanted"] = status.wanted
            body["mode"] = status.fullTunnel ? "full" : "services"
            body["services_on"] = entries.isEmpty ? status.services.count : entries.filter(\.on).count
            body["services_offered"] = entries.count
            body["domains"] = status.domains
            body["networks"] = entries.reduce(0) { $0 + $1.cidrs.count }
            body["own_entries"] = (status.own?.domains.count ?? 0) + (status.own?.networks.count ?? 0)
            body["policy_revision"] = status.revision
            if status.release.range(of: #"\A[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}\z"#, options: .regularExpression) != nil { body["router_release"] = status.release }
            body["warnings"] = (status.warnings ?? []).filter { ["vpn", "proxy"].contains($0) }
        }
        let codes = Set(StatusCodes.causes.values.flatMap { $0 }).union(AutoReportQueue.reportable).union(["guard_restored"])
        body["faults"] = faults.suffix(FaultEvent.limit).filter { codes.contains($0.code) }.map {
            ["code": $0.code, "phase": $0.phase, "seconds_ago": max(0, Int(now.timeIntervalSince1970) - $0.at)] as [String: Any]
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
}

/// A crash report of the program or the daemon, made safe to send: the home
/// directory is "~", the keys that identify the machine or its boot are gone;
/// threads and binary images stay so it can be symbolicated. Over 1 MiB only
/// the thread that crashed is kept.
public enum CrashLog {
    public static let limit = 1_048_576
    static let removed: Set<String> = ["crashReporterKey", "sleepWakeUUID", "bootSessionUUID", "deviceIdentifierForVendor",
                                       "userID", "uuid_ownerName", "hostname", "computerName"]

    public static func clean(_ data: Data) -> Data? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: #"/Users/[^/"\\\s]+"#, with: "~", options: .regularExpression)
        // An .ips file is a header line of JSON, then a body of JSON.
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let header = object(parts[0]) else { return nil }
        var body = parts.count > 1 ? object(parts[1]) : nil
        func strip(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.filter { !removed.contains($0.key) }.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        var out = serialize(strip(header))
        if let parsed = body {
            body = strip(parsed) as? [String: Any]
            var rest = serialize(body ?? [:])
            if out.count + rest.count > limit, var trimmed = body {
                trimmed["threads"] = (trimmed["threads"] as? [[String: Any]])?.filter { $0["triggered"] as? Bool == true }
                rest = serialize(trimmed)
            }
            out += Data("\n".utf8) + rest
        }
        return out.count <= limit ? out : out.prefix(limit)
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
    private static func serialize(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Crash reports of the program or the daemon newer than DATE, oldest first.
    public static func find(in directories: [URL], newerThan date: Date) -> [(url: URL, code: String, at: Date)] {
        var found: [(URL, String, Date)] = []
        for directory in directories {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".ips") {
                let code: String
                if name.hasPrefix("IKEv2ManagerClient") { code = "app_crash" }
                else if name.hasPrefix("ikev2-manager-clientd") || name.hasPrefix("io.github.nikitid.ikev2-manager-client") { code = "daemon_crash" }
                else { continue }
                let url = directory.appendingPathComponent(name)
                guard let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, at > date else { continue }
                found.append((url, code, at))
            }
        }
        return found.sorted { $0.2 < $1.2 }
    }
}

/// Sends what the queue lets go and keeps the queue in a file only this user
/// can read. The program calls it; the daemon only hands over its faults.
public actor AutoReporter {
    private let file: URL
    private let reporter: ProblemReporter
    private let journal: ReportJournal?
    private let about: [String: String]
    private let reporterID: String
    public private(set) var queue: AutoReportQueue

    /// ABOUT: app_version, app_build, os_version, architecture, language.
    public init(file: URL, reporter: ProblemReporter = ProblemReporter(), journal: ReportJournal? = nil,
                about: [String: String], reporterID: String) {
        self.file = file; self.reporter = reporter; self.journal = journal; self.about = about; self.reporterID = reporterID
        queue = (try? JSONDecoder().decode(AutoReportQueue.self, from: Data(contentsOf: file))) ?? AutoReportQueue()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: [.atomic])
        chmod(file.path, 0o600)
    }

    public func record(code: String, phase: String, at: Date, crashLog: String? = nil) {
        queue.record(code: code, phase: phase, appVersion: about["app_version"] ?? "", at: at, crashLog: crashLog)
        save()
    }

    /// The daemon's faults it has not taken yet.
    public func take(daemonFaults: [FaultEvent]) {
        for event in daemonFaults where event.at > queue.daemonFaultsSeen {
            queue.record(code: event.code, phase: event.phase, appVersion: about["app_version"] ?? "",
                         at: Date(timeIntervalSince1970: TimeInterval(event.at)))
            queue.daemonFaultsSeen = event.at
        }
        save()
    }

    /// Crash reports of the program and the daemon newer than the last taken.
    public func takeCrashLogs(in directories: [URL]) {
        for log in CrashLog.find(in: directories, newerThan: queue.crashLogsSeen) {
            let cleaned = (try? Data(contentsOf: log.url)).flatMap(CrashLog.clean).map { String(decoding: $0, as: UTF8.self) }
            queue.record(code: log.code, phase: "", appVersion: about["app_version"] ?? "", at: log.at, crashLog: cleaned)
            queue.crashLogsSeen = log.at
        }
        save()
    }

    /// The person switched reports off: the queue goes.
    public func clear() { queue.clear(); save() }

    /// Sends what is due; how many requests went to the service.
    @discardableResult
    public func send(now: Date, launchedAt: Date, consent: Bool?, status: ClientStatusReport?, faults: [FaultEvent]) async -> Int {
        let actions = queue.due(now: now, launchedAt: launchedAt, consent: consent)
        var count = 0
        for action in actions {
            do {
                switch action {
                case .report(let item):
                    var context = about
                    context["failure_code"] = item.code
                    context["failure_phase"] = item.phase
                    context["fingerprint"] = item.fingerprint
                    context["occurrences"] = String(item.occurrences)
                    context["mode"] = status?.fullTunnel == true ? "full" : "services"
                    var files = [ReportFile(name: "waypoint-fault.json", contentType: "application/json",
                                            data: FaultFile.make(status: status, faults: faults, appVersion: about["app_version"] ?? "", now: now))]
                    if let log = item.crashLog { files.append(ReportFile(name: "waypoint-crash.ips", contentType: "text/plain", data: Data(log.utf8))) }
                    let phase = item.phase.isEmpty ? "—" : item.phase
                    let sent = try await reporter.send(description: "Сбой Waypoint: \(item.code), фаза \(phase)", kind: .crash,
                                                       reporter: reporterID, contact: "", context: context, files: files)
                    count += 1
                    queue.reported(item, id: sent.id, claim: sent.claim, at: now)
                    try? journal?.add(sent)
                case .repeats(let item):
                    let report = SentReport(id: item.reportID, claim: item.claim, kind: .crash, title: "", sentAt: item.sentAt)
                    try await reporter.reply(report, "Ещё \(item.repeats) раз(а) за сутки.")
                    count += 1
                    queue.told(item.fingerprint, at: now)
                }
            } catch ProblemReportError.tooMany(let seconds) {
                queue.notBefore = now.addingTimeInterval(TimeInterval(seconds))
                break
            } catch {
                // Unreachable or refused: it stays queued for the next round.
                break
            }
            save()
        }
        save()
        return count
    }
}
