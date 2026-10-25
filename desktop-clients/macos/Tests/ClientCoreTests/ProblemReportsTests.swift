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
            return (200, Data(#"{"id":"rep_1","state":"in_progress","attachments":[],"replies":[{"from":"reporter","body":"It drops","created_at":"2026-10-24T10:00:00Z"},{"from":"support","body":"Which network?","created_at":"2026-10-24T11:30:00.123Z"},{"from":"robot","body":"x"}]}"#.utf8))
        case ("POST", "/api/v1/reports/rep_1/messages"): return (201, Data())
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
            .send(description: "Tunnel drops\nsince Monday", kind: .question, reporter: "me-1", contact: "", context: ["app_version": "2.3.0"], files: [])
        #expect(id.id == "rep_1" && id.kind == .question && id.title == "Tunnel drops" && id.seen == 0)
        #expect(service.calls.map { "\($0.method) \($0.path)" } == ["POST /api/v1/reports"])
        let body = service.json(0)
        #expect(body["project"] as? String == "waypoint" && body["submit"] as? Bool == true && body["contact"] == nil)
        #expect(body["kind"] as? String == "question" && (body["reporter"] as? [String: String]) == ["id": "me-1"])
        #expect(id.claim == body["claim_token"] as? String)
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
            .send(description: "x", reporter: "me-1", contact: "me@example.com", context: [:], files: [picture, state])
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
            try await reporter(down).send(description: "x", reporter: "me-1", contact: "", context: [:], files: [])
        }
        let paused = RecordingService(); paused.status = 404
        await #expect(throws: ProblemReportError.unavailable) {
            try await reporter(paused).send(description: "x", reporter: "me-1", contact: "", context: [:], files: [])
        }
    }

    @Test func theConversationIsReadAndAnswered() async throws {
        let service = RecordingService()
        let reporter = ProblemReporter(endpoint: endpoint, transport: service)
        let report = SentReport(id: "rep_1", claim: String(repeating: "a", count: 64), kind: .bug, title: "x", sentAt: Date())
        let conversation = try await reporter.conversation(report)
        #expect(conversation.state == "in_progress" && conversation.stateLabel == "в работе")
        #expect(conversation.replies.map(\.from) == [.reporter, .support] && conversation.fromSupport == 1)
        #expect(conversation.replies[1].body == "Which network?" && conversation.replies[1].createdAt != nil)
        #expect(service.calls[0].headers["Authorization"] == "Bearer " + report.claim)
        try await reporter.reply(report, "  Home Wi-Fi  ")
        #expect(service.calls[1].method == "POST" && service.calls[1].path == "/api/v1/reports/rep_1/messages")
        #expect(service.json(1) as NSDictionary == ["body": "Home Wi-Fi"] as NSDictionary)
        await #expect(throws: ProblemReportError.refused(400, "invalid_body")) { try await reporter.reply(report, "   ") }
        let old = SentReport(id: "old", claim: report.claim, kind: .bug, title: "x", sentAt: Date())
        await #expect(throws: ProblemReportError.gone) { _ = try await reporter.conversation(old) }
    }

    @Test func theReporterIsTheSameEveryTime() throws {
        let defaults = try #require(UserDefaults(suiteName: "waypoint-reporter-\(UUID().uuidString)"))
        let first = ReporterIdentity.id(defaults)
        #expect(UUID(uuidString: first) != nil && ReporterIdentity.id(defaults) == first)
    }

    @Test func theJournalKeepsReportsForThisUserOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = ReportJournal(file: folder.appendingPathComponent("reports.json"))
        #expect(journal.load().isEmpty)
        for index in 0..<55 {
            try journal.add(SentReport(id: "r\(index)", claim: "c", kind: .feedback, title: "t", sentAt: Date(timeIntervalSince1970: Double(index))))
        }
        #expect(journal.load().count == ReportJournal.limit && journal.load().first?.id == "r54")
        try journal.markSeen("r54", 2)
        try journal.remove("r53")
        #expect(journal.load().first?.seen == 2 && !journal.load().contains { $0.id == "r53" })
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("reports.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func eachReportHasItsOwnClaim() {
        #expect(ProblemReport.fresh().claim != ProblemReport.fresh().claim)
    }
}
