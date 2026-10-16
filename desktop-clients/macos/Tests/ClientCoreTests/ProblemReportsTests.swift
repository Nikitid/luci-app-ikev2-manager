import Foundation
import os
import Testing
@testable import ClientCore

/// A report service that answers as its contract says and keeps every request.
final class RecordingService: ReportTransport, @unchecked Sendable {
    struct Call { let method: String; let path: String; let headers: [String: String]; let body: Data? }
    private let lock = OSAllocatedUnfairLock(initialState: [Call]())
    var calls: [Call] { lock.withLock { $0 } }
    var down = false
    var status = 200

    func exchange(_ method: String, _ url: URL, headers: [String: String], body: Data?) async throws -> (Int, Data) {
        if down { throw URLError(.notConnectedToInternet) }
        lock.withLock { $0.append(Call(method: method, path: url.path, headers: headers, body: body)) }
        switch (method, url.path) {
        case ("POST", "/api/v1/reports"): return (status == 200 ? 201 : status, Data(#"{"id":"rep_1","state":"draft"}"#.utf8))
        case ("POST", "/api/v1/reports/rep_1/attachments"): return (201, Data(#"{"id":"att_1"}"#.utf8))
        case ("POST", "/api/v1/uploads"): return (201, Data())
        case ("PATCH", "/api/v1/uploads/att_1"): return (204, Data())
        case ("POST", "/api/v1/reports/rep_1/finalize"): return (200, Data(#"{"id":"rep_1","state":"received"}"#.utf8))
        case ("GET", "/api/v1/reports/rep_1"):
            return (200, Data(#"{"id":"rep_1","state":"in_progress","replies":[{"body":"Thanks, looking.","created_at":"2026-10-16T10:00:00Z"}]}"#.utf8))
        default: return (404, Data(#"{"error":"not_found"}"#.utf8))
        }
    }
    func json(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: calls[index].body ?? Data())) as? [String: Any] ?? [:]
    }
}

@Suite struct ProblemReportsTests {
    let endpoint = URL(string: "https://reports.example")!

    @Test func textAloneIsOneRequestThatSubmits() async throws {
        let service = RecordingService()
        let report = ProblemReport.fresh(title: "Tunnel drops\nmore text")
        #expect(report.claim.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        #expect(UUID(uuidString: report.clientID) != nil && report.title == "Tunnel drops")
        let sent = try await ProblemReporter(endpoint: endpoint, transport: service)
            .send(report, description: "Tunnel drops", contact: "", context: ["app_version": "2.3.0"], attachment: nil) { _ in }
        #expect(sent.reportID == "rep_1" && sent.finished)
        #expect(service.calls.map { "\($0.method) \($0.path)" } == ["POST /api/v1/reports"])
        let body = service.json(0)
        #expect(body["project"] as? String == "waypoint" && body["submit"] as? Bool == true && body["contact"] == nil)
        #expect(body["claim_token"] as? String == report.claim && body["client_id"] as? String == report.clientID)
        #expect(service.calls[0].headers["Authorization"] == "Bearer " + report.claim)
    }

    @Test func aFileFollowsTheUploadContractAndIsSubmittedLast() async throws {
        let service = RecordingService()
        let file = Data(#"{"state":"blocked"}"#.utf8)
        let box = OSAllocatedUnfairLock(initialState: [ProblemReport]())
        _ = try await ProblemReporter(endpoint: endpoint, transport: service)
            .send(.fresh(title: "x"), description: "x", contact: "me@example.com", context: [:], attachment: file) { report in box.withLock { $0.append(report) } }
        let seen = box.withLock { $0 }
        #expect(service.calls.map { "\($0.method) \($0.path)" } == ["POST /api/v1/reports", "POST /api/v1/reports/rep_1/attachments",
                                                                     "POST /api/v1/uploads", "PATCH /api/v1/uploads/att_1",
                                                                     "POST /api/v1/reports/rep_1/finalize"])
        #expect(service.json(0)["submit"] == nil && service.json(0)["contact"] as? String == "me@example.com")
        #expect(service.json(1)["size"] as? Int == file.count)
        #expect(service.json(1)["sha256"] as? String == SHA256Hex.of(file))
        #expect(service.calls[2].headers["Upload-Metadata"] == "attachment_id " + Data("att_1".utf8).base64EncodedString())
        #expect(service.calls[3].body == file)
        // The report number is handed out to be kept before the file is sent.
        #expect(seen.first?.reportID == "rep_1" && seen.first?.finished == false && seen.last?.finished == true)
    }

    @Test func failuresAreToldApart() async {
        let reporter = { (service: RecordingService) in ProblemReporter(endpoint: endpoint, transport: service) }
        let down = RecordingService(); down.down = true
        await #expect(throws: ProblemReportError.unreachable) {
            try await reporter(down).send(.fresh(title: "x"), description: "x", contact: "", context: [:], attachment: nil) { _ in }
        }
        let paused = RecordingService(); paused.status = 404
        await #expect(throws: ProblemReportError.unavailable) {
            try await reporter(paused).send(.fresh(title: "x"), description: "x", contact: "", context: [:], attachment: nil) { _ in }
        }
    }

    @Test func aSentReportIsReadWithItsClaim() async {
        let service = RecordingService()
        var report = ProblemReport.fresh(title: "x")
        report.reportID = "rep_1"
        let state = await ProblemReporter(endpoint: endpoint, transport: service).state(of: report)
        #expect(state == ProblemReportState(state: "in_progress", replies: ["Thanks, looking."]))
        #expect(service.calls.last?.headers["Authorization"] == "Bearer " + report.claim)
    }

    @Test func theBookKeepsReportsForThisUserOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let book = ProblemReportBook(file: dir.appendingPathComponent("reports.json"))
        var report = ProblemReport.fresh(title: "first")
        book.keep(report)
        report.reportID = "rep_1"
        book.keep(report)
        #expect(book.load() == [report])
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("reports.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try? FileManager.default.removeItem(at: dir)
    }
}
