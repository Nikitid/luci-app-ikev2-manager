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
        case "blocked": return "Доступ закрыт"
        case "enrollment_required": return "Требуется настройка доступа"
        case "registration_pending": return "Регистрация не завершена"
        case "registration_error": return "Ошибка регистрации"
        case "profile_required": return "Нужен профиль VPN"
        case "connecting": return "Подключение к VPN"
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
        case "blocked": return "Подключение выключено. Выбранные адреса остаются заблокированы."
        case "enrollment_required": return "Вставьте ссылку приглашения, выданную администратором."
        case "registration_pending": return "Ожидается выдача настроек сервера."
        case "registration_error": return "Не удалось получить или сохранить настройки. Попытка повторяется автоматически."
        case "profile_required": return "Устройство зарегистрировано. Осталось один раз установить профиль VPN в «Системных настройках»."
        case "connecting": return "Система устанавливает IKEv2-соединение. Доступ к выбранным адресам пока заблокирован."
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

struct ClientView: View {
    @StateObject private var model = ClientModel()
    @State private var invitation = ""
    @State private var registering = false
    @State private var reporting = false

    var body: some View {
        let status = model.status
        VStack(alignment: .leading, spacing: 10) {
            Text(model.heading).font(.title).bold()
                .foregroundStyle(status?.protected == true ? Color.green : status?.state == "blocked" ? Color.orange : Color.primary)
            Text(model.detail).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Блокировка вне туннеля: " + (status?.guardInstalled == true ? "включена и проверена" : "не подтверждена"))
            Text("Туннель и маршруты выбранных сервисов: " + (status?.routed == true ? "подтверждены" : status?.state == "connecting" ? "устанавливаются" : "нет"))
            Text("Путь на роутере: " + (status?.protected == true ? "подтверждён" : "не подтверждён"))
            Text(servicesLine(status)).fixedSize(horizontal: false, vertical: true)
            if !model.message.isEmpty { Text(model.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 4)
            HStack {
                if status?.state == "enrollment_required" || status?.state == "registration_error" {
                    Button("Регистрация…") { registering = true }
                }
                if status?.state == "profile_required" { Button("Установить профиль VPN…") { model.installProfile() } }
                if let status, status.guardInstalled, status.profileInstalled {
                    if status.wanted { Button("Отключить") { model.command("disconnect") } }
                    else { Button("Подключить") { model.command("connect") } }
                }
                Button("Отчёт…") { reporting = true }
                Spacer()
                Text("Проверено: " + model.checked.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary).font(.caption)
            }.disabled(model.busy)
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 360)
        .onAppear { model.start() }
        .sheet(isPresented: $registering) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Вставьте ссылку приглашения, выданную администратором")
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

    private func servicesLine(_ status: ClientStatusReport?) -> String {
        guard let status else { return "Назначенные сервисы: нет данных" }
        var line = status.services.isEmpty
            ? (status.domains == 0 ? "Назначенные сервисы: нет" : "Назначенные сервисы: доменов \(status.domains), названия уточняются")
            : "Назначенные сервисы (доменов: \(status.domains), версия настроек \(status.revision)): " + status.services.joined(separator: ", ")
        if !status.available.isEmpty { line += "\nДоступны по запросу у администратора: " + status.available.joined(separator: ", ") }
        return line
    }
}

@main
struct ClientApplication: App {
    var body: some Scene {
        WindowGroup("IKEv2 Manager") { ClientView() }.windowResizability(.contentSize)
    }
}
