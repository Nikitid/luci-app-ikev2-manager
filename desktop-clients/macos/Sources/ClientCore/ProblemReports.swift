import Foundation

/// Problem reports from this device to the developer's report service.
///
/// A report carries what the person wrote, an optional address for a reply
/// and, if they ask, the same state report the window shows. Each report has
/// its own random claim token: it opens that report's status and the replies
/// to it and nothing else. The client ID and the claim are kept before the
/// first request, so a send that was cut off is taken up again and returns the
/// same report instead of a second one.
public struct ProblemReport: Codable, Equatable, Sendable {
    public var clientID: String
    public var claim: String
    public var title: String
    public var sent: Date
    public var reportID: String?
    public var finished: Bool

    public static func fresh(title: String, now: Date = Date()) -> ProblemReport {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no random source")
        let claim = bytes.map { String(format: "%02x", $0) }.joined()
        return ProblemReport(clientID: UUID().uuidString.lowercased(), claim: claim,
                             title: String(title.split(separator: "\n").first ?? "").prefix(120).description,
                             sent: now, reportID: nil, finished: false)
    }
}

/// What the service says of a report now, and what was written back.
public struct ProblemReportState: Equatable, Sendable {
    public var state: String?
    public var replies: [String]
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

    /// Sends REPORT, as created by `ProblemReport.fresh`, with the person's
    /// text, contact and context, and ATTACHMENT when given. `progress` is
    /// called with the report each time it learns more, so the caller can
    /// keep it before the next step. Returns the report as finished.
    public func send(_ report: ProblemReport, description: String, contact: String, context: [String: String],
                     attachment: Data?, progress: @Sendable (ProblemReport) -> Void) async throws -> ProblemReport {
        var report = report
        var create: [String: Any] = ["project": Self.project, "client_id": report.clientID, "claim_token": report.claim,
                                     "description": description, "context": context]
        if !contact.isEmpty { create["contact"] = contact }
        // Without a file the report is submitted in this one request.
        if attachment == nil { create["submit"] = true }
        let (status, data) = try await call("POST", "api/v1/reports", claim: report.claim, json: create)
        guard status == 200 || status == 201 else { throw Self.fail(status, data) }
        guard let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { throw ProblemReportError.refused(status, "no_report_id") }
        report.reportID = id
        progress(report)
        if let attachment {
            let sum = SHA256Hex.of(attachment)
            let (s1, d1) = try await call("POST", "api/v1/reports/\(id)/attachments", claim: report.claim,
                                          json: ["filename": "waypoint-state.json", "content_type": "application/json",
                                                 "size": attachment.count, "sha256": sum])
            guard s1 == 200 || s1 == 201 else { throw Self.fail(s1, d1) }
            guard let file = ((try? JSONSerialization.jsonObject(with: d1)) as? [String: Any])?["id"] as? String,
                  file.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
            else { throw ProblemReportError.refused(s1, "no_attachment_id") }
            // Created once; a creation that already happened answers 409.
            let (s2, d2) = try await call("POST", "api/v1/uploads/", claim: report.claim,
                                          headers: ["Tus-Resumable": "1.0.0", "Upload-Length": String(attachment.count),
                                                    "Upload-Metadata": "attachment_id " + Data(file.utf8).base64EncodedString()])
            guard s2 == 201 || s2 == 409 else { throw Self.fail(s2, d2) }
            let (s3, d3) = try await call("PATCH", "api/v1/uploads/\(file)", claim: report.claim, raw: attachment,
                                          headers: ["Tus-Resumable": "1.0.0", "Upload-Offset": "0",
                                                    "Content-Type": "application/offset+octet-stream"])
            guard s3 == 204 || s3 == 409 else { throw Self.fail(s3, d3) }
            let (s4, d4) = try await call("POST", "api/v1/reports/\(id)/finalize", claim: report.claim, json: [:])
            guard s4 == 200 || s4 == 201 else { throw Self.fail(s4, d4) }
        }
        report.finished = true
        progress(report)
        return report
    }

    /// What the service says of a sent report and the replies to it.
    public func state(of report: ProblemReport) async -> ProblemReportState? {
        guard let id = report.reportID,
              let (status, data) = try? await call("GET", "api/v1/reports/\(id)", claim: report.claim), status == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let replies = (object["replies"] as? [[String: Any]] ?? []).compactMap { $0["body"] as? String }
        return ProblemReportState(state: object["state"] as? String, replies: replies)
    }
}

/// The reports this person sent from this Mac, kept with the claim that reads
/// them, readable by this user only.
public struct ProblemReportBook: Sendable {
    let file: URL
    public init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Waypoint/reports.json")) {
        self.file = file
    }
    public func load() -> [ProblemReport] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([ProblemReport].self, from: data)) ?? []
    }
    public func keep(_ report: ProblemReport) {
        var all = load().filter { $0.clientID != report.clientID }
        all.insert(report, at: 0)
        guard let data = try? JSONEncoder().encode(Array(all.prefix(20))) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

import CryptoKit
enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
