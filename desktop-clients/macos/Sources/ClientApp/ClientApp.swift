import AppKit
import ClientCore
import SwiftUI

/// What the window shows: the daemon's last answer, or why there is none.
@MainActor
final class ClientModel: ObservableObject {
    @Published var status: ClientStatusReport?
    @Published var message = ""
    @Published var busy = false
    @Published var checked = Date()
    private var timer: Timer?
    private var connectAfterRegistration = false
    private var profileFile: URL?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func ask(_ request: Control.Request, then: @escaping @MainActor (Control.Response?) -> Void) {
        Task.detached {
            let response = try? Control.send(request)
            await then(response)
        }
    }

    func refresh() {
        ask(Control.Request(op: "status")) { [self] response in
            status = response?.status
            checked = Date()
            guard let status else { return }
            if status.profileInstalled, let file = profileFile {
                // The profile carries the device's credential; it has done its work.
                try? FileManager.default.removeItem(at: file)
                profileFile = nil
            }
            if connectAfterRegistration, status.state == "blocked", status.profileInstalled, !status.wanted, !busy {
                connectAfterRegistration = false
                command("connect")
            }
        }
    }

    func command(_ op: String, invitation: String? = nil) {
        guard !busy else { return }
        busy = true
        message = ""
        ask(Control.Request(op: op, invitation: invitation)) { [self] response in
            busy = false
            switch response?.result {
            case "ok": if let next = response?.status { status = next }
            case "administrator_required": message = "Это действие доступно только администратору этого Mac."
            case nil: message = "Нет связи с системной службой клиента."
            default: message = "Служба отклонила действие. Проверьте состояние клиента."
            }
        }
    }

    func register(_ invitation: String) {
        connectAfterRegistration = true
        command("begin", invitation: invitation)
    }

    /// Hands the VPN profile to System Settings, where the owner approves it.
    func installProfile() {
        guard !busy else { return }
        busy = true
        ask(Control.Request(op: "profile")) { [self] response in
            busy = false
            guard response?.result == "ok", let encoded = response?.profile, let data = Data(base64Encoded: encoded) else {
                message = response?.result == "administrator_required" ? "Профиль VPN может установить только администратор этого Mac."
                    : "Не удалось получить профиль VPN."
                return
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikev2-manager-client-" + UUID().uuidString)
            let file = directory.appendingPathComponent("IKEv2 Manager Client.mobileconfig")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
                else { throw CocoaError(.fileWriteUnknown) }
            } catch { message = "Не удалось подготовить профиль VPN."; return }
            profileFile = file
            connectAfterRegistration = true
            NSWorkspace.shared.open(file)
            if let settings = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") { NSWorkspace.shared.open(settings) }
            message = "Откройте «Системные настройки» → «Основные» → «Управление устройством», выберите профиль «IKEv2 Manager Client» и нажмите «Установить»."
        }
    }

    var heading: String {
        guard let status else { return "Служба не отвечает" }
        switch status.state {
        case "protected": return "Доступ открыт"
        case "blocked": return "Доступ выключен"
        case "enrollment_required": return "Устройство не зарегистрировано"
        case "registration_pending": return "Регистрация не завершена"
        case "registration_error": return "Ошибка регистрации"
        case "profile_required": return "Нужен профиль VPN"
        case "connecting": return "Подключение"
        case "tunnel_connected": return "Туннель установлен"
        case "connection_error": return "Не удалось подключить VPN"
        case "starting": return "Служба запускается"
        case "access_closed": return "Доступ не включён"
        default: return "Ошибка системной службы"
        }
    }

