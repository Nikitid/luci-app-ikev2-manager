import Foundation

/// The one state the window and the menu show for what the daemon publishes:
/// the sign of the menu bar icon and the heading follow it.
public enum StatusView {
    public static let visibleStates = ["off", "connecting", "on", "attention", "setup", "closed"]

    public static func visible(state: String, error: String) -> String {
        switch state {
        case "protected": return "on"
        case "blocked": return "off"
        case "connecting", "tunnel_connected", "registration_pending", "starting": return "connecting"
        case "enrollment_required", "profile_required" where error == "none": return "setup"
        case "access_closed": return "closed"
        default: return "attention"
        }
    }

    /// Where each service the device has on goes now: through the tunnel,
    /// the ordinary way, or nowhere while the tunnel is down.
    public static func paths(_ entries: [ServiceEntry], protected: Bool) -> [ServiceEntry] {
        entries.map { entry in
            var copy = entry
            copy.path = !entry.on ? nil : protected ? "tunnel" : entry.closed ? "blocked" : "direct"
            return copy
        }
    }
}
