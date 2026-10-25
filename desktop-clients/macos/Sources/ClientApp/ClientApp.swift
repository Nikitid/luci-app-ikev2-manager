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

    private var started = false
    func start() {
        // The window and the menu-bar item share this model; it starts once.
        guard !started else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        lookAtReports()
        reportTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.lookAtReports() }
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
            case "administrator_required": message = "Нужны права администратора."
            case nil: message = "Служба не отвечает."
            default: message = "Действие отклонено."
            }
        }
    }

    /// The person's choice of their offer: what is on, and what of it is
    /// blocked without the tunnel where that is theirs to decide.
    func choose(_ entry: ServiceEntry, on: Bool? = nil, closed: Bool? = nil) {
        guard let entries = status?.entries, !busy else { return }
        var turnedOn = Set(entries.filter { !$0.required && $0.on }.map(\.id))
        var blocked = Set(entries.filter { $0.chooseClosed && $0.closed }.map(\.id))
        if let on { if on { turnedOn.insert(entry.id) } else { turnedOn.remove(entry.id) } }
        if let closed { if closed { blocked.insert(entry.id) } else { blocked.remove(entry.id) } }
        busy = true
        message = ""
        ask(Control.Request(op: "choose", on: turnedOn.sorted(), closed: blocked.sorted())) { [self] response in
            busy = false
            switch response?.result {
            case "ok": if let next = response?.status { status = next }
            case nil: message = "Служба не отвечает."
            default: message = "Выбор не принят. Попробуйте ещё раз."
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
                message = response?.result == "administrator_required" ? "Нужны права администратора."
                    : "Профиль не получен."
                return
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikev2-manager-client-" + UUID().uuidString)
            let file = directory.appendingPathComponent("Waypoint.mobileconfig")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
                else { throw CocoaError(.fileWriteUnknown) }
            } catch { message = "Профиль не сохранён."; return }
            profileFile = file
            connectAfterRegistration = true
            NSWorkspace.shared.open(file)
            if let settings = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") { NSWorkspace.shared.open(settings) }
            message = "«Системные настройки» → «Основные» → «Управление устройством» → «Waypoint» → «Установить»."
        }
    }

    /// What the browsers of the person at this window are set to.
    @Published var selfResolving: [String] = []
    @Published var browsersTold = false

    func lookAtBrowsers() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let managed = URL(fileURLWithPath: "/Library/Managed Preferences")
        selfResolving = SystemPlan.selfResolvingBrowsers(support: support, managed: managed)
        browsersTold = SystemPlan.browsersTold(managed: managed)
    }

    /// Hands the system a profile that tells the browsers to ask it for names.
    /// The person installs it themselves, and removes it the same way.
    func offerBrowserProfile() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-browsers-" + UUID().uuidString)
        let file = directory.appendingPathComponent("Waypoint-browsers.mobileconfig")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: file.path, contents: SystemPlan.browserProfile(), attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        } catch { message = "Профиль не сохранён."; return }
        NSWorkspace.shared.open(file)
        openProfileSettings()
        message = "«Системные настройки» → «Основные» → «Управление устройством» → «Waypoint: browsers» → «Установить». Затем перезапустите браузеры."
    }

    func openProfileSettings() {
        if let settings = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") { NSWorkspace.shared.open(settings) }
    }

    var heading: String {
        guard let status else { return "Служба не отвечает" }
        switch status.state {
        case "protected": return "Доступ открыт"
        case "blocked": return "Доступ выключен"
        case "enrollment_required": return "Устройство не зарегистрировано"
        case "registration_pending": return "Регистрация"
        case "registration_error": return "Ошибка регистрации"
        case "profile_required": return "Нужен профиль VPN"
        case "connecting": return "Подключение"
        case "tunnel_connected": return "Проверка доступа"
        case "connection_error": return "Нет подключения"
        case "starting": return "Запуск"
        case "access_closed": return status.error == "no_services" ? "Сервисы не назначены" : "Доступ не разрешён"
        default: return "Ошибка службы"
        }
    }

    var detail: String {
        guard let status else { return "Переустановите программу." }
        switch status.state {
        case "protected": return status.fullTunnel ? "Весь трафик идёт через туннель." : "Сервисы идут через туннель."
        case "blocked": return status.blockWithoutTunnel ? "Сервисы заблокированы." : "Сервисы идут напрямую, без туннеля."
        case "enrollment_required": return "Нужна ссылка приглашения от администратора."
        case "registration_pending": return "Ожидается ответ сервера."
        case "registration_error": return "Настройки не получены. Повторите регистрацию."
        case "profile_required": return "Установите профиль в «Системных настройках»."
        case "connecting": return "Устанавливается туннель."
        case "tunnel_connected":
            switch status.error {
            case "path_connectionFailed": return "Нет связи с сервером."
            case "path_differentPolicy": return "Настройки обновляются."
            case "path_accessRejected": return "Доступ отозван администратором."
            default: return "Сервер ещё не подтвердил доступ."
            }
        case "connection_error":
            return status.error == "tunnel_takes_everything"
                ? "Сервер предложил направить в туннель весь трафик. Подключение отклонено."
                : status.error == "profile_mode" ? "Режим изменён администратором. Установите профиль заново."
                : "Туннель не установлен. Попытка повторится."
        case "access_closed": return status.error == "no_services" ? "Администратор не назначил этому устройству сервисов. Сайты открываются как обычно." : "Доступ для этого устройства выключен администратором."
        default: return "Состояние защиты не подтверждено. Подробности в отчёте."
        }
    }

    /// The one place downloads come from; the router supplies only a number.
    var update: (version: String, url: URL)? {
        let own = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        guard let release = status?.release, ClientStatusReport.newer(release, than: own),
              let url = URL(string: "https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v\(release)/Waypoint-\(release).pkg")
        else { return nil }
        return (release, url)
    }

    var version: String { "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0") }

    var report: String {
        guard let status, let data = try? JSONEncoder.pretty.encode(status) else { return "{\n  \"state\" : \"service_unavailable\"\n}" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Reports to the developer: their kind, the person's words, an address
    // for a reply if they give one, pictures they pasted and the state report
    // above if they tick it. The journal keeps each report's number and claim,
    // so support's answers can be read here and answered.
    @Published var reportMessage = ""
    @Published var reportSending = false
    @Published var reports: [SentReport] = []
    @Published var conversations: [String: ReportConversation] = [:]
    private let journal = ReportJournal()
    private var reportTimer: Timer?
    private var lookingAtReports = false

    /// Support's replies the person has not opened yet.
    var unread: Int { reports.reduce(0) { $0 + unread($1) } }
    func unread(_ report: SentReport) -> Int { max(0, (conversations[report.id]?.fromSupport ?? 0) - report.seen) }

    /// Asks the service about the twenty newest reports; one it no longer
    /// knows leaves the journal.
    func lookAtReports() {
        reports = journal.load()
        guard !lookingAtReports else { return }
        lookingAtReports = true
        let asked = Array(reports.prefix(20))
        Task {
            for report in asked {
                do {
                    let conversation = try await ProblemReporter().conversation(report)
                    await MainActor.run { conversations[report.id] = conversation }
                } catch ProblemReportError.gone {
                    try? journal.remove(report.id)
                    await MainActor.run { conversations[report.id] = nil }
                } catch {}
            }
            await MainActor.run { reports = journal.load(); lookingAtReports = false }
        }
    }

    /// The person opened REPORT: what support said so far is seen.
    func markRead(_ report: SentReport) {
        guard let conversation = conversations[report.id], conversation.fromSupport != report.seen else { return }
        try? journal.markSeen(report.id, conversation.fromSupport)
        reports = journal.load()
    }

    /// The person's answer on REPORT; called with true once it is sent.
    func answer(_ report: SentReport, _ text: String, done: @escaping @MainActor (Bool) -> Void) {
        guard !reportSending else { return }
        reportSending = true
        reportMessage = ""
        Task {
            do {
                try await ProblemReporter().reply(report, text)
                let conversation = try? await ProblemReporter().conversation(report)
                await MainActor.run {
                    if let conversation { conversations[report.id] = conversation }
                    reportSending = false
                    done(true)
                }
            } catch {
                await MainActor.run { reportMessage = Self.words(error); reportSending = false; done(false) }
            }
        }
    }

    static func words(_ error: Error) -> String {
        switch error as? ProblemReportError {
        case .unavailable: "Сервис отчётов сейчас не принимает отчёты Waypoint."
        case .busy: "Сервис отчётов занят; отправьте снова через несколько минут."
        case .unreachable: "Сервис отчётов недоступен. Проверьте интернет и отправьте снова."
        case .gone: "Обращение больше не найдено на сервере."
        case .refused(let status, let code): "Сервис отклонил отчёт (" + String(status) + (code.isEmpty ? "" : ", " + code) + ")."
        case nil: "Отчёт не отправлен."
        }
    }

    /// Called with true when the report went out, so the form can be cleared.
    func sendReport(_ text: String, kind: ReportKind, contact: String, attach: Bool, pictures: [Data], done: @escaping @MainActor (Bool) -> Void) {
        guard !reportSending else { return }
        reportSending = true
        reportMessage = "Отправка…"
        var context: [String: String] = ["app_version": version.replacingOccurrences(of: "v", with: ""),
                                         "os_version": "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
                                         "language": Locale.preferredLanguages.first ?? ""]
        #if arch(arm64)
        context["architecture"] = "arm64"
        #else
        context["architecture"] = "x86_64"
        #endif
        if let state = status?.state { context["failure_code"] = state }
        var files = pictures.enumerated().map { index, data in
            data.starts(with: [0xff, 0xd8, 0xff])
                ? ReportFile(name: "picture-\(index + 1).jpg", contentType: "image/jpeg", data: data)
                : ReportFile(name: "picture-\(index + 1).png", contentType: "image/png", data: data)
        }
        if attach { files.append(ReportFile(name: "waypoint-state.json", contentType: "application/json", data: Data(report.utf8))) }
        Task {
            do {
                let sent = try await ProblemReporter().send(description: text, kind: kind, reporter: ReporterIdentity.id(),
                                                            contact: contact, context: context, files: files)
                await MainActor.run {
                    try? journal.add(sent)
                    reports = journal.load()
                    reportMessage = "Отправлено. Ответ поддержки появится во вкладке «Мои обращения»."
                    reportSending = false
                    done(true)
                }
            } catch {
                await MainActor.run { reportMessage = Self.words(error); reportSending = false; done(false) }
            }
        }
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
        // Nothing is wrong when the device simply has no service yet.
        if status.state == "access_closed", status.error == "no_services" { return .off }
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

struct AddressRow: View {
    let label: String
    let value: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(value.isEmpty ? "Нет данных" : value)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).help(value)
                Button {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(value, forType: .string) {
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless).disabled(value.isEmpty)
                .help(copied ? "Скопировано" : "Скопировать")
                .accessibilityLabel("Скопировать: " + label)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }
}

struct AddressCard: View {
    let addresses: ConnectionAddresses?
    var body: some View {
        Card(title: "Адреса Waypoint") {
            Text("Для исключений в другом VPN.")
                .font(.caption).foregroundStyle(.secondary)
            AddressRow(label: "Сервер", value: addresses?.server ?? "")
            AddressRow(label: "IP сервера", value: addresses?.serverIP ?? "")
            AddressRow(label: "Сеть сервисов", value: addresses?.services ?? "")
            AddressRow(label: "Сеть туннеля", value: addresses?.tunnel ?? "")
            Text("Используйте домен или IP сервера.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What the person was offered: each service on or off and what becomes of it
/// without the tunnel. Required ones only say so; the rest are theirs to switch.
struct ServiceList: View {
    let entries: [ServiceEntry]
    @ObservedObject var model: ClientModel
    var body: some View {
        if entries.isEmpty {
            Text("Не назначены").foregroundStyle(.secondary)
        }
        ForEach(entries, id: \.id) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if entry.required {
                        Text(entry.label).bold()
                        Spacer()
                        Text("обязательный").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle(isOn: Binding(get: { entry.on }, set: { model.choose(entry, on: $0) })) { Text(entry.label).bold() }
                            .toggleStyle(.switch).disabled(model.busy)
                    }
                }
                if entry.on {
                    if entry.chooseClosed {
                        Toggle("Блокировать без туннеля", isOn: Binding(get: { entry.closed }, set: { model.choose(entry, closed: $0) }))
                            .font(.caption).disabled(model.busy)
                    } else {
                        Text(entry.closed ? "Без туннеля блокируется" : "Без туннеля идёт напрямую").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text([entry.domains > 0 ? "доменов: \(entry.domains)" : "", entry.networks > 0 ? "сетей: \(entry.networks)" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
    }
}

/// The menu-bar item: the state at a glance, the switch, and the services
/// the person may turn on - the window is for everything else.
struct MenuBarView: View {
    @ObservedObject var model: ClientModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.tone.symbol).foregroundStyle(model.tone.color)
                Text(model.heading).bold()
            }
            Text(model.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let status = model.status, status.guardInstalled, status.profileInstalled, status.state != "access_closed" {
                Toggle("Waypoint", isOn: Binding(get: { status.wanted }, set: { model.command($0 ? "connect" : "disconnect") }))
                    .toggleStyle(.switch).disabled(model.busy)
            }
            if let entries = model.status?.entries, entries.contains(where: { !$0.required }) {
                Divider()
                ForEach(entries.filter { !$0.required }, id: \.id) { entry in
                    Toggle(entry.label, isOn: Binding(get: { entry.on }, set: { model.choose(entry, on: $0) })).disabled(model.busy)
                }
            }
            Divider()
            HStack {
                Button("Открыть Waypoint") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.start() }
    }
}

/// The reports sent from this Mac: a list, and for the one opened its
/// conversation with support and a field to answer.
struct ReportsView: View {
    @ObservedObject var model: ClientModel
    @State private var opened: String?
    @State private var answerText = ""

    var body: some View {
        if let id = opened, let report = model.reports.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { opened = nil; answerText = "" } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                    Text(report.kind.label + " · " + report.title).bold().lineLimit(1)
                    Spacer()
                    if let conversation = model.conversations[report.id] { Text(conversation.stateLabel).foregroundStyle(.secondary) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        let replies = model.conversations[report.id]?.replies ?? []
                        if replies.isEmpty { Text("Ответов пока нет.").foregroundStyle(.secondary) }
                        ForEach(Array(replies.enumerated()), id: \.offset) { _, reply in
                            HStack {
                                if reply.from == .reporter { Spacer(minLength: 60) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reply.from == .support ? "Поддержка" : "Вы").font(.caption).foregroundStyle(.secondary)
                                    Text(reply.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    if let created = reply.createdAt {
                                        Text(created.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(reply.from == .support ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.15)))
                                if reply.from == .support { Spacer(minLength: 60) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 520, height: 260)
                TextEditor(text: $answerText).font(.body).frame(width: 520, height: 60)
                    .overlay(alignment: .topLeading) {
                        if answerText.isEmpty { Text("Ответ поддержке").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                if !model.reportMessage.isEmpty { Text(model.reportMessage).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Ответить") { model.answer(report, answerText) { sent in if sent { answerText = "" } } }
                        .disabled(model.reportSending || answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || answerText.count > 5000)
                }
            }
            .onAppear { model.markRead(report) }
            .onChange(of: model.conversations[report.id]?.fromSupport) { model.markRead(report) }
        } else if model.reports.isEmpty {
            Text("Отсюда ещё ничего не отправляли.").foregroundStyle(.secondary).frame(width: 520, height: 120)
        } else {
            List(model.reports) { report in
                Button { model.reportMessage = ""; opened = report.id } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.title.isEmpty ? report.kind.label : report.title).lineLimit(1)
                            Text(report.kind.label + " · " + report.sentAt.formatted(date: .abbreviated, time: .omitted) +
                                 (model.conversations[report.id].map { " · " + $0.stateLabel } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.unread(report) > 0 {
                            Text("\(model.unread(report))").font(.caption.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.accentColor))
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .frame(width: 520, height: 320)
        }
    }
}

struct ClientView: View {
    @ObservedObject var model: ClientModel
    @State private var invitation = ""
    @State private var registering = false
    @State private var reporting = false
    @State private var problem = ""
    @State private var problemContact = ""
    @State private var problemAttach = true
    @State private var problemKind: ReportKind = .bug
    /// 0: a new report; 1: the reports sent from here and their conversations.
    @State private var reportTab = 0
    /// Pictures pasted with ⌘V or dropped on the form, as PNG or JPEG.
    @State private var problemPictures: [Data] = []
    @State private var pasteMonitor: Any?
    @State private var browsing = false
    @State private var removing = false
    /// "system", "light" or "dark": the look the user chose for this window.
    @AppStorage("theme") private var theme = "system"

    var body: some View {
        let status = model.status
        HStack(alignment: .top, spacing: 20) {
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
                Spacer(minLength: 0)
                // The look of the window: a small sign in the corner, away from the actions.
                Menu {
                    Picker("Тема", selection: $theme) {
                        Text("Как в системе").tag("system"); Text("Светлая").tag("light"); Text("Тёмная").tag("dark")
                    }.pickerStyle(.inline).labelsHidden()
                } label: { Image(systemName: "circle.lefthalf.filled").font(.system(size: 15)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Тема")
            }
            Card(title: "Проверки") {
                let fresh = status?.state == "enrollment_required"
                let relaxed = status?.blockWithoutTunnel == false
                let idle = status?.state == "access_closed" && status?.error == "no_services"
                CheckRow(label: "Блокировка вне туннеля", value: idle ? "не нужна" : relaxed ? "выключена администратором" : status?.guardInstalled == true ? "включена" : fresh ? "после регистрации" : "не подтверждена",
                         tone: idle || relaxed ? .off : status?.guardInstalled == true ? .open : fresh ? .off : .attention)
                CheckRow(label: "Туннель", value: status?.routed == true ? "подключён" : status?.state == "connecting" ? "подключается" : "нет",
                         tone: status?.routed == true ? .open : status?.state == "connecting" ? .working : .off)
                CheckRow(label: "Подтверждение сервера", value: status?.protected == true ? "получено" : "нет",
                         tone: status?.protected == true ? .open : status?.routed == true ? .working : .off)
                CheckRow(label: "DNS в браузерах",
                         value: !model.selfResolving.isEmpty ? model.selfResolving.joined(separator: ", ") + ": свой DoH, в обход туннеля" : model.browsersTold ? "системный DNS, задано Waypoint" : "системный DNS",
                         tone: !model.selfResolving.isEmpty ? .attention : fresh ? .off : .open)
            }
            Card(title: "Сервисы") {
                if let entries = status?.entries {
                    ServiceList(entries: entries, model: model)
                } else if let status, !status.services.isEmpty {
                    Text(status.services.joined(separator: " · ")).bold().fixedSize(horizontal: false, vertical: true)
                    Text("Доменов: \(status.domains)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(status == nil ? "Нет данных" : status?.domains == 0 || (status?.state == "access_closed" && status?.error == "no_services") ? "Не назначены" : "Доменов: \(status?.domains ?? 0)")
                        .foregroundStyle(.secondary)
                }
                if let status, !status.available.isEmpty {
                    Text("По запросу: " + status.available.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let update = model.update {
                HStack {
                    Text("Доступна версия \(update.version).").fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Обновить") { NSWorkspace.shared.open(update.url) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tone.working.color.opacity(0.12)))
            }
            if let warnings = status?.warnings, !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if warnings.contains("vpn") { Text("Работает другой VPN: сервисы могут не открываться, пока он включён.") }
                    if warnings.contains("proxy") { Text("Включён системный прокси: трафик через него идёт в обход туннеля.") }
                }
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tone.working.color.opacity(0.12)))
            }
            if model.unread > 0 {
                HStack {
                    Text("Поддержка ответила на ваше обращение.").fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Открыть") { reportTab = 1; reporting = true }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tone.open.color.opacity(0.12)))
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                primaryAction(status)
                Spacer()
                if !model.selfResolving.isEmpty || model.browsersTold { Button("Браузеры…") { browsing = true } }
                Button("Проверить") { model.refresh(); model.lookAtBrowsers() }
                Button("Отчёт…") { reporting = true }
                Button("Сбросить…") { removing = true }.buttonStyle(.borderedProminent).tint(Tone.attention.color)
                    .disabled(status == nil || status?.state == "enrollment_required")
            }.fixedSize(horizontal: false, vertical: true).disabled(model.busy)
            Text("Проверено " + model.checked.formatted(date: .omitted, time: .standard) + " · " + model.version)
                .foregroundStyle(.secondary).font(.caption)
        }
        .frame(width: 496)
        AddressCard(addresses: status?.addresses).frame(width: 280)
        }
        .padding(22)
        .frame(width: 840)
        // The window is as tall as what it shows and no shorter than its
        // usual height: when a notice appears - a newer version, a warning -
        // the window grows by it instead of squeezing everything above.
        .frame(minHeight: 420, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { applyTheme(); model.start(); model.lookAtBrowsers() }
        .onChange(of: theme) { applyTheme() }
        .sheet(isPresented: $registering) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ссылка приглашения").font(.headline)
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
        .confirmationDialog("Сбросить Waypoint на этом Mac?", isPresented: $removing) {
            Button("Сбросить", role: .destructive) { model.command("reset") }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Будут удалены: профиль VPN, блокировки, DNS-записи сервисов и регистрация устройства. Программа останется; чтобы вернуть доступ, понадобится новая ссылка от администратора.")
        }
        .confirmationDialog("DNS в браузерах", isPresented: $browsing) {
            if model.browsersTold {
                Button("Открыть «Управление устройством»") { model.openProfileSettings() }
            } else {
                Button("Подготовить профиль") { model.offerBrowserProfile() }
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text(model.browsersTold
                 ? "Waypoint задал браузерам политику «использовать системный DNS» отдельным профилем. Чтобы вернуть браузерам их собственную настройку, удалите профиль «Waypoint: browsers» в «Управлении устройством»."
                 : "Браузер со своим DNS поверх HTTPS (DoH)" + (model.selfResolving.isEmpty ? "" : " (" + model.selfResolving.joined(separator: ", ") + ")") + ", открывает сервисы в обход туннеля. Waypoint может подготовить профиль, который задаёт Chrome, Edge, Brave, Яндекс Браузеру и Firefox политику «использовать системный DNS». Она действует для всех сайтов; установить и удалить профиль можете только вы.")
        }
        .sheet(isPresented: $reporting) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $reportTab) {
                    Text("Новое обращение").tag(0)
                    Text(model.unread > 0 ? "Мои обращения (\(model.unread))" : "Мои обращения").tag(1)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 520)
                if reportTab == 1 {
                    ReportsView(model: model)
                    HStack { Spacer(); Button("Закрыть") { reporting = false } }
                } else {
                Text("Отчёт").font(.headline)
                ScrollView { Text(model.report).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(width: 520, height: 200)
                Divider()
                Text("Написать разработчику").font(.subheadline).bold()
                Picker("", selection: $problemKind) {
                    ForEach(ReportKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 520)
                TextEditor(text: $problem).font(.body).frame(width: 520, height: 80)
                    .overlay(alignment: .topLeading) {
                        if problem.isEmpty { Text("Что случилось и что вы делали перед этим").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                Text("Скриншот можно вставить через ⌘V или перетащить в это окно.").font(.caption).foregroundStyle(.secondary)
                if !problemPictures.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(problemPictures.enumerated()), id: \.offset) { index, data in
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill() }
                                    else { Color.secondary.opacity(0.2) }
                                }
                                .frame(width: 96, height: 72).clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                                Button { problemPictures.remove(at: index) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }.buttonStyle(.plain).padding(3).help("Убрать")
                            }
                        }
                    }
                }
                TextField("Почта для ответа (необязательно)", text: $problemContact).frame(width: 520)
                Toggle("Приложить отчёт выше", isOn: $problemAttach)
                if !model.reportMessage.isEmpty { Text(model.reportMessage).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("Скопировать") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.report, forType: .string) }
                    Spacer()
                    Button("Закрыть") { reporting = false }
                    Button("Отправить") {
                        let contact = problemContact.trimmingCharacters(in: .whitespaces)
                        model.sendReport(problem.trimmingCharacters(in: .whitespacesAndNewlines), kind: problemKind, contact: contact,
                                         attach: problemAttach, pictures: problemPictures) { sent in
                            guard sent else { return }
                            problem = ""
                            problemContact = ""
                            problemPictures = []
                        }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(model.reportSending || problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  !(problemContact.isEmpty || problemContact.range(of: "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]+$", options: .regularExpression) != nil))
                }
                }
            }.padding(20)
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                for provider in providers {
                    if provider.canLoadObject(ofClass: URL.self) {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url, let data = try? Data(contentsOf: url) else { return }
                            DispatchQueue.main.async { addPicture(data) }
                        }
                    } else {
                        provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                            guard let data else { return }
                            DispatchQueue.main.async { addPicture(data) }
                        }
                    }
                }
                return true
            }
            .onAppear {
                model.reportMessage = ""
                if reportTab == 1 { model.lookAtReports() }
                // ⌘V with a picture on the clipboard and no text: the picture
                // goes to the report, wherever the cursor is in the form.
                pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers == "v",
                          NSPasteboard.general.string(forType: .string) == nil,
                          let data = Self.pastedPicture() else { return event }
                    addPicture(data)
                    return nil
                }
            }
            .onDisappear {
                if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
                pasteMonitor = nil
            }
        }
    }

    /// The picture on the clipboard as PNG or JPEG, if there is one.
    static func pastedPicture() -> Data? {
        let board = NSPasteboard.general
        if let png = board.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Adds a picture the service takes: PNG or JPEG of up to 5 MB, five at most.
    private func addPicture(_ data: Data) {
        var picture = data
        if !(data.starts(with: [0x89, 0x50, 0x4e, 0x47]) || data.starts(with: [0xff, 0xd8, 0xff])) {
            guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                model.reportMessage = "Приложить можно только картинку."
                return
            }
            picture = png
        }
        guard problemPictures.count < 5 else { model.reportMessage = "Можно приложить не больше пяти картинок."; return }
        guard picture.count <= 5 * 1024 * 1024 else { model.reportMessage = "Картинку больше 5 МБ приложить нельзя."; return }
        problemPictures.append(picture)
    }

    /// The whole application takes the look at once. Asking SwiftUI to go back
    /// to "no preference" left half of the window in the previous look.
    private func applyTheme() {
        NSApp.appearance = theme == "light" ? NSAppearance(named: .aqua) : theme == "dark" ? NSAppearance(named: .darkAqua) : nil
    }

    /// The one thing to do next, as the prominent button.
    @ViewBuilder private func primaryAction(_ status: ClientStatusReport?) -> some View {
        if status?.state == "enrollment_required" || status?.state == "registration_error" {
            Button("Регистрация…") { registering = true }.buttonStyle(.borderedProminent).fixedSize()
        } else if status?.state == "profile_required" || (status?.state == "connection_error" && status?.error == "profile_mode") {
            Button("Установить профиль…") { model.installProfile() }.buttonStyle(.borderedProminent).fixedSize()
        } else if status?.state == "connecting" {
            Button("Отключить") { model.command("disconnect") }
        } else if status?.state == "access_closed" {
            // Nothing to switch on until the administrator assigns a service or opens access.
            EmptyView()
        } else if let status, status.guardInstalled, status.profileInstalled {
            if status.wanted { Button("Отключить") { model.command("disconnect") } }
            else { Button("Включить") { model.command("connect") }.buttonStyle(.borderedProminent) }
        }
    }
}

@main
struct ClientApplication: App {
    @StateObject private var model = ClientModel()
    var body: some Scene {
        Window("Waypoint", id: "main") { ClientView(model: model) }.windowResizability(.contentSize)
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.status?.state == "protected" ? "lock.shield.fill" : "shield")
        }
        .menuBarExtraStyle(.window)
    }
}
