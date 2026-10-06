import Foundation
import Testing
@testable import ClientCore

struct HostsFixture: Decodable {
    let name: String
    let original: String
    let entries: [HostEntry]
    let expected: String?
    let fails: Bool
}

@Test func sharedHostsFixtures() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = try JSONDecoder().decode([HostsFixture].self,
        from: Data(contentsOf: root.appendingPathComponent("fixtures/hosts.json")))
    for fixture in fixtures {
        do {
            let result = try ManagedHosts.reconcile(fixture.original, entries: fixture.entries)
            #expect(!fixture.fails, "\(fixture.name): should refuse")
            #expect(result == fixture.expected, "\(fixture.name): preservation")
            #expect(try ManagedHosts.reconcile(result, entries: fixture.entries) == result,
                    "\(fixture.name): idempotence")
        } catch {
            #expect(fixture.fails, "\(fixture.name): unexpected error \(error)")
        }
    }
}
