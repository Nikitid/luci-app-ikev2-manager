import AppKit
import ClientCore
import SwiftUI

extension ClientModel {
    func releaseNotes(_ version: String) -> URL {
        URL(string: "https://github.com/Nikitid/luci-app-ikev2-manager/releases/tag/v\(version)")!
    }
    var updating: Bool { status?.update?.phase == .installing }
    var updateFailed: Bool { status?.update?.phase == .failed }
    var updateDetail: String {
        switch status?.update?.phase {
        case .installing?: return "Ставится. Туннель на минуту отключится и вернётся сам."
        case .failed?:
            let code = status?.update?.failure ?? ""
            if code == "noKey" { return "В этой сборке нет ключа проверки; поставьте версию вручную." }
            return "Файл не совпал с подписанным списком релиза; ничего не установлено, отчёт отправлен. Попытка повторится через 6 ч."
        default: return installUpdates ? "Поставится сама, когда туннель не нужен." : "Ставится только по кнопке."
        }
    }
    func updateNow() { command("update") }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.apply(UserDefaults.standard.string(forKey: "theme") ?? "system")
        // In the Dock while a window is open, only in the menu bar otherwise,
        // decided by the windows themselves and not by the views inside them.
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let id = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { Self.follow(opened: Self.window(id)) }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let id = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { Self.follow(closing: Self.window(id)) }
        }
    }

    @MainActor static func window(_ id: ObjectIdentifier?) -> NSWindow? {
        NSApp.windows.first { ObjectIdentifier($0) == id }
    }

    @MainActor static func ordinary(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && window.className != "NSStatusBarWindow"
    }

    @MainActor static func follow(opened window: NSWindow?) {
        guard let window, ordinary(window), NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    @MainActor static func follow(closing window: NSWindow?) {
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && ordinary($0) }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
    // The menu bar item stays when the window closes; the tunnel belongs to the daemon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    // Quitting is a moment the tunnel is not in use by this program: the
    // daemon may install a verified update now, if the person lets it.
    func applicationWillTerminate(_ notification: Notification) {
        if UserDefaults.standard.object(forKey: "installUpdates") as? Bool ?? true { _ = try? Control.send(Control.Request(op: "update_quit")) }
    }
}

@main
struct ClientApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ClientModel()

    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            Snapshots.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            exit(0)
        }
    }

    var body: some Scene {
        Window("Waypoint", id: "main") { MainWindow(model: model) }
            .defaultSize(width: 900, height: 600)
            .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarSign(visible: model.visible)
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView(model: model) }
    }
}
