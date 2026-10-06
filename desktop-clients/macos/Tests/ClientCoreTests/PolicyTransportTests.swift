import Foundation
import Testing
@testable import ClientCore

@Test func policyEndpointRestrictions() throws {
    let token = String(repeating: "a", count: 64)
    try PolicyTransportClient.validate(endpoint: #require(URL(string: "https://vpn.example.com:19443/client/v1/policy")), token: token)
    for text in ["http://vpn.example.com/client/v1/policy", "https://127.0.0.1/client/v1/policy",
                 "https://user@vpn.example.com/client/v1/policy", "https://vpn.example.com/client/v1/policy?device=x",
                 "https://vpn.example.com/client/v1/policy#x", "https://vpn.example.com/client/v1/%70olicy",
                 "https://vpn.example.com/ubus"] {
        #expect(throws: PolicyFetchError.invalidEndpoint) {
            try PolicyTransportClient.validate(endpoint: #require(URL(string: text)), token: token)
        }
    }
    #expect(throws: PolicyFetchError.invalidEndpoint) {
        try PolicyTransportClient.validate(endpoint: #require(URL(string: "https://vpn.example.com/client/v1/policy")), token: "secret")
    }
}

@Test func policyResponseBoundaries() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/policies.json")
    let fixtures = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[String: Any]])
    let data = try JSONSerialization.data(withJSONObject: #require(fixtures.first?["policy"]))
    let parsed = try PolicyTransportClient.decode(data: data, contentType: "application/json; charset=utf-8", length: Int64(data.count))
    #expect(parsed.revision == 1)
    for contentType: String? in [nil, "text/html"] {
        #expect(throws: PolicyFetchError.invalidResponse) {
            try PolicyTransportClient.decode(data: data, contentType: contentType, length: -1)
        }
    }
    #expect(throws: PolicyFetchError.invalidResponse) {
        try PolicyTransportClient.decode(data: data, contentType: "application/json", length: Int64(data.count + 1))
    }
    #expect(throws: PolicyFetchError.invalidResponse) {
        try PolicyTransportClient.decode(data: Data([0xFF]), contentType: "application/json", length: -1)
    }
    #expect(throws: PolicyFetchError.responseTooLarge) {
        try PolicyTransportClient.decode(data: Data(repeating: 32, count: 1_048_577), contentType: "application/json", length: -1)
    }
}
