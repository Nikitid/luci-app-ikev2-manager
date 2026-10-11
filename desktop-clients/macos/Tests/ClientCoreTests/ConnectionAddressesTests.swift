import Foundation
import Testing
@testable import ClientCore

struct ConnectionAddressesTests {
    @Test(arguments: ["", "10.40.50.0/24", "172.30.16.0/20", "10.40.50.7/32"])
    func acceptsNetworks(_ text: String) { #expect(ConnectionAddresses.validNetwork(text)) }

    @Test(arguments: ["0.0.0.0/0", "10.40.50.1/24", "10.40.50.0/33", "10.40.50.0/024", "010.40.50.0/24", "not-a-network"])
    func refusesInvalidNetworks(_ text: String) { #expect(!ConnectionAddresses.validNetwork(text)) }

    @Test func servicesFromOldAndNewRouters() throws {
        var value: [String: Any] = ["version": 1, "id": "laptop", "revision": 1, "selected": [], "available": []]
        #expect(try DeviceTransport.decodeServices(JSONSerialization.data(withJSONObject: value), id: "laptop").tunnelSubnet == "")
        value["tunnel_subnet"] = "10.40.50.0/24"
        #expect(try DeviceTransport.decodeServices(JSONSerialization.data(withJSONObject: value), id: "laptop").tunnelSubnet == "10.40.50.0/24")
        value["tunnel_subnet"] = "10.40.50.1/24"
        #expect(throws: DeviceError.invalidResponse) { try DeviceTransport.decodeServices(JSONSerialization.data(withJSONObject: value), id: "laptop") }
    }
}