    var detail: String {
        guard let status else { return "Системный компонент клиента не установлен или остановлен. Состояние защиты не подтверждено." }
        switch status.state {
        case "protected": return "Выбранные сервисы идут через офис: туннель, маршруты и путь на роутере подтверждены. Остальной трафик идёт как обычно."
        case "blocked": return "Вы выключили доступ. Сервисы офиса заблокированы, остальной интернет работает как обычно."
        case "enrollment_required": return "Получите у администратора ссылку приглашения и нажмите «Зарегистрировать устройство»."
        case "registration_pending": return "Ожидается выдача настроек сервера."
        case "registration_error": return "Не удалось получить или сохранить настройки. Попытка повторяется автоматически."
        case "profile_required": return "Устройство зарегистрировано. Осталось один раз установить профиль VPN в «Системных настройках»."
        case "connecting": return "Система устанавливает соединение с офисом. Если это длится дольше минуты, включите «IKEv2 Manager Client» в «Системных настройках» → VPN."
        case "tunnel_connected":
            switch status.error {
            case "path_pathUnavailable": return "Роутер пока не подтвердил путь для выбранных сервисов. Доступ к ним заблокирован; проверка повторяется."
            case "path_connectionFailed": return "Нет связи со службой доступа на роутере. Доступ к выбранным сервисам заблокирован; проверка повторяется."
            case "path_differentPolicy": return "Роутер и клиент применяют разные версии настроек. Доступ заблокирован, пока они не совпадут."
            case "path_accessRejected": return "Доступ этого устройства отозван администратором."
            default: return "IKEv2 и маршруты подтверждены. Ожидается подтверждение пути от роутера."
            }
        case "connection_error":
            return status.error == "tunnel_takes_everything"
                ? "Сервер предложил отправлять в туннель весь трафик. Клиент отказался: через офис должны идти только выбранные сервисы."
                : "Система не подтвердила туннель. Попытка повторится автоматически."
        case "access_closed": return "Роутер знает это устройство, но доступ для него не включён администратором или отозван. Выбранные сервисы остаются заблокированы; проверка повторяется."
        default: return "Служба не смогла подтвердить защиту или обновить настройки. Доступ не подтверждён."
        }
    }

    /// The one place downloads come from; the router supplies only a number.
    var update: (version: String, url: URL)? {
        let own = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        guard let release = status?.release, ClientStatusReport.newer(release, than: own),
              let url = URL(string: "https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v\(release)/IKEv2ManagerClient-\(release).pkg")
        else { return nil }
        return (release, url)
    }

