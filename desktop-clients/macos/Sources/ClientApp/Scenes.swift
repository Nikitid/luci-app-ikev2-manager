import AppKit
import ClientCore
import SwiftUI

// MARK: Reports

struct ReportsView: View {
    @ObservedObject var model: ClientModel
    @State private var selected: String?
    @State private var writing = false

    var body: some View {
        HSplitView {
            List(model.reports, selection: $selected) { report in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.title.isEmpty ? report.kind.label : report.title).lineLimit(1)
                        Text((report.kind == .crash ? "автоматически · " : "") + (model.conversations[report.id]?.stateLabel ?? "отправлено") +
                             " · " + report.sentAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .badge(model.unread(report))
                .tag(report.id)
            }
            .frame(minWidth: 220, idealWidth: 260)
            .overlay { if model.reports.isEmpty { Text("Обращений пока нет.").foregroundStyle(.secondary) } }
            Group {
                if let report = model.reports.first(where: { $0.id == selected }) {
                    Conversation(model: model, report: report)
                } else {
                    Text("Выберите обращение или напишите новое.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 300)
        }
        .toolbar { ToolbarItem { Button { writing = true } label: { Label("Новое обращение", systemImage: "square.and.pencil") } } }
        .sheet(isPresented: $writing) { NewReportSheet(model: model) }
        .onChange(of: selected) { _, id in if let report = model.reports.first(where: { $0.id == id }) { model.markRead(report) } }
    }
}

struct Conversation: View {
    @ObservedObject var model: ClientModel
    let report: SentReport
    @State private var answer = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((model.conversations[report.id]?.replies ?? []).enumerated()), id: \.offset) { _, reply in
                        let own = reply.from == .reporter
                        Text(reply.body).textSelection(.enabled)
                            .padding(10)
                            .background(own ? Palette.accentSoft : Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(own ? Palette.accent.opacity(0.35) : Palette.line, lineWidth: 1))
                            .frame(maxWidth: .infinity, alignment: own ? .trailing : .leading)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                TextField("Ответ поддержке", text: $answer, axis: .vertical).lineLimit(1...4)
                Button("Отправить") { model.answer(report, answer) { if $0 { answer = "" } } }
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.reportSending)
            }
            .padding(12)
            if !model.reportMessage.isEmpty { Text(model.reportMessage).font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 12) }
        }
    }
}

struct NewReportSheet: View {
    @ObservedObject var model: ClientModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = ReportKind.bug
    @State private var text = ""
    @State private var contact = ""
    @State private var network = false
    @State private var pictures: [Data] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Новое обращение").font(.headline)
            Picker("Тип", selection: $kind) { ForEach(ReportKind.chosen, id: \.self) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            TextEditor(text: $text).font(.body).frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            HStack {
                Button("Вставить картинку") { if let data = Self.pastedPicture(), pictures.count < 5 { pictures.append(data) } }
                Text(pictures.isEmpty ? "⌘V в поле или кнопкой, до 5" : "Картинок: \(pictures.count)").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Почта для ответа (необязательно)", text: $contact).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("Вместе с текстом уйдёт").font(.subheadline).foregroundStyle(.secondary)
                Text("· версии Waypoint и macOS").font(.caption)
                Text("· состояние Waypoint: \(model.status?.state ?? "нет ответа службы") (\(model.status?.error ?? "—"))").font(.caption)
                Toggle("Сеть этого Mac: имя и адрес сервера, сети", isOn: $network).font(.caption)
            }
            HStack {
                Text(model.reportMessage).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Отправить") {
                    model.sendReport(text, kind: kind, contact: contact, attach: network, pictures: pictures) { if $0 { dismiss() } }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.reportSending)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    static func pastedPicture() -> Data? {
        let board = NSPasteboard.general
        if let png = board.data(forType: .png) { return png }
        if let tiff = board.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff) { return image.representation(using: .png, properties: [:]) }
        return nil
    }
}

