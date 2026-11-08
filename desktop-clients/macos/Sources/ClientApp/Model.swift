import AppKit
import ClientCore
import ServiceManagement
import SwiftUI

/// What the window shows: the daemon's last answer, or why there is none.
@MainActor
final class ClientModel: ObservableObject {
    @Published var status: ClientStatusReport?
    @Published var message = ""
    @Published var busy = false
    @Published var checked = Date()
    /// Whether the window has had an answer at all, and whether the last question went unanswered.
    @Published var asked = false
    @Published var failed = false
    private var timer: Timer?
    private var connectAfterRegistration = false
    private var profileFile: URL?

    private var started = false
    /// Pictures of the views for checking them: the model asks nobody.
    var offline = false
    func start() {
        // The window and the menu-bar item share this model; it starts once.
        guard !started, !offline else { return }
        started = true
        // The daemon installs; the person's choice is told to it at every start.
        ask(Control.Request(op: "auto_update", on: [installUpdates ? "on" : "off"])) { _ in }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        lookAtReports()
        autoTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAutoReports() }
        }
        // Not in the first seconds after launch: the queue itself waits ten.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.runAutoReports() }
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
            asked = true
            failed = response?.status == nil
            // An answer that did not come keeps the last one, marked as stale by `failed`.
            if let next = response?.status { status = next; checked = Date() }
            guard let status, !failed else { return }
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
    /// blocked without the tunnel where that is theirs to decide. The row
    /// changes at once and waits by itself; the others stay usable. A refusal
    /// puts it back and says why under the row.
    @Published var pending: [String: (on: Bool, closed: Bool)] = [:]
    @Published var choiceError: [String: String] = [:]

    func shown(_ entry: ServiceEntry) -> (on: Bool, closed: Bool) { pending[entry.id] ?? (entry.on, entry.closed) }

    func choose(_ entry: ServiceEntry, on: Bool? = nil, closed: Bool? = nil) {
        guard let entries = status?.entries else { return }
        let current = shown(entry)
        pending[entry.id] = (on ?? current.on, closed ?? current.closed)
        choiceError[entry.id] = nil
        var turnedOn = Set<String>(), blocked = Set<String>()
        for item in entries {
            let wanted = shown(item)
            if !item.required && wanted.on { turnedOn.insert(item.id) }
            if item.chooseClosed && wanted.closed { blocked.insert(item.id) }
        }
        ask(Control.Request(op: "choose", on: turnedOn.sorted(), closed: blocked.sorted())) { [self] response in
            pending[entry.id] = nil
            switch response?.result {
            case "ok": if let next = response?.status { status = next }
            case nil: choiceError[entry.id] = "Служба не отвечает."
            default: choiceError[entry.id] = "Роутер не принял выбор."
            }
        }
    }

    /// Asks the router to check the services now.
    @Published var checkMessage = ""
    func checkNow() {
        checkMessage = "Проверяю…"
        ask(Control.Request(op: "check")) { [self] response in
            switch response?.result {
            case "ok": checkMessage = "Роутер проверяет; итог через несколько секунд."
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.refresh(); self?.checkMessage = "" }
            case "check_too_often": checkMessage = "Снова можно через \(response?.retryAfter ?? 30) с."
            case "check_busy": checkMessage = "Проверка уже идёт."
            case nil: checkMessage = "Служба не отвечает."
            default: checkMessage = "Роутер не принял просьбу."
            }
        }
    }

    /// The person's own sites and networks for this Mac, sent as a whole list.
    /// Entries sent and not yet in the router's list: shown as "waiting for the router".
    @Published var ownWaiting: [String] = []
    @Published var ownHintShown = false

    /// Adds what the person typed, checked here as the router would first.
    func addOwn(_ text: String) -> String? {
        guard let own = status?.own else { return "Добавлять свои адреса не разрешено." }
        let server = [status?.addresses?.server ?? ""].filter { !$0.isEmpty }
        switch OwnAddresses.check(text, server: server) {
        case .failure(let refusal): return WindowText.ownRefusal(refusal.reason)
        case .success(let parsed):
            var domains = own.domains, networks = own.networks
            if let domain = parsed.domain { guard !domains.contains(domain) else { return "Уже в списке." }; domains.append(domain) }
            if let network = parsed.network { guard !networks.contains(network) else { return "Уже в списке." }; networks.append(network) }
            guard domains.count + networks.count <= own.limit else { return WindowText.ownRefusal("over_limit") }
            ownWaiting.append(parsed.domain ?? parsed.network ?? "")
            setOwn(domains: domains, networks: networks)
            return nil
        }
    }

    func setOwn(domains: [String], networks: [String]) {
        guard !busy else { return }
        busy = true
        message = ""
        ask(Control.Request(op: "own", domains: domains, networks: networks)) { [self] response in
            busy = false
            if let next = response?.status { status = next }
            switch response?.result {
            case "ok": ownHintShown = true
            case "own_refused": ownWaiting = []; message = "Роутер не принял адрес: нужен публичный сайт или адрес, не частная сеть."
            case "own_not_allowed": message = "Добавлять свои адреса больше не разрешено."
            case "own_too_often": message = "Слишком много изменений за сутки. Попробуйте завтра."
            case nil: message = "Служба не отвечает."
            default: message = "Список не принят. Попробуйте ещё раз."
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

    var heading: String { phrase.heading }

    var detail: String { phrase.detail }

    private var phrase: StatusPhrases.Phrase {
        guard let status else { return StatusPhrases.unavailable }
        return StatusPhrases.phrase(state: status.state, error: status.error, full: status.fullTunnel, direct: !status.blockWithoutTunnel)
    }

    /// The one place downloads come from; the router supplies only a number.
    var update: (version: String, url: URL)? {
        let own = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        guard let release = status?.release, ClientStatusReport.newer(release, than: own),
              let url = URL(string: "https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v\(release)/Waypoint-\(release).pkg")
        else { return nil }
        return (release, url)
    }

    // MARK: reset, settings, first launch

    @Published var resetText = ""
    func reset() {
        resetText = "Сбрасываю…"
        ask(Control.Request(op: "reset")) { [self] response in
            if let next = response?.status { status = next }
            switch response?.result {
            case "administrator_required": resetText = "Нужны права администратора."
            case nil: resetText = "Служба не отвечает."
            default: resetText = response?.reset.map(WindowText.resetSummary) ?? "Сброс не выполнен."
            }
        }
    }

    /// Opening at login is the system's own setting for this program.
    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { message = "Не удалось изменить запуск при входе." }
        }
    }

    /// Automatic failure reports: nil until the person answered once.
    var sendReports: Bool? {
        get { UserDefaults.standard.object(forKey: "autoReports") as? Bool }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "autoReports")
            if newValue != true { Task { await autoReporter.clear() } }
        }
    }

    var installUpdates: Bool {
        get { UserDefaults.standard.object(forKey: "installUpdates") as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "installUpdates")
            ask(Control.Request(op: "auto_update", on: [newValue ? "on" : "off"])) { _ in }
        }
    }

    /// The first launch after registration, or the first of this version on a
    /// device registered before: once.
    var firstRunDue: Bool {
        guard let status, !["enrollment_required", "registration_pending", "registration_error", "starting"].contains(status.state)
        else { return false }
        return !UserDefaults.standard.bool(forKey: "firstRunDone")
    }

    func finishFirstRun(_ choices: FirstRunChoices) {
        guard choices.canFinish else { return }
        openAtLogin = choices.openAtLogin
        installUpdates = choices.installUpdates
        sendReports = choices.sendReports
        UserDefaults.standard.set(true, forKey: "firstRunDone")
        objectWillChange.send()
    }

    // MARK: automatic failure reports

    let launchedAt = Date()
    private var autoTimer: Timer?
    lazy var autoReporter: AutoReporter = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Waypoint")
        var about = ["app_version": version.replacingOccurrences(of: "v", with: ""),
                     "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                     "os_version": "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
                     "language": Locale.preferredLanguages.first ?? "", "architecture": "arm64"]
        #if !arch(arm64)
        about["architecture"] = "x86_64"
        #endif
        return AutoReporter(file: support.appendingPathComponent("auto-reports.json"), journal: journal, about: about,
                            reporterID: ReporterIdentity.id())
    }()

    /// Takes the daemon's faults and new crash reports, then sends what may go.
    func runAutoReports() {
        let consent = sendReports, status = status, auto = autoReporter, launched = launchedAt
        ask(Control.Request(op: "faults")) { response in
            let faults = response?.faults ?? []
            Task.detached {
                await auto.take(daemonFaults: faults)
                let home = FileManager.default.homeDirectoryForCurrentUser
                await auto.takeCrashLogs(in: [home.appendingPathComponent("Library/Logs/DiagnosticReports"),
                                              URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")])
                await auto.send(now: Date(), launchedAt: launched, consent: consent, status: status, faults: faults)
            }
        }
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
        case .tooMany(let seconds): "Слишком много отчётов подряд; отправьте снова через \(max(1, seconds / 60)) мин."
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
