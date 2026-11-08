import Foundation
import Testing
@testable import ClientCore

/// A report service that answers 429 with Retry-After once, then as RecordingService.
private final class LimitedService: ReportTransport, @unchecked Sendable {
    let inner = RecordingService()
    var limited = true
    func exchange(_ method: String, _ url: URL, headers: [String: String], body: Data?) async throws -> (Int, Data) {
        try await inner.exchange(method, url, headers: headers, body: body)
    }
    func exchangeWithHeaders(_ method: String, _ url: URL, headers: [String: String], body: Data?) async throws -> (Int, Data, [String: String]) {
        if limited { limited = false; return (429, Data(#"{"error":"rate_limited"}"#.utf8), ["retry-after": "120"]) }
        let (status, data) = try await exchange(method, url, headers: headers, body: body)
        return (status, data, [:])
    }
}

private let about = ["app_version": "3.0.0", "app_build": "3.0.0", "os_version": "macOS 27.2", "architecture": "arm64", "language": "ru"]

private func reporter(_ transport: ReportTransport) -> (AutoReporter, URL) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("auto-" + UUID().uuidString + ".json")
    return (AutoReporter(file: file, reporter: ProblemReporter(endpoint: URL(string: "https://reports.example")!, transport: transport),
                         about: about, reporterID: UUID().uuidString.lowercased()), file)
}

private let start = Date(timeIntervalSince1970: 1_800_000_000)

@Test func nothingGoesBeforeTheQuestionIsAnsweredAndNoClearsTheQueue() async {
    let service = RecordingService()
    let (auto, file) = reporter(service)
    defer { try? FileManager.default.removeItem(at: file) }
    for code in ["internal", "tick_stalled", "guard_unconfirmed"] { await auto.record(code: code, phase: "pf", at: start) }
    await auto.record(code: "ike_no_answer", phase: "connect", at: start)
    #expect(await auto.queue.pending.count == 3, "the environment is never a failure of the program")
    await auto.send(now: start + 3600, launchedAt: start, consent: nil, status: nil, faults: [])
    await auto.send(now: start + 3600, launchedAt: start, consent: false, status: nil, faults: [])
    #expect(service.calls.isEmpty, "not a single request before the person said yes")
    await auto.clear()
    #expect(await auto.queue.pending.isEmpty)
    // Kept between launches.
    await auto.record(code: "internal", phase: "names", at: start)
    let again = AutoReporter(file: file, about: about, reporterID: "x")
    #expect(await again.queue.pending.count == 1)
}

@Test func oneReportPerFailureADayAndRepeatsAsOneMessage() async throws {
    let service = RecordingService()
    let (auto, file) = reporter(service)
    defer { try? FileManager.default.removeItem(at: file) }
    await auto.record(code: "internal", phase: "pf", at: start)
    #expect(await auto.send(now: start + 30, launchedAt: start - 100, consent: true, status: nil, faults: []) == 0, "a minute for mending first")
    #expect(await auto.send(now: start + 61, launchedAt: start + 55, consent: true, status: nil, faults: []) == 0, "ten seconds after launch first")
    #expect(await auto.send(now: start + 61, launchedAt: start - 100, consent: true, status: nil, faults: []) == 1)
    let create = service.json(0)
    #expect(create["kind"] as? String == "crash" && create["description"] as? String == "Сбой Waypoint: internal, фаза pf")
    let context = try #require(create["context"] as? [String: String])
    #expect(context["failure_code"] == "internal" && context["fingerprint"] == "internal|pf|3.0.0" && context["occurrences"] == "1")
    #expect(Set(context.keys).isSubset(of: ["app_version", "app_build", "os_version", "architecture", "language", "failure_code", "failure_phase", "fingerprint", "occurrences", "mode"]))
    for offset in 1...4 { await auto.record(code: "internal", phase: "pf", at: start + Double(offset) * 100) }
    let before = service.calls.count
    #expect(await auto.send(now: start + 3600, launchedAt: start, consent: true, status: nil, faults: []) == 0, "no second report the same day")
    #expect(await auto.send(now: start + 86_500, launchedAt: start, consent: true, status: nil, faults: []) == 1)
    #expect(service.calls.count == before + 1 && service.calls.last?.path == "/api/v1/reports/rep_1/messages")
    let message = String(decoding: service.calls.last?.body ?? Data(), as: UTF8.self)
    #expect(message.contains("4"))
}

@Test func atMostFiveReportsADayAndTheServicesRetryAfterIsKept() async throws {
    let service = LimitedService()
    let (auto, file) = reporter(service)
    defer { try? FileManager.default.removeItem(at: file) }
    for (index, code) in ["internal", "tick_stalled", "guard_unconfirmed", "needs_reset", "reset_incomplete", "profile_loop"].enumerated() {
        await auto.record(code: code, phase: "p\(index)", at: start)
    }
    #expect(await auto.send(now: start + 100, launchedAt: start, consent: true, status: nil, faults: []) == 0)
    #expect(await auto.queue.notBefore == start + 220, "429 with Retry-After: 120")
    #expect(await auto.send(now: start + 200, launchedAt: start, consent: true, status: nil, faults: []) == 0)
    #expect(await auto.send(now: start + 230, launchedAt: start, consent: true, status: nil, faults: []) == 5)
    #expect(await auto.queue.pending.count == 1, "the sixth waits for tomorrow")
    #expect(await auto.send(now: start + 4000, launchedAt: start, consent: true, status: nil, faults: []) == 0)
    #expect(await auto.send(now: start + 230 + 86_400, launchedAt: start, consent: true, status: nil, faults: []) == 1)
}

@Test func faultFileHoldsOnlyTheListedKeys() throws {
    var status = ClientStatusReport(state: "error", guardInstalled: true, protected: false, routed: true, wanted: true,
                                    profileInstalled: true, error: "internal", services: ["secret-service"], available: ["other-secret"],
                                    domains: 4, revision: 7, release: "3.0.0", updatedAt: 1)
    status.warnings = ["vpn", "secret-warning"]
    status.addresses = ConnectionAddresses(server: "vpn.secret.example", serverIP: "198.51.100.200", services: "172.31.254.0/24", tunnel: "10.40.50.0/24")
    status.entries = [ServiceEntry(id: "secretchat", required: true, on: true, closed: true, chooseClosed: false, domains: 2, networks: 1,
                                   resources: ["host-1"], cidrs: ["149.154.160.0/20"])]
    status.own = OwnAddresses(limit: 5, ports: [443], domains: ["mine.secret.example"], networks: ["93.184.208.0/20"])
    let data = FaultFile.make(status: status, faults: [FaultEvent(code: "internal", phase: "pf", at: 900), FaultEvent(code: "secret", phase: "x", at: 950)],
                              appVersion: "3.0.0", now: Date(timeIntervalSince1970: 1000))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys).isSubset(of: FaultFile.keys), "\(Set(json.keys).subtracting(FaultFile.keys))")
    let text = String(decoding: data, as: UTF8.self)
    for word in ["secret", "149.154", "172.31", "10.40", "198.51", "host-1"] { #expect(!text.contains(word), "\(word)") }
    #expect((json["faults"] as? [[String: Any]])?.first?["seconds_ago"] as? Int == 100)
    #expect(data.count <= FaultFile.limit)
}

@Test func crashLogLosesTheHomeAndTheMachineKeys() throws {
    let header = #"{"app_name":"IKEv2ManagerClient","timestamp":"2026-11-08 10:00:00.00 +0300","bug_type":"309","os_version":"macOS 27.2"}"#
    let body = #"{"crashReporterKey":"ABCD-1234","sleepWakeUUID":"EEEE","bootSessionUUID":"FFFF","procPath":"/Users/alice/Applications/Waypoint.app/Contents/MacOS/IKEv2ManagerClient","threads":[{"triggered":true,"frames":[1]},{"frames":[2]}],"usedImages":[{"path":"/Users/alice/lib.dylib"}]}"#
    let cleaned = try #require(CrashLog.clean(Data((header + "\n" + body).utf8)))
    let text = String(decoding: cleaned, as: UTF8.self)
    #expect(!text.contains("alice") && !text.contains("ABCD-1234") && !text.contains("EEEE") && !text.contains("FFFF"))
    #expect(text.contains("~/Applications/Waypoint.app") && text.contains("\"threads\"") && text.contains("usedImages"))
    #expect(CrashLog.clean(Data("not json".utf8)) == nil)
}
