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
        let id = try await ProblemReporter(endpoint: endpoint, transport: service)
            .send(description: "Tunnel drops", contact: "", context: ["app_version": "2.3.0"], files: [])
        #expect(id == "rep_1")
        #expect(service.calls.map { "\($0.method) \($0.path)" } == ["POST /api/v1/reports"])
        let body = service.json(0)
        #expect(body["project"] as? String == "waypoint" && body["submit"] as? Bool == true && body["contact"] == nil)
        let claim = body["claim_token"] as? String ?? ""
        #expect(claim.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        #expect(UUID(uuidString: body["client_id"] as? String ?? "") != nil)
        #expect(service.calls[0].headers["Authorization"] == "Bearer " + claim)
    }

    @Test func eachFileFollowsTheUploadContractAndTheReportIsSubmittedLast() async throws {
        let service = RecordingService()
        let picture = ReportFile(name: "picture-1.png", contentType: "image/png", data: Data([0x89, 0x50, 0x4e, 0x47]))
        let state = ReportFile(name: "waypoint-state.json", contentType: "application/json", data: Data(#"{"state":"blocked"}"#.utf8))
        _ = try await ProblemReporter(endpoint: endpoint, transport: service)
            .send(description: "x", contact: "me@example.com", context: [:], files: [picture, state])
        let upload = ["POST /api/v1/reports/rep_1/attachments", "POST /api/v1/uploads", "PATCH /api/v1/uploads/att_1"]
        #expect(service.calls.map { "\($0.method) \($0.path)" } == ["POST /api/v1/reports"] + upload + upload + ["POST /api/v1/reports/rep_1/finalize"])
        #expect(service.json(0)["submit"] == nil && service.json(0)["contact"] as? String == "me@example.com")
        #expect(service.json(1)["filename"] as? String == "picture-1.png" && service.json(1)["content_type"] as? String == "image/png")
        #expect(service.json(1)["size"] as? Int == picture.data.count && service.json(1)["sha256"] as? String == SHA256Hex.of(picture.data))
        #expect(service.calls[2].headers["Upload-Metadata"] == "attachment_id " + Data("att_1".utf8).base64EncodedString())
        #expect(service.calls[3].body == picture.data && service.calls[6].body == state.data)
        #expect(service.json(4)["filename"] as? String == "waypoint-state.json")
        // Every request carries the one claim of this report.
        #expect(Set(service.calls.map { $0.headers["Authorization"] ?? "" }).count == 1)
    }

    @Test func failuresAreToldApart() async {
        let reporter = { (service: RecordingService) in ProblemReporter(endpoint: endpoint, transport: service) }
        let down = RecordingService(); down.down = true
        await #expect(throws: ProblemReportError.unreachable) {
            try await reporter(down).send(description: "x", contact: "", context: [:], files: [])
        }
        let paused = RecordingService(); paused.status = 404
        await #expect(throws: ProblemReportError.unavailable) {
            try await reporter(paused).send(description: "x", contact: "", context: [:], files: [])
        }
    }

    @Test func eachReportHasItsOwnClaim() {
        #expect(ProblemReport.fresh().claim != ProblemReport.fresh().claim)
    }
}
