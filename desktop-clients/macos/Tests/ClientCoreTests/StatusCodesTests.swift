import Foundation
import Testing
@testable import ClientCore

/// The shared table of status codes and their phrases, `fixtures/status-codes.json`,
/// against what this client can produce and says.
private struct Row {
    let key: String
    let states: [String]
    let errors: [String]
    let warnings: [String]
    let only: [String]?
    let heading: String
    let detail: String
}

private func table() throws -> (rows: [Row], auto: [String: Any]) {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("fixtures/status-codes.json"))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let phrases = try #require(json["phrases"] as? [[String: Any]])
    var rows: [Row] = []
    for phrase in phrases {
        let key = try #require(phrase["key"] as? String)
        let when = try #require(phrase["when"] as? [String: Any])
        guard let mac = when["macos"] as? [String: Any] else { continue }
        let heading = try #require((phrase["heading"] as? [String: String])?["ru"], "\(key): heading")
        let detail = try #require((phrase["detail"] as? [String: String])?["ru"], "\(key): detail")
        #expect(((phrase["heading"] as? [String: String])?["en"] ?? "").isEmpty == false, "\(key): English heading")
        #expect(((phrase["detail"] as? [String: String])?["en"] ?? "").isEmpty == false, "\(key): English detail")
        rows.append(Row(key: key, states: try #require(phrase["states"] as? [String]),
                        errors: mac["error"] as? [String] ?? ["none"], warnings: mac["warnings"] as? [String] ?? [],
                        only: mac["only_states"] as? [String], heading: heading, detail: detail))
    }
    return (rows, try #require(json["auto_report"] as? [String: Any]))
}

@Test func everyCodeTheDaemonPublishesHasThePhraseOfTheTable() throws {
    let (rows, _) = try table()
    // What the table promises is what the daemon can publish, and the other way round.
    var promised: [String: Set<String>] = [:]
    for row in rows {
        for state in row.states where row.only?.contains(state) ?? true {
            promised[state, default: []].formUnion(row.errors)
        }
    }
    for state in StatusCodes.states {
        let produced = Set(StatusCodes.causes[state] ?? [])
        #expect(!produced.isEmpty, "\(state): no cause listed")
        #expect(promised[state] == produced, "\(state): table \(promised[state] ?? []) against client \(produced)")
    }
    #expect(Set(promised.keys).subtracting(StatusCodes.states) == ["service_unavailable"], "states in the table the daemon never publishes")

    // The client's own words for each row equal the table's.
    for row in rows {
        for state in row.states where row.only?.contains(state) ?? true {
            for error in row.errors {
                let phrase = StatusPhrases.phrase(state: state, error: error, full: row.warnings.contains("full"),
                                                  direct: row.warnings.contains("open"))
                #expect(phrase.heading == row.heading, "\(row.key) \(state)/\(error): heading")
                #expect(phrase.detail == row.detail.replacingOccurrences(of: "{code}", with: error), "\(row.key) \(state)/\(error): detail")
            }
        }
    }
    #expect(StatusPhrases.phrase(state: "service_unavailable", error: "none") == StatusPhrases.unavailable)
}

@Test func theCodesTheRuntimeNamesAreInTheTable() throws {
    let (rows, _) = try table()
    let named = Set(rows.flatMap(\.errors))
    let reachable: [DeviceError] = [.invalidEndpoint, .connectionFailed, .accessRejected, .httpRejected, .invalidResponse]
    for error in reachable { #expect(named.contains(StatusCodes.enrollment(error)), "enrollment \(error)") }
    for error in DeviceError.allCases { #expect(named.contains(StatusCodes.path(error)), "path \(error)") }
    // A code with no word of its own never falls to a wrong one silently.
    for error in DeviceError.allCases { #expect(named.contains(StatusCodes.enrollment(error)), "enrollment \(error)") }
}

@Test func theAutomaticReportRulesAreConsistent() throws {
    let (_, auto) = try table()
    #expect(auto["kind"] as? String == "crash" && auto["project"] as? String == "waypoint")
    let limits = try #require(auto["limits"] as? [String: Any])
    #expect(limits["per_device_per_day"] as? Int == 5 && limits["per_fingerprint_per_day"] as? Int == 1)
    #expect(limits["queue_entries"] as? Int == 20 && limits["queue_days"] as? Int == 7)
    #expect(limits["honour_retry_after"] as? Bool == true)

    let failures = try #require(auto["failures"] as? [[String: Any]])
    let codes = failures.compactMap { $0["failure_code"] as? String }
    #expect(Set(codes).count == codes.count && !codes.isEmpty, "a failure code is listed once")
    for failure in failures {
        let platforms = try #require(failure["platforms"] as? [String])
        #expect(!platforms.isEmpty && Set(platforms).isSubset(of: ["macos", "windows"]))
        #expect((failure["when"] as? String)?.isEmpty == false)
    }

    // What the environment causes is never a failure of the program.
    let never = try #require(auto["never_reported"] as? [String: Any])
    let environment = Set((never["codes"] as? [String] ?? []) + (never["states"] as? [String] ?? []))
    #expect(environment.isDisjoint(with: codes), "an environment code is reported as a failure")
    // The report names only what the service allows, and no address or name.
    let allowed = Set((auto["context_keys"] as? [String] ?? []) + (auto["project_context_keys"] as? [String] ?? []))
    let forbidden = Set(try #require(auto["forbidden"] as? [String]))
    #expect(allowed.isDisjoint(with: forbidden) && !allowed.isEmpty)
    #expect(allowed.isSuperset(of: ["failure_code", "failure_phase", "app_version", "os_version", "architecture", "language"]))
}
