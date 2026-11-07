import Foundation
import Testing
@testable import ClientCore

/// What the router says of each service now, read from recorded answers of the API.
private func answer(_ entries: String) -> Data {
    Data(#"{"version":1,"id":"alice-mac","revision":2,"selected":[],"available":[],"entries":["#.utf8 + Data(entries.utf8) + Data("]}".utf8))
}
private let entry = #"{"id":"chat","required":false,"on":true,"closed":false,"choose_closed":true,"domains":3,"networks":1,"resources":["host-4"],"cidrs":["149.154.160.0/20"]"#

@Test func healthOfEachServiceIsReadAndAnOlderRouterMeansUnknown() throws {
    let recorded = [
        entry + #","health":{"state":"ok","tunnel":1,"since":1700000000}}"#,
        entry.replacingOccurrences(of: "chat", with: "mail") + #","health":{"state":"down","reason":"no_tunnel"}}"#,
        entry.replacingOccurrences(of: "chat", with: "wiki") + #","health":{"state":"down","reason":"silent","tunnel":2}}"#,
        entry.replacingOccurrences(of: "chat", with: "news") + #","health":{"state":"direct"}}"#,
        entry.replacingOccurrences(of: "chat", with: "docs") + #","health":{"state":"unknown"}}"#,
        entry.replacingOccurrences(of: "chat", with: "old") + "}",
    ].joined(separator: ",")
    let entries = try #require(try DeviceTransport.decodeServices(answer(recorded), id: "alice-mac").entries)
    #expect(entries.map(\.health.state) == [.ok, .down, .down, .direct, .unknown, .unknown])
    #expect(entries[0].health.since == 1_700_000_000 && entries[1].health.reason == "no_tunnel" && entries[2].health.reason == "silent")
    for bad in [#","health":{"state":"fine"}}"#, #","health":{"state":"down","reason":"Bad Reason"}}"#,
                #","health":{"state":"ok","extra":1}}"#, #","health":"ok"}"#, #","health":{"state":"ok","since":-5}}"#] {
        #expect(throws: DeviceError.invalidResponse) { try DeviceTransport.decodeServices(answer(entry + bad), id: "alice-mac") }
    }
}

/// The same examples the router checks itself against: each accepted the same
/// way, each refused for the same reason, before anything is sent.
@Test func ownAddressesFollowTheSharedExamples() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixtures/own-addresses.json"))) as? [String: Any])
    let server = try #require(json["server"] as? String)
    for item in try #require(json["domains"] as? [[String: String]]) {
        let input = item["input"]!
        switch OwnAddresses.checkDomain(input, server: [server]) {
        case .success(let name): #expect(name == item["ok"], "\(input)")
        case .failure(let refusal): #expect(refusal.reason == item["reason"] && refusal.entry == input, "\(input): \(refusal.reason)")
        }
    }
    for item in try #require(json["networks"] as? [[String: String]]) {
        let input = item["input"]!
        switch OwnAddresses.checkNetwork(input) {
        case .success(let network): #expect(network == item["ok"], "\(input)")
        case .failure(let refusal): #expect(refusal.reason == item["reason"], "\(input): \(refusal.reason)")
        }
    }
    #expect(DeviceTransport.decodeOwnRefusal(Data(#"{"error":"invalid_own","reason":"private","entry":"10.0.0.5"}"#.utf8)) == OwnRefusal(reason: "private", entry: "10.0.0.5"))
    #expect(DeviceTransport.decodeOwnRefusal(Data(#"{"error":"invalid_own","reason":"Bad"}"#.utf8)) == nil)
}

@Test func aSessionThatDoesNotComeUpSaysWhy() async throws {
    var (runtime, machine, _, store, now) = try await registered()
    try await runtime.setWanted(true)
    await runtime.tick(now: now); now += 10
    var status = await runtime.status()
    #expect(status.state == "connecting" && status.visible == "connecting" && status.error == "none")
    func after30(_ setup: () -> Void) async -> ClientStatusReport {
        setup()
        for _ in 0..<4 { await runtime.tick(now: now); now += 10 }
        return await runtime.status()
    }
    status = await after30 { machine.sync { machine.isOnline = true; machine.serverAddress = "203.0.113.10" } }
    #expect(status.state == "connection_error" && status.error == "ike_no_answer" && status.visible == "attention")
    #expect(status.next != nil, "the next attempt is named")
    status = await after30 { machine.sync { machine.serverAddress = "" } }
    #expect(status.error == "server_not_found")
    status = await after30 { machine.sync { machine.isOnline = false } }
    #expect(status.error == "offline")
    // Once the session is up the cause goes.
    machine.sync { machine.connected = true }
    await runtime.tick(now: now)
    #expect(await runtime.status().error != "offline")
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func everyPublishedStateHasOneVisibleState() {
    for state in StatusCodes.states {
        for cause in StatusCodes.causes[state] ?? [] {
            #expect(StatusView.visibleStates.contains(StatusView.visible(state: state, error: cause)), "\(state)/\(cause)")
        }
    }
    #expect(StatusView.visible(state: "protected", error: "none") == "on")
    #expect(StatusView.visible(state: "profile_required", error: "profile_removed") == "attention")
    #expect(StatusView.visible(state: "profile_required", error: "none") == "setup")
    #expect(StatusView.visible(state: "access_closed", error: "no_services") == "closed")
    let entry = ServiceEntry(id: "chat", required: false, on: true, closed: true, chooseClosed: true, domains: 1, networks: 0, resources: [], cidrs: [])
    var open = entry; open = ServiceEntry(id: "wiki", required: false, on: true, closed: false, chooseClosed: true, domains: 1, networks: 0, resources: [], cidrs: [])
    let off = ServiceEntry(id: "news", required: false, on: false, closed: false, chooseClosed: true, domains: 1, networks: 0, resources: [], cidrs: [])
    #expect(StatusView.paths([entry, open, off], protected: false).map(\.path) == ["blocked", "direct", nil])
    #expect(StatusView.paths([entry, open, off], protected: true).map(\.path) == ["tunnel", "tunnel", nil])
}