// MARK: First launch

/// Right after registration, over the whole window: three decisions. Done
/// only once reports have an answer; closed without one, nothing is sent.
struct FirstRunView: View {
    @ObservedObject var model: ClientModel
    @State private var choices = FirstRunChoices()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WaypointSign(visible: model.visible, size: 18)
            Text("Почти готово").font(.system(size: 28, weight: .thin))
            Text("Waypoint зарегистрирован на этом Mac. Всё это меняется в Настройках.").foregroundStyle(.secondary)
            Panel {
                PanelRow { SwitchRow(title: "Открывать при входе в систему", note: "Значок появится в строке меню сам.", isOn: $choices.openAtLogin) }
                PanelRow { SwitchRow(title: "Ставить обновления сами", note: "Когда туннель не нужен; только проверенный файл.", isOn: $choices.installUpdates) }
                PanelRow(last: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Отчёты о сбоях")
                        Text("Коды ошибок, версии и журнал сбоев. Адреса, имена сайтов и сетей остаются на этом Mac.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Picker("Отчёты о сбоях", selection: $choices.sendReports) {
                            Text("Отправлять разработчику автоматически").tag(Bool?.some(true))
                            Text("Не отправлять").tag(Bool?.some(false))
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                    }
                }
            }
            HStack {
                Spacer()
                if !choices.canFinish { Text("после ответа про отчёты").font(.caption).foregroundStyle(.secondary) }
                Button("Готово") { model.finishFirstRun(choices) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!choices.canFinish)
            }
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
    }
}

/// A title, a note under it and the switch on the right edge.
struct SwitchRow: View {
    let title: String
    let note: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @ObservedObject var model: ClientModel
    @AppStorage("theme") private var theme = "system"
    @State private var confirmReset = false

