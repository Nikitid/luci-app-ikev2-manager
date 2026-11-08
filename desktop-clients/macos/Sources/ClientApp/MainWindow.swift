import AppKit
import ClientCore
import SwiftUI

enum Section: String, Hashable, CaseIterable {
    case overview, services, own, reports
    var title: String {
        switch self {
        case .overview: "Обзор"
        case .services: "Сервисы"
        case .own: "Свои сайты и адреса"
        case .reports: "Обращения"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "waveform.path.ecg"
        case .services: "list.bullet"
        case .own: "globe"
        case .reports: "bubble.left"
        }
    }
}

extension ClientModel {
    var visible: String {
        // Still asking is not a fault: neutral until an answer or its absence.
        guard let status else { return failed ? "attention" : "connecting" }
        if failed { return "attention" }
        return status.visible ?? StatusView.visible(state: status.state, error: status.error)
    }
    var headingText: String { status == nil && !failed ? "Проверяю состояние" : WindowText.heading(failed ? nil : status) }
    /// Whether the connection can be switched from here.
    var switchable: Bool {
        guard let status, !failed else { return false }
        return !["enrollment_required", "registration_pending", "registration_error", "needs_reset", "reset_incomplete", "starting"].contains(status.state)
    }
    var connectionWanted: Binding<Bool> {
        Binding(get: { self.status?.wanted ?? false }, set: { self.command($0 ? "connect" : "disconnect") })
    }
}

/// The window: navigation on the left, one section on the right. Its frame
/// never waits for the daemon; each section says where its data stands.
struct MainWindow: View {
    @ObservedObject var model: ClientModel
    @State private var section: Section? = .overview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One container, so its appearance is the window's own and not that
        // of whichever page is inside: in 2.3.0 the modifiers below sat on
        // a Group, ran for each page as it swapped, and switched the program
        // out of the Dock and back, which hid and showed the window.
        ZStack {
            if model.firstRunDue {
                FirstRunView(model: model)
            } else {
                NavigationSplitView {
                    List(Section.allCases, id: \.self, selection: $section) { item in
                        Label(item.title, systemImage: item.symbol)
                            .badge(badge(item))
                    }
                    .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 320)
                    .safeAreaInset(edge: .bottom) { SidebarStatus(model: model) }
                } detail: {
                    detail.frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Palette.bg)
                        .navigationTitle((section ?? .overview).title)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .tint(Palette.accent)
        .onAppear { model.start() }
    }

    private func badge(_ item: Section) -> Text? {
        switch item {
        case .services: let text = WindowText.counter(model.status); return text.isEmpty ? nil : Text(text)
        case .own: return model.status?.own.map { Text(WindowText.ownCounter($0)) }
        case .reports: return model.unread > 0 ? Text("\(model.unread)") : nil
        case .overview: return nil
        }
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .overview {
        case .overview: OverviewView(model: model, go: { section = $0 })
        case .services: ServicesView(model: model)
        case .own: OwnSitesView(model: model)
        case .reports: ReportsView(model: model)
        }
    }
}

/// The state repeated at the foot of the sidebar in every section.
struct SidebarStatus: View {
    @ObservedObject var model: ClientModel
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                WaypointSign(visible: model.visible, size: 13)
                Text(model.headingText).font(.callout).lineLimit(1)
                Spacer(minLength: 8)
                Toggle("Waypoint", isOn: model.connectionWanted).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!model.switchable || model.busy)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

/// The heading of Overview: sign, state, the one switch, the sentence, and
/// one notch per service that is on.
struct StateHeader: View {
    @ObservedObject var model: ClientModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = model.failed ? nil : model.status
        let attention = model.visible == "attention"
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                WaypointSign(visible: model.visible, size: 18)
                Text(heading(status)).font(.system(size: 28, weight: .thin))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .id(heading(status))
                    .transition(.opacity)
                Spacer()
                Toggle("Waypoint", isOn: model.connectionWanted).labelsHidden().toggleStyle(.switch)
                    .disabled(!model.switchable || model.busy)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: WindowText.heading(status))
            Text(sentence(status))
                .foregroundStyle(attention ? Palette.danger : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status, status.entries != nil {
                HStack(spacing: 10) {
                    Text("Сервисы").font(.headline)
                    Notches(entries: WindowText.servicesOn(status))
                }
                .padding(.top, 6)
            }
            Rectangle().fill(attention ? Palette.danger.opacity(0.55) : Palette.line).frame(height: 1)
            HStack {
                Text(status?.addresses?.server ?? "").lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(rightLine(status)).foregroundStyle(model.failed ? Palette.stale : .secondary)
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .onChange(of: model.visible) { _, visible in
            if visible == "attention" {
                AccessibilityNotification.Announcement(WindowText.heading(model.status) + ". " + WindowText.detail(model.status)).post()
            }
        }
    }

    private func heading(_ status: ClientStatusReport?) -> String {
        status == nil && !model.failed ? "Проверяю состояние" : WindowText.heading(status)
    }

    private func sentence(_ status: ClientStatusReport?) -> String {
        if model.failed { return "Служба Waypoint не отвечает. Если это повторяется, переустановите программу." }
        return model.asked ? WindowText.detail(status) : "Спрашиваю службу Waypoint…"
    }

    private func rightLine(_ status: ClientStatusReport?) -> String {
        if !model.asked { return "" }
        if model.failed { return "служба не отвечает · данные \(WindowText.clock(model.checked))" }
        if let next = WindowText.nextAttempt(status) { return next }
        return WindowText.healthLine(status, checked: model.checked)
    }
}

