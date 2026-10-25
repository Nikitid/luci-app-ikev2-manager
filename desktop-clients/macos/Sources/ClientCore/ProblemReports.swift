import Foundation

/// Reports from this device to the developer's report service.
///
/// A report carries its kind, what the person wrote, an optional address for
/// a reply, pictures they pasted and, if they ask, the same state report the
/// window shows. Each report has its own random claim token, which the
/// service takes as the proof that the files, the finishing step and the
/// conversation belong to it; the journal keeps it so the person can read
/// support's answers and reply. A random reporter ID, made once per
/// installation, tells the service that reports come from the same person.
public struct ProblemReport: Equatable, Sendable {
    public var clientID: String
    public var claim: String

    public static func fresh() -> ProblemReport {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no random source")
        return ProblemReport(clientID: UUID().uuidString.lowercased(), claim: bytes.map { String(format: "%02x", $0) }.joined())
    }
}

/// What a report is about, as the person picks it.
public enum ReportKind: String, CaseIterable, Codable, Sendable {
    case bug, feature, question, feedback

    public var label: String {
        switch self {
        case .bug: "Проблема"
        case .feature: "Идея"
        case .question: "Вопрос"
        case .feedback: "Отзыв"
        }
    }
}

/// The reporter ID of this installation: random, made once, kept with the
/// app's settings. Only a keyed hash of it is stored by the service.
public enum ReporterIdentity {
    static let key = "reportReporterID"

    public static func id(_ defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: key), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: key)
        return id
    }
}

/// A report this device sent, as the journal keeps it: enough to show it in
/// a list and to read and continue its conversation.
public struct SentReport: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var claim: String
    public var kind: ReportKind
    /// The first line of what the person wrote, at most 80 characters.
    public var title: String
    public var sentAt: Date
    /// How many of support's replies the person has seen.
    public var seen: Int

    public init(id: String, claim: String, kind: ReportKind, title: String, sentAt: Date, seen: Int = 0) {
        self.id = id; self.claim = claim; self.kind = kind; self.title = title; self.sentAt = sentAt; self.seen = seen
    }

    static func title(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}

/// One message of a report's conversation.
public struct ReportReply: Equatable, Sendable {
    public enum From: String, Sendable { case support, reporter }
    public var from: From
    public var body: String
    public var createdAt: Date?
}

/// Where a report stands and what was said about it.
public struct ReportConversation: Equatable, Sendable {
    /// received, in_progress, resolved or closed.
    public var state: String
    public var replies: [ReportReply]
    public var fromSupport: Int { replies.filter { $0.from == .support }.count }

    public var stateLabel: String {
        switch state {
        case "received": "получено"
        case "in_progress": "в работе"
        case "resolved": "решено"
        case "closed": "закрыто"
        default: "отправляется"
        }
    }
}

/// The reports sent from here, newest first, at most fifty, in a file only
/// this user can read: the claims in it open the conversations.
public struct ReportJournal: Sendable {
    public static let limit = 50
    let file: URL

    public init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Waypoint", isDirectory: true).appendingPathComponent("reports.json")) {
        self.file = file
    }

    public func load() -> [SentReport] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SentReport].self, from: data)) ?? []
    }

    public func save(_ reports: [SentReport]) throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Array(reports.prefix(Self.limit)))
        let temporary = folder.appendingPathComponent(".reports-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    }

    public func add(_ report: SentReport) throws {
        try save([report] + load().filter { $0.id != report.id })
    }

    /// Notes that the person has seen SEEN of support's replies to ID.
    public func markSeen(_ id: String, _ seen: Int) throws {
        var reports = load()
        guard let index = reports.firstIndex(where: { $0.id == id }), reports[index].seen != seen else { return }
        reports[index].seen = seen
        try save(reports)
    }

    public func remove(_ id: String) throws { try save(load().filter { $0.id != id }) }
}

/// A file sent with a report.
public struct ReportFile: Equatable, Sendable {
    public var name: String
    public var contentType: String
    public var data: Data
    public init(name: String, contentType: String, data: Data) {
        self.name = name
        self.contentType = contentType
        self.data = data
    }
}

/// One HTTP exchange, so the protocol can be followed without a network.
public protocol ReportTransport: Sendable {
    func exchange(_ method: String, _ url: URL, headers: [String: String], body: Data?) async throws -> (Int, Data)
}