    var body: some View {
        Form {
            Toggle("Открывать при входе в систему", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
            Picker("Тема", selection: $theme) {
                Text("Как в системе").tag("system")
                Text("Светлая").tag("light")
                Text("Тёмная").tag("dark")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: Binding(get: { model.installUpdates }, set: { model.installUpdates = $0 })) {
                Text("Ставить обновления сами")
                Text("Когда туннель не нужен: ночью или при выходе из Waypoint. Только файл, проверенный ключом проекта.")
            }
            Toggle(isOn: Binding(get: { model.sendReports == true }, set: { model.sendReports = $0 })) {
                Text("Отправлять отчёты о сбоях автоматически")
                Text("Коды ошибок, версии и журнал сбоев. Адреса, имена сайтов и сетей остаются на этом Mac.")
            }
            LabeledContent {
                Button(model.browsersTold ? "Задано" : "Задать…") { model.offerBrowserProfile() }.disabled(model.browsersTold)
            } label: {
                Text("DNS в браузерах")
                Text(model.selfResolving.isEmpty ? "Chrome и Firefox спрашивают имена сами, в обход туннеля. Waypoint может задать им системный DNS."
                     : model.selfResolving.joined(separator: ", ") + " спрашивают имена в обход туннеля.")
            }
            LabeledContent {
                Button("Сбросить…") { confirmReset = true }
            } label: {
                Text("Сбросить Waypoint на этом Mac")
                Text(model.resetText.isEmpty ? "Удалит профиль VPN, блокировку, имена сервисов и регистрацию; скажет, что удалено." : model.resetText)
            }
            Text("Waypoint \(model.version.dropFirst()) · Apple silicon").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .tint(Palette.accent)
        .onAppear { model.start(); model.lookAtBrowsers() }
        .onChange(of: theme) { _, value in Theme.apply(value) }
        .confirmationDialog("Сбросить Waypoint на этом Mac?", isPresented: $confirmReset) {
            Button("Сбросить", role: .destructive) { model.reset() }
        } message: {
            Text("Регистрация пропадёт; для новой нужна новая ссылка от администратора.")
        }
    }
}

enum Theme {
    static func apply(_ value: String) {
        NSApp.appearance = value == "light" ? NSAppearance(named: .aqua) : value == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
}

// MARK: Menu bar

/// The menu: state and switch, the optional services, a newer version and
/// the way into the window. The set is changed in the window only.
struct MenuView: View {
    @ObservedObject var model: ClientModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.failed ? nil : model.status
        let attention = model.visible == "attention"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                WaypointSign(visible: model.visible, size: 14)
                Text(model.headingText).font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("Waypoint", isOn: model.connectionWanted).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!model.switchable || model.busy)
            }
            if attention || status == nil {
                Text(WindowText.detail(status)).font(.callout).foregroundStyle(attention ? Palette.danger : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(attention ? Palette.danger.opacity(0.55) : Palette.line).frame(height: 1)
            HStack {
                Text(status?.addresses?.server ?? "").lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(WindowText.nextAttempt(status) ?? "проверено " + WindowText.clock(model.checked)).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            if let status, ["connection_error", "error"].contains(status.state), status.wanted {
                Button("Подключить снова") { model.command("connect") }.buttonStyle(.borderedProminent).disabled(model.busy)
            } else if status?.state == "profile_required" {
                Button("Установить профиль…") { model.installProfile() }.buttonStyle(.borderedProminent)
            } else if status?.state == "enrollment_required" {
                Button("Зарегистрировать…") { open() }.buttonStyle(.borderedProminent)
            }
            // The question of the first launch, if its page was closed without an answer.
            if model.sendReports == nil, model.firstRunDue {
                Button("Отправлять отчёты о сбоях? Ответить…") { open() }.buttonStyle(.link).font(.caption).foregroundStyle(Palette.accent)
            }
            let optional = (status?.entries ?? []).filter { !$0.required && model.shown($0).on && !OwnAddresses.isService($0.id) }
            if !optional.isEmpty {
                Text("По выбору").font(.caption).foregroundStyle(.secondary)
                ForEach(optional, id: \.id) { entry in
                    HStack {
                        Text(entry.label).lineLimit(1)
                        Spacer()
                        Text(status?.state == "protected" ? WindowText.withoutTunnel(entry) : entry.closed ? "сейчас закрыт" : "сейчас напрямую")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle(entry.label, isOn: Binding(get: { model.shown(entry).on }, set: { model.choose(entry, on: $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.pending[entry.id] != nil)
                    }
                }
            }
            if let update = model.update {
                Divider()
                HStack {
                    Text("Есть версия \(update.version)")
                    Spacer()
                    Button("Обновить") { model.updateNow() }.disabled(model.updating)
                }
            }
            Divider()
            VStack(spacing: 0) {
                MenuItem(title: "Открыть Waypoint", shortcut: "⌘O") { open() }.keyboardShortcut("o")
                SettingsLink { MenuItemLabel(title: "Настройки…", shortcut: "⌘,") }.buttonStyle(MenuItemStyle())
                MenuItem(title: "Выйти из Waypoint", shortcut: "туннель останется") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .tint(Palette.accent)
        .onAppear { model.start() }
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuItemLabel: View {
    let title: String
    let shortcut: String
    var body: some View {
        HStack { Text(title); Spacer(); Text(shortcut).foregroundStyle(.secondary).font(.caption) }
            .frame(height: 28).contentShape(Rectangle())
    }
}

struct MenuItem: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    var body: some View { Button(action: action) { MenuItemLabel(title: title, shortcut: shortcut) }.buttonStyle(MenuItemStyle()) }
}

/// A menu row: highlighted under the pointer with a radius of 10, like the system's.
struct MenuItemStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering || configuration.isPressed ? Color.primary.opacity(0.08) : .clear))
            .onHover { hovering = $0 }
            .padding(.horizontal, -8)
    }
}
