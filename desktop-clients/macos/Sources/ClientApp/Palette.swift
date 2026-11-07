import AppKit
import SwiftUI

/// "Patina and graphite" as named colours: light, dark and their increased
/// contrast variants, resolved by the system for the current appearance.
enum Palette {
    private static func color(_ name: String, light: UInt32, dark: UInt32, lightContrast: UInt32? = nil, darkContrast: UInt32? = nil) -> Color {
        func make(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: NSColor.Name("waypoint." + name)) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return make(dark)
            case .accessibilityHighContrastDarkAqua?: return make(darkContrast ?? dark)
            case .accessibilityHighContrastAqua?: return make(lightContrast ?? light)
            default: return make(light)
            }
        })
    }

    static let accent = color("accent", light: 0x207070, dark: 0x7abfbf, lightContrast: 0x145757, darkContrast: 0x9ad6d6)
    static let accentSoft = color("accent-soft", light: 0xcfe7e5, dark: 0x203a3a, lightContrast: 0xb9dcd9, darkContrast: 0x2a4a4a)
    static let bg = color("bg", light: 0xf4f3f1, dark: 0x1a1c1e)
    static let surface = color("surface", light: 0xfdfdfb, dark: 0x232528)
    /// The edge that holds a surface; with increased contrast it is the strong one.
    static let line = color("line", light: 0xd4d2cf, dark: 0x383b3f, lightContrast: 0x8e8c89, darkContrast: 0x7a7e83)
    static let lineStrong = color("line-strong", light: 0xc2c0bc, dark: 0x55595e, lightContrast: 0x6f6d6a, darkContrast: 0x9a9ea3)
    /// A deviation: brick. Never the norm.
    static let danger = color("danger", light: 0x993a31, dark: 0xed8c80, lightContrast: 0x7a2a22, darkContrast: 0xffaca2)
    /// Stale data only: brass.
    static let stale = color("stale", light: 0x7b5518, dark: 0xe1bb74, lightContrast: 0x5e400f, darkContrast: 0xf0d199)
}

/// A group of rows held by a hairline edge, not by a shadow.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
    }
}

/// One row of a panel, with the hairline between rows.
struct PanelRow<Content: View>: View {
    var last = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            content.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            if !last { Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 16) }
        }
    }
}

/// The program's sign in four states, the same drawing as the menu bar
/// icon: three lanes, the middle one the path.
struct WaypointSign: View {
    let visible: String
    var size: CGFloat = 16
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(Self.label(visible))
    }
    var symbol: String {
        switch visible {
        case "on": return "arrow.right.to.line"
        case "connecting": return "ellipsis"
        case "attention": return "exclamationmark.triangle"
        default: return "line.3.horizontal"
        }
    }
    static func label(_ visible: String) -> String {
        switch visible {
        case "on": return "Waypoint: подключено"
        case "connecting": return "Waypoint: подключается"
        case "attention": return "Waypoint: нужно внимание"
        default: return "Waypoint: выключено"
        }
    }
}

/// The menu bar icon: the template images made from the program's sign, or
/// the symbol while running outside the bundle.
struct MenuBarSign: View {
    let visible: String
    var body: some View {
        let name: String = switch visible {
        case "on": "menubar-open"
        case "connecting": "menubar-connecting"
        case "attention": "menubar-attention"
        default: "menubar-off"
        }
        if let image = Bundle.main.image(forResource: name) {
            let template = { image.isTemplate = true; return image }()
            Image(nsImage: template).accessibilityLabel(WaypointSign.label(visible))
        } else {
            WaypointSign(visible: visible)
        }
    }
}
