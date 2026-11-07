import AppKit
import ClientCore
import SwiftUI

extension ClientModel {
    func releaseNotes(_ version: String) -> URL {
        URL(string: "https://github.com/Nikitid/luci-app-ikev2-manager/releases/tag/v\(version)")!
    }
    var updating: Bool { false }
    var updateFailed: Bool { false }
    var updateDetail: String { "Поставится сама, когда туннель не нужен." }
    func updateNow() { if let url = update?.url { NSWorkspace.shared.open(url) } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.apply(UserDefaults.standard.string(forKey: "theme") ?? "system")
    }
    // The menu bar item stays when the window closes; the tunnel belongs to the daemon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
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
