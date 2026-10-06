// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IKEv2ManagerClient",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ClientCore", targets: ["ClientCore"])],
    targets: [
        .target(name: "ClientCore"),
        .testTarget(name: "ClientCoreTests", dependencies: ["ClientCore"])
    ]
)