    var version: String { "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0") }

    var report: String {
        guard let status, let data = try? JSONEncoder.pretty.encode(status) else { return "{\n  \"state\" : \"service_unavailable\"\n}" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// How a state reads at a glance: one colour and one sign, the same on Windows.
enum Tone {
    case open, working, attention, off
    var color: Color {
        switch self {
        case .open: return Color(red: 0.13, green: 0.55, blue: 0.27)
        case .working: return Color(red: 0.85, green: 0.55, blue: 0.05)
        case .attention: return Color(red: 0.78, green: 0.20, blue: 0.18)
        case .off: return Color.secondary
        }
    }
    var symbol: String {
        switch self {
        case .open: return "checkmark"
        case .working: return "ellipsis"
        case .attention: return "exclamationmark"
        case .off: return "power"
        }
    }
}

extension ClientModel {
    var tone: Tone {
        guard let status else { return .attention }
        switch status.state {
        case "protected": return .open
        case "connecting", "tunnel_connected", "registration_pending", "profile_required", "starting": return .working
        case "blocked", "enrollment_required": return .off
        default: return .attention
        }
    }
}

/// A framed group of rows, the unit both windows are built from.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

struct CheckRow: View {
    let label: String, value: String, tone: Tone
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tone.color).frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

struct ClientView: View {
    @StateObject private var model = ClientModel()
    @State private var invitation = ""
    @State private var registering = false
    @State private var reporting = false

    var body: some View {
        let status = model.status
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(model.tone.color.opacity(0.15)).frame(width: 44, height: 44)
                    Image(systemName: model.tone.symbol).font(.system(size: 18, weight: .bold)).foregroundStyle(model.tone.color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.heading).font(.title2).bold()
                    Text(model.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Card(title: "Проверки") {
                let fresh = status?.state == "enrollment_required"
                CheckRow(label: "Блокировка вне туннеля", value: status?.guardInstalled == true ? "включена" : fresh ? "появится после регистрации" : "не подтверждена",
                         tone: status?.guardInstalled == true ? .open : fresh ? .off : .attention)
                CheckRow(label: "Туннель и маршруты", value: status?.routed == true ? "подтверждены" : status?.state == "connecting" ? "устанавливаются" : "нет",
                         tone: status?.routed == true ? .open : status?.state == "connecting" ? .working : .off)
                CheckRow(label: "Путь через офис", value: status?.protected == true ? "подтверждён" : "не подтверждён",
                         tone: status?.protected == true ? .open : status?.routed == true ? .working : .off)
            }
            Card(title: "Сервисы через офис") {
                if let status, !status.services.isEmpty {
                    Text(status.services.joined(separator: " · ")).bold().fixedSize(horizontal: false, vertical: true)
                    Text("Доменов: \(status.domains) · версия настроек \(status.revision)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(status == nil ? "Нет данных" : status?.domains == 0 ? "Пока не назначены" : "Доменов: \(status?.domains ?? 0), названия уточняются")
                        .foregroundStyle(.secondary)
                }
                if let status, !status.available.isEmpty {
                    Text("По запросу у администратора: " + status.available.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let update = model.update {
                HStack {
                    Text("Доступна версия \(update.version). Установка сохранит регистрацию.").fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Скачать") { NSWorkspace.shared.open(update.url) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tone.working.color.opacity(0.12)))
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                primaryAction(status)
                Spacer()
                Button("Проверить") { model.refresh() }
                Button("Отчёт…") { reporting = true }
            }.fixedSize(horizontal: false, vertical: true).disabled(model.busy)
            Text("Проверено " + model.checked.formatted(date: .omitted, time: .standard) + " · " + model.version)
                .foregroundStyle(.secondary).font(.caption)
        }
        .padding(22)
        .frame(width: 540)
        .frame(minHeight: 420)
        .onAppear { model.start() }
        .sheet(isPresented: $registering) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Регистрация устройства").font(.headline)
                Text("Вставьте ссылку приглашения, выданную администратором.").foregroundStyle(.secondary)
                SecureField("https://…/client/v1/enroll#…", text: $invitation).frame(width: 460)
                HStack {
                    Spacer()
                    Button("Отмена") { invitation = ""; registering = false }
                    Button("Зарегистрировать") {
                        let link = invitation
                        invitation = ""; registering = false
                        model.register(link)
                    }.keyboardShortcut(.defaultAction).disabled(invitation.isEmpty)
                }
            }.padding(20)
        }
        .sheet(isPresented: $reporting) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Отчёт о состоянии").font(.headline)
                ScrollView { Text(model.report).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(width: 480, height: 260)
                HStack {
                    Button("Скопировать") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.report, forType: .string) }
                    Spacer()
                    Button("Закрыть") { reporting = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }
    }

    /// The one thing to do next, as the prominent button.
    @ViewBuilder private func primaryAction(_ status: ClientStatusReport?) -> some View {
        if status?.state == "enrollment_required" || status?.state == "registration_error" {
            Button("Зарегистрировать устройство…") { registering = true }.buttonStyle(.borderedProminent).fixedSize()
        } else if status?.state == "profile_required" {
            Button("Установить профиль VPN…") { model.installProfile() }.buttonStyle(.borderedProminent).fixedSize()
        } else if let status, status.guardInstalled, status.profileInstalled {
            if status.wanted { Button("Отключить доступ") { model.command("disconnect") } }
            else { Button("Включить доступ") { model.command("connect") }.buttonStyle(.borderedProminent) }
        }
    }
}

@main
struct ClientApplication: App {
    var body: some Scene {
        WindowGroup("IKEv2 Manager") { ClientView() }.windowResizability(.contentSize)
    }
}