public struct URLSessionReportTransport: ReportTransport {
    public init() {}
    public func exchange(_ method: String, _ url: URL, headers: [String: String], body: Data?) async throws -> (Int, Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

public enum ProblemReportError: Error, Equatable {
    /// The service does not take this project's reports now.
    case unavailable
    /// Busy: try again in a few minutes.
    case busy
    /// The network or the service did not answer.
    case unreachable
    /// Refused, with the service's code.
    case refused(Int, String)
    /// The service no longer knows the report: expired or removed.
    case gone
}

public struct ProblemReporter: Sendable {
    public static let defaultEndpoint = URL(string: "https://reports.nikitid.ru")!
    public static let project = "waypoint"
    let endpoint: URL
    let transport: ReportTransport

    public init(endpoint: URL = ProblemReporter.defaultEndpoint, transport: ReportTransport = URLSessionReportTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    private func call(_ method: String, _ path: String, claim: String, json: [String: Any]? = nil,
                      raw: Data? = nil, headers: [String: String] = [:]) async throws -> (Int, Data) {
        var all = headers
        all["Authorization"] = "Bearer " + claim
        var body = raw
        if let json {
            body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            all["Content-Type"] = "application/json"
        }
        do {
            return try await transport.exchange(method, endpoint.appendingPathComponent(path), headers: all, body: body)
        } catch {
            throw ProblemReportError.unreachable
        }
    }

    private static func fail(_ status: Int, _ data: Data) -> ProblemReportError {
        let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? ""
        switch status {
        case 404: return .unavailable
        case 429, 503: return .busy
        case 0: return .unreachable
        default: return .refused(status, code)
        }
    }

    /// Sends a fresh report of KIND with the person's text, contact and
    /// context, and FILES in their order, from REPORTER. Returns what the
    /// journal keeps of it.
    public func send(description: String, kind: ReportKind = .bug, reporter: String, contact: String,
                     context: [String: String], files: [ReportFile]) async throws -> SentReport {
        let report = ProblemReport.fresh()
        var create: [String: Any] = ["project": Self.project, "client_id": report.clientID, "claim_token": report.claim,
                                     "description": description, "kind": kind.rawValue, "reporter": ["id": reporter],
                                     "context": context]
        if !contact.isEmpty { create["contact"] = contact }
        // Without files the report is submitted in this one request.
        if files.isEmpty { create["submit"] = true }
        let (status, data) = try await call("POST", "api/v1/reports", claim: report.claim, json: create)
        guard status == 200 || status == 201 else { throw Self.fail(status, data) }
        guard let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { throw ProblemReportError.refused(status, "no_report_id") }
        let sent = SentReport(id: id, claim: report.claim, kind: kind, title: SentReport.title(of: description), sentAt: Date())
        guard !files.isEmpty else { return sent }
        for file in files {
            let (s1, d1) = try await call("POST", "api/v1/reports/\(id)/attachments", claim: report.claim,
                                          json: ["filename": file.name, "content_type": file.contentType,
                                                 "size": file.data.count, "sha256": SHA256Hex.of(file.data)])
            guard s1 == 200 || s1 == 201 else { throw Self.fail(s1, d1) }
            guard let attachment = ((try? JSONSerialization.jsonObject(with: d1)) as? [String: Any])?["id"] as? String,
                  attachment.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
            else { throw ProblemReportError.refused(s1, "no_attachment_id") }
            let (s2, d2) = try await call("POST", "api/v1/uploads/", claim: report.claim,
                                          headers: ["Tus-Resumable": "1.0.0", "Upload-Length": String(file.data.count),
                                                    "Upload-Metadata": "attachment_id " + Data(attachment.utf8).base64EncodedString()])
            guard s2 == 201 else { throw Self.fail(s2, d2) }
            let (s3, d3) = try await call("PATCH", "api/v1/uploads/\(attachment)", claim: report.claim, raw: file.data,
                                          headers: ["Tus-Resumable": "1.0.0", "Upload-Offset": "0",
                                                    "Content-Type": "application/offset+octet-stream"])
            guard s3 == 204 else { throw Self.fail(s3, d3) }
        }
        let (s4, d4) = try await call("POST", "api/v1/reports/\(id)/finalize", claim: report.claim, json: [:])
        guard s4 == 200 || s4 == 201 else { throw Self.fail(s4, d4) }
        return sent
    }

    /// Where REPORT stands and the conversation about it.
    public func conversation(_ report: SentReport) async throws -> ReportConversation {
        let (status, data) = try await call("GET", "api/v1/reports/\(report.id)", claim: report.claim)
        if status == 404 { throw ProblemReportError.gone }
        guard status == 200, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Self.fail(status, data)
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let replies = ((root["replies"] as? [[String: Any]]) ?? []).compactMap { item -> ReportReply? in
            guard let from = (item["from"] as? String).flatMap(ReportReply.From.init(rawValue:)),
                  let body = item["body"] as? String, !body.isEmpty else { return nil }
            let created = (item["created_at"] as? String).flatMap { stamp.date(from: $0) ?? plain.date(from: $0) }
            return ReportReply(from: from, body: body, createdAt: created)
        }
        return ReportConversation(state: root["state"] as? String ?? "", replies: replies)
    }

    /// The person's answer to support on REPORT; it reopens a resolved or
    /// closed report.
    public func reply(_ report: SentReport, _ body: String) async throws {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 5000 else { throw ProblemReportError.refused(400, "invalid_body") }
        let (status, data) = try await call("POST", "api/v1/reports/\(report.id)/messages", claim: report.claim, json: ["body": text])
        if status == 404 { throw ProblemReportError.gone }
        guard status == 200 || status == 201 else { throw Self.fail(status, data) }
    }
}

import CryptoKit
enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
