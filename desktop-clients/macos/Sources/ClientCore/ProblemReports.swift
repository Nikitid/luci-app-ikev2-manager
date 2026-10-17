import Foundation

/// Problem reports from this device to the developer's report service.
///
/// A report carries what the person wrote, an optional address for a reply,
/// pictures they pasted and, if they ask, the same state report the window
/// shows. It is sent and forgotten: nothing of it is kept on this device.
/// Each report has its own random claim token, which the service takes as
/// the proof that the files and the finishing step belong to it.
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

    /// Sends a fresh report with the person's text, contact and context, and
    /// FILES in their order. Returns the service's report number.
    public func send(description: String, contact: String, context: [String: String],
                     files: [ReportFile]) async throws -> String {
        let report = ProblemReport.fresh()
        var create: [String: Any] = ["project": Self.project, "client_id": report.clientID, "claim_token": report.claim,
                                     "description": description, "context": context]
        if !contact.isEmpty { create["contact"] = contact }
        // Without files the report is submitted in this one request.
        if files.isEmpty { create["submit"] = true }
        let (status, data) = try await call("POST", "api/v1/reports", claim: report.claim, json: create)
        guard status == 200 || status == 201 else { throw Self.fail(status, data) }
        guard let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { throw ProblemReportError.refused(status, "no_report_id") }
        guard !files.isEmpty else { return id }
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
        return id
    }
}

import CryptoKit
enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
