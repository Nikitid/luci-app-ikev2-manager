import AppKit
import ClientCore
import SwiftUI

/// `IKEv2ManagerClient --snapshot DIR`: every screen in the light and the dark
/// appearance, from made-up data, as PNG files, for checking the views
/// without a daemon. The model asks nobody in this mode.
@MainActor
enum Snapshots {
    static func entry(_ id: String, _ label: String, required: Bool = true, on: Bool = true, closed: Bool = false,
                      choose: Bool = false, health: ServiceHealth.State = .ok) -> ServiceEntry {
        var item = ServiceEntry(id: id, required: required, on: on, closed: closed, chooseClosed: choose, domains: 3, networks: 1,
                                resources: [], cidrs: ["149.154.160.0/20"])
        item.label = label
        item.health = ServiceHealth(state: health, reason: health == .down ? "silent" : nil, since: 1_800_000_000)
        return item
    }

    static func status(_ state: String = "protected", error: String = "none", down: Bool = false, worst: Bool = false) -> ClientStatusReport {
        var report = ClientStatusReport(state: state, guardInstalled: true, protected: state == "protected", routed: state == "protected",
                                        wanted: true, profileInstalled: true, error: error, services: [], available: [], domains: 12,
                                        revision: 4, release: "3.0.1", updatedAt: 0)
        var many: [ServiceEntry] = []
        for index in 1...18 {
            let health: ServiceHealth.State = index == 4 ? .down : .ok
            many.append(entry("s\(index)", "Очень длинное название сервиса номер \(index) для проверки", required: index < 10,
                              on: index < 14, closed: index % 3 == 0, choose: index >= 10, health: health))
        }
        report.entries = worst
            ? many
            : [entry("portal", "Рабочий портал", closed: true), entry("acc", "Бухгалтерия", closed: true, health: down ? .down : .ok),
               entry("mail", "Почта"), entry("chatgpt", "ChatGPT"),
               entry("youtube", "YouTube", required: false, choose: true), entry("telegram", "Telegram", required: false, on: false, choose: true),
               entry("steam", "Steam", required: false, on: false, choose: true)]
        report.own = worst
            ? OwnAddresses(limit: 20, ports: [80, 443], domains: (1...12).map { "site\($0).example-long-domain-name.org" },
                           networks: (1...8).map { "93.184.\($0).0/24" })
            : OwnAddresses(limit: 20, ports: [80, 443], domains: ["docs.example.org"], networks: ["93.184.215.34/32"])
        report.addresses = ConnectionAddresses(server: "vpn.example.test", serverIP: "", services: "172.31.254.0/24", tunnel: "10.40.50.0/24")
        report.visible = StatusView.visible(state: state, error: error)
        report.entries = report.entries.map { StatusView.paths($0, protected: state == "protected") }
        if state == "connection_error" { report.next = Int(Date().timeIntervalSince1970) + 20 }
        return report
    }

    static func model(_ status: ClientStatusReport?, asked: Bool = true, failed: Bool = false, firstRun: Bool = false) -> ClientModel {
        let model = ClientModel()
        model.offline = true
        model.status = status
        model.asked = asked
        model.failed = failed
        model.checked = Date(timeIntervalSince1970: 1_800_000_000)
        UserDefaults.standard.set(!firstRun, forKey: "firstRunDone")
        return model
    }

    static func write(to directory: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let savedFirstRun = UserDefaults.standard.object(forKey: "firstRunDone")
        let screens: [(String, CGSize, () -> AnyView)] = [
            ("01-menu", CGSize(width: 320, height: 420), { AnyView(MenuView(model: model(status()))) }),
            ("01-menu-error", CGSize(width: 320, height: 460), { AnyView(MenuView(model: model(status("connection_error", error: "ike_no_answer")))) }),
            ("02-overview", CGSize(width: 900, height: 640), { AnyView(MainWindow(model: model(status()))) }),
            ("03a-service-down", CGSize(width: 900, height: 640), { AnyView(MainWindow(model: model(status(down: true)))) }),
            ("03b-connection-error", CGSize(width: 900, height: 640), { AnyView(MainWindow(model: model(status("connection_error", error: "ike_no_answer")))) }),
            ("03c-loading", CGSize(width: 900, height: 640), { AnyView(MainWindow(model: model(nil, asked: false))) }),
            ("03d-daemon-down", CGSize(width: 900, height: 640), { AnyView(MainWindow(model: model(status(), failed: true))) }),
            ("04-services", CGSize(width: 900, height: 640), { AnyView(ServicesView(model: model(status(down: true))).background(Palette.bg)) }),
            ("04-add", CGSize(width: 440, height: 480), { AnyView(AddServiceSheet(model: model(status())).background(Palette.bg)) }),
            ("04-own", CGSize(width: 680, height: 520), { AnyView(OwnSitesView(model: model(status())).background(Palette.bg)) }),
            ("05-report", CGSize(width: 480, height: 520), { AnyView(NewReportSheet(model: model(status())).background(Palette.bg)) }),
            ("06-first-run", CGSize(width: 900, height: 640), { AnyView(MainWindow(model: model(status(), firstRun: true))) }),
            ("07-settings", CGSize(width: 560, height: 520), { AnyView(SettingsView(model: model(status()))) }),
            ("08-update", CGSize(width: 900, height: 640), { AnyView(MainWindow(model: model(status()))) }),
            ("90-worst-services", CGSize(width: 900, height: 900), { AnyView(ServicesView(model: model(status(worst: true))).background(Palette.bg)) }),
            ("90-worst-own", CGSize(width: 680, height: 1200), { AnyView(OwnSitesView(model: model(status(worst: true))).background(Palette.bg)) }),
            ("90-worst-empty", CGSize(width: 900, height: 640), { AnyView(MainWindow(model: model({ var s = status(); s.entries = []; s.own = nil; return s }()))) }),
        ]
        for (name, size, make) in screens {
            for (theme, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
                let view = NSHostingView(rootView: make().frame(width: size.width, height: size.height, alignment: .top).background(Palette.bg))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = appearance
                window.contentView = view
                view.frame = CGRect(origin: .zero, size: size)
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-\(theme).png"))
                window.close()
            }
        }
        // A daemon that answers after two seconds: the frame is there at once,
        // and what it shows then is the same as an immediate answer.
        for (theme, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            let slow = model(nil, asked: false)
            let size = CGSize(width: 900, height: 640)
            let view = NSHostingView(rootView: MainWindow(model: slow).frame(width: size.width, height: size.height, alignment: .top).background(Palette.bg))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = view
            view.frame = CGRect(origin: .zero, size: size)
            func shoot(_ name: String) {
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-\(theme).png"))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            shoot("10-slow-at-0s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { slow.status = status(); slow.asked = true }
            RunLoop.main.run(until: Date().addingTimeInterval(2.6))
            shoot("10-slow-at-2.6s")
            window.close()
        }
        if let savedFirstRun { UserDefaults.standard.set(savedFirstRun, forKey: "firstRunDone") } else { UserDefaults.standard.removeObject(forKey: "firstRunDone") }
    }
}
