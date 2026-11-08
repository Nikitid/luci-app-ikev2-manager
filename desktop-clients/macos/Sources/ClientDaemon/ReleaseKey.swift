// The client release public key (keys/waypoint-client-release.pem), written
// here by build.sh when the key exists. Without it no update is installed.
enum ReleaseKey {
    static let pem: String? = nil
}