/// One notch per service that is on; one that does not work is longer and brick.
struct Notches: View {
    let entries: [ServiceEntry]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 4) {
            ForEach(entries.prefix(24), id: \.id) { entry in
                let down = entry.health.state == .down
                Capsule().fill(down ? Palette.danger : Color.secondary)
                    .frame(width: down ? 2 : 1.5, height: down ? 18 : 12)
                    .help(entry.label + (down ? " — не отвечает" : ""))
                    .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: down)
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Сервисы: " + entries.map { $0.label + ($0.health.state == .down ? ", не отвечает" : ", работает") }.joined(separator: "; "))
    }
}

struct OverviewView: View {
    @ObservedObject var model: ClientModel
    var go: (Section) -> Void
    @State private var registering = false
    @State private var otherVPN = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StateHeader(model: model)
                PrimaryAction(model: model, registering: $registering)
                if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary) }
                UpdateRow(model: model)
                if let status = model.status, !model.failed, status.entries != nil || status.own != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Набор").font(.subheadline).foregroundStyle(.secondary).padding(.leading, 4)
                        Panel {
                            let entries = WindowText.servicesOn(status)
                            let optionalOff = (status.entries ?? []).filter { !$0.required && !$0.on && !OwnAddresses.isService($0.id) }.count
                            jump("Обязательные", WindowText.groupSummary(entries.filter(\.required)), .services)
                            jump("По выбору", WindowText.groupSummary(entries.filter { !$0.required }, offeredMore: optionalOff), .services)
                            if let own = status.own {
                                jump("Свои сайты и адреса", ((own.domains + own.networks).prefix(3).joined(separator: ", ") + " · " +
                                     WindowText.ownCounter(own)).trimmingCharacters(in: CharacterSet(charactersIn: " ·")), .own, last: true)
                            }
                        }
                    }
                }
                if let addresses = model.status?.addresses {
                    Panel {
                        DisclosureGroup(isExpanded: $otherVPN) {
                            OtherVPNRows(addresses: addresses).padding(.top, 8)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Для другого VPN")
                                Text("Сервер, IP сервера и сети: добавьте их в исключения другого VPN").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .sheet(isPresented: $registering) { RegistrationSheet(model: model) }
    }

    private func jump(_ title: String, _ summary: String, _ target: Section, last: Bool = false) -> some View {
        PanelRow(last: last) {
            Button { go(target) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The one prominent action for a state that needs one.
struct PrimaryAction: View {
    @ObservedObject var model: ClientModel
    @Binding var registering: Bool
    var body: some View {
        if let status = model.status, !model.failed {
            switch status.state {
            case "enrollment_required", "registration_error":
                Button("Зарегистрировать…") { registering = true }.buttonStyle(.borderedProminent)
            case "profile_required":
                Button("Установить профиль…") { model.installProfile() }.buttonStyle(.borderedProminent).disabled(model.busy)
            case "connection_error", "error":
                HStack {
                    Button("Подключить снова") { model.command("connect") }.buttonStyle(.borderedProminent).disabled(model.busy || !status.wanted)
                    if ["internal", "guard_unconfirmed"].contains(status.error) {
                        Text(model.sendReports == true ? "Отчёт отправлен" : "Можно сообщить о проблеме в «Обращениях»")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case "needs_reset":
                SettingsLink { Text("Сбросить…") }.buttonStyle(.borderedProminent)
            default: EmptyView()
            }
        }
    }
}

/// Values another VPN needs as exceptions: label, value in monospace, copy.
struct OtherVPNRows: View {
    let addresses: ConnectionAddresses
    var body: some View {
        let rows: [(String, String)] = [("Сервер", addresses.server), ("IP сервера", addresses.serverIP),
                                        ("Сеть сервисов", addresses.services), ("Сеть туннеля", addresses.tunnel)]
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                    if row.1.isEmpty {
                        Text("роутер не сообщает").foregroundStyle(.secondary)
                    } else {
                        Text(row.1).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    Button { copy(row.1) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).disabled(row.1.isEmpty).help("Скопировать").accessibilityLabel("Скопировать: " + row.0)
                }
            }
            Button("Скопировать все") { copy(rows.map(\.1).filter { !$0.isEmpty }.joined(separator: "\n")) }
                .padding(.top, 4)
        }
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The link from the administrator, pasted, never shown in clear.
struct RegistrationSheet: View {
    @ObservedObject var model: ClientModel
    @Environment(\.dismiss) private var dismiss
    @State private var invitation = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ссылка приглашения").font(.headline)
            Text("Вставьте ссылку от администратора. Она одноразовая.").foregroundStyle(.secondary)
            HStack {
                SecureField("https://…/client/v1/enroll#…", text: $invitation).frame(width: 380)
                Button("Вставить") { invitation = NSPasteboard.general.string(forType: .string) ?? "" }
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Зарегистрировать") { model.register(invitation.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(invitation.isEmpty)
            }
        }
        .padding(20)
    }
}
