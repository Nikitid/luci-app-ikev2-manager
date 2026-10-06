// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IKEv2ManagerClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClientCore", targets: ["ClientCore"]),
        .executable(name: "ikev2-manager-clientd", targets: ["ClientDaemon"]),
        .executable(name: "IKEv2ManagerClient", targets: ["ClientApp"])
    ],
    targets: [
        .target(name: "ClientCore"),
        .executableTarget(name: "ClientDaemon", dependencies: ["ClientCore"]),
        .executableTarget(name: "ClientApp", dependencies: ["ClientCore"]),
        .testTarget(name: "ClientCoreTests", dependencies: ["ClientCore"])
    ]
)
