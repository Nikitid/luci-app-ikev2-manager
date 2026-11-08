import AppKit
import ClientCore
import SwiftUI

/// Data that is not there yet, or no longer current: said in the area itself.
struct AreaNote: View {
    let area: DataArea
    var empty = "Пусто."
    var body: some View {
        switch area {
        case .loading: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Загружаю…").foregroundStyle(.secondary) }
        case .error: Text("Служба Waypoint не отвечает; показаны последние известные данные.").foregroundStyle(Palette.stale)
        case .empty: Text(empty).foregroundStyle(.secondary)
        case .ready: EmptyView()
        }
    }
}

// MARK: Services

struct ServicesView: View {
    @ObservedObject var model: ClientModel
    @State private var adding = false
    @State private var detailsOf: String?

    var body: some View {
        let entries = (model.status?.entries ?? []).filter { !OwnAddresses.isService($0.id) }
        let area = DataArea.of(model.status, asked: model.asked, failed: model.failed, items: entries.count)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AreaNote(area: area, empty: model.status?.entries == nil ? "Роутер не выдаёт набор этому Mac." : "Сервисы этому Mac не назначены.")
                if !entries.isEmpty {
                    group("Обязательные", entries.filter(\.required), trailing: requiredTrailing(entries.filter(\.required)))
                    let chosen = entries.filter { !$0.required && model.shown($0).on }
                    let offered = entries.filter { !$0.required }.count
                    group("По выбору", chosen, trailing: "\(chosen.count) из \(offered) выданных",
                          empty: offered == 0 ? "Сервисов по выбору не выдано." : "Ничего не включено. «Добавить» — из выданных.")
                }
                if !model.checkMessage.isEmpty { Text(model.checkMessage).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .toolbar {
            ToolbarItem {
                Button { adding = true } label: { Label("Добавить", systemImage: "plus") }
                    .disabled(!entries.contains { !$0.required && !model.shown($0).on })
                    .help("Добавить сервис из выданных")
            }
        }
        .sheet(isPresented: $adding) { AddServiceSheet(model: model) }
    }

    private func requiredTrailing(_ required: [ServiceEntry]) -> String {
        let down = required.filter { $0.health.state == .down }
        guard !down.isEmpty else { return "задал администратор, не выключить" }
        return down.map(\.label).prefix(2).joined(separator: ", ") + (down.count == 1 ? " не отвечает" : " не отвечают") + " · остальные работают"
    }

    private func group(_ title: String, _ items: [ServiceEntry], trailing: String, empty: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(trailing).font(.caption).foregroundStyle(trailing.contains("не отвеча") ? Palette.danger : .secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
            if items.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                Panel {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                        PanelRow(last: index == items.count - 1) { ServiceRow(model: model, entry: entry, detailsOf: $detailsOf) }
                    }
                }
            }
        }
    }
}

struct ServiceRow: View {
    @ObservedObject var model: ClientModel
    let entry: ServiceEntry
    @Binding var detailsOf: String?

    var body: some View {
        let shown = model.shown(entry)
        let waiting = model.pending[entry.id] != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { detailsOf = entry.id } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.label).lineLimit(1).truncationMode(.tail)
                        if let reason = WindowText.healthReason(entry.health) {
                            Text(reason).font(.caption).foregroundStyle(Palette.danger)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { detailsOf == entry.id }, set: { if !$0 { detailsOf = nil } }), arrowEdge: .bottom) {
                    ServiceDetails(model: model, entry: entry)
                }
                // Where the person decides, the rule is the checkbox itself, not said twice.
                if entry.required || !entry.chooseClosed {
                    Label(WindowText.withoutTunnel(entry), systemImage: entry.closed ? "lock" : "arrow.right")
                        .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon).lineLimit(1)
                }
                if waiting { ProgressView().controlSize(.small) }
                if !entry.required {
                    if entry.chooseClosed {
                        Toggle("закрыт без туннеля", isOn: Binding(get: { shown.closed }, set: { model.choose(entry, closed: $0) }))
                            .toggleStyle(.checkbox).font(.caption).disabled(waiting)
                    }
                    Toggle(entry.label, isOn: Binding(get: { shown.on }, set: { model.choose(entry, on: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(waiting)
                }
            }
            if let error = model.choiceError[entry.id] { Text(error).font(.caption).foregroundStyle(Palette.danger) }
        }
        .accessibilityElement(children: .contain)
    }
}

/// What a service is made of and how it stands, by its row.
struct ServiceDetails: View {
    @ObservedObject var model: ClientModel
    let entry: ServiceEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.label).font(.headline)
            if let reason = WindowText.healthReason(entry.health) {
                let since = entry.health.since.map { " с " + WindowText.clock(Date(timeIntervalSince1970: TimeInterval($0))) } ?? ""
                Text(reason + since + ".").foregroundStyle(Palette.danger)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("Правило").foregroundStyle(.secondary); Text((entry.required ? "обязательный" : "по выбору") + (entry.closed ? ", закрытый" : "")) }
                GridRow { Text("Без туннеля").foregroundStyle(.secondary); Text(entry.closed ? "закрыт: не откроется и напрямую" : "идёт напрямую") }
                GridRow { Text("Состав").foregroundStyle(.secondary)
                    Text(WindowText.plural(entry.domains, "домен", "домена", "доменов") + (entry.networks > 0 ? ", " + WindowText.plural(entry.networks, "сеть", "сети", "сетей") : "")) }
                GridRow { Text("Проверено").foregroundStyle(.secondary); Text(WindowText.clock(model.checked)).monospacedDigit() }
            }
            .font(.callout)
            HStack {
                Button("Проверить сейчас") { model.checkNow() }
                if !model.checkMessage.isEmpty { Text(model.checkMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

/// A service from those given, found by its name; its rule chosen at once.
struct AddServiceSheet: View {
    @ObservedObject var model: ClientModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked: String?
    @State private var closed = false

    var body: some View {
        let offered = (model.status?.entries ?? []).filter { !$0.required && !model.shown($0).on && !OwnAddresses.isService($0.id) }
        let found = query.isEmpty ? offered : offered.filter { $0.label.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
        let chosen = offered.first { $0.id == picked }
        VStack(alignment: .leading, spacing: 12) {
            Text("Добавить сервис").font(.headline)
            Text("Из \(offered.count) выданных администратором.").font(.caption).foregroundStyle(.secondary)
            TextField("Поиск", text: $query).textFieldStyle(.roundedBorder)
            List(found, id: \.id, selection: $picked) { entry in
                HStack {
                    Text(entry.label)
                    Spacer()
                    Text(WindowText.withoutTunnel(entry)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(entry.id)
            }
            .frame(height: 220)
            Text("Найдено \(found.count) из \(offered.count).").font(.caption).foregroundStyle(.secondary)
            if let chosen, chosen.chooseClosed {
                HStack {
                    Text("\(chosen.label) без туннеля")
                    Spacer()
                    Picker("Без туннеля", selection: $closed) {
                        Text("Напрямую").tag(false)
                        Text("Закрыт").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.map { "Добавить \($0.label)" } ?? "Добавить") {
                    if let chosen { model.choose(chosen, on: true, closed: chosen.chooseClosed ? closed : nil) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: picked) { _, id in closed = offered.first { $0.id == id }?.closed ?? false }
    }
}

// MARK: Own sites and addresses

struct OwnSitesView: View {
    @ObservedObject var model: ClientModel
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let own = model.status?.own
        let area = DataArea.of(model.status, asked: model.asked, failed: model.failed)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AreaNote(area: area)
                if let own {
                    Text("Идут через туннель только на этом Mac. Администратор разрешил до \(own.limit) адресов на портах \(own.ports.map(String.init).joined(separator: ", ")).")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    let full = own.domains.count + own.networks.count >= own.limit
                    Panel {
                        PanelRow(last: own.domains.isEmpty && own.networks.isEmpty && model.ownWaiting.isEmpty) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    TextField("Сайт или адрес IPv4", text: $text).textFieldStyle(.roundedBorder).focused($focused)
                                        .onSubmit(add).disabled(full)
                                        .onChange(of: text) { _, value in error = value.isEmpty ? nil : localCheck(value) }
                                    Button("Добавить", action: add).disabled(full || text.isEmpty || error != nil || model.busy)
                                }
                                if let error { Text(error).font(.caption).foregroundStyle(Palette.danger) }
                                else if full { Text(WindowText.ownRefusal("over_limit")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        let items = own.domains.map { ($0, "с поддоменами") } + own.networks.map { ($0, $0.hasSuffix("/32") ? "адрес" : "сеть") }
                        let waiting = model.ownWaiting.filter { !own.domains.contains($0) && !own.networks.contains($0) }
                        ForEach(Array(items.enumerated()), id: \.element.0) { index, item in
                            PanelRow(last: index == items.count - 1 && waiting.isEmpty) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.0.hasSuffix("/32") ? String(item.0.dropLast(3)) : item.0).font(.system(.body, design: .monospaced))
                                        Text(item.1).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button { remove(item.0) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless).help("Убрать").accessibilityLabel("Убрать " + item.0).disabled(model.busy)
                                }
                            }
                        }
                        ForEach(waiting, id: \.self) { item in
                            PanelRow(last: item == waiting.last) {
                                HStack {
                                    Text(item).font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Text("ждёт роутера").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("\(WindowText.ownCounter(own)) · порт \(own.ports.map(String.init).joined(separator: ", ")). Без туннеля — напрямую." +
                         (model.ownHintShown ? " Браузеру может понадобиться до минуты." : ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(Palette.danger) }
                } else if area == .ready {
                    Text("Администратор не разрешил добавлять свои сайты и адреса.").foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private func localCheck(_ value: String) -> String? {
        let server = [model.status?.addresses?.server ?? ""].filter { !$0.isEmpty }
        if case .failure(let refusal) = OwnAddresses.check(value, server: server) { return WindowText.ownRefusal(refusal.reason) }
        return nil
    }

    private func add() {
        guard error == nil, !text.isEmpty else { return }
        if let refusal = model.addOwn(text) { error = refusal } else { text = "" }
    }

    private func remove(_ item: String) {
        guard let own = model.status?.own else { return }
        model.setOwn(domains: own.domains.filter { $0 != item }, networks: own.networks.filter { $0 != item })
    }
}

// MARK: Update

/// A newer version, said over the set on Overview.
struct UpdateRow: View {
    @ObservedObject var model: ClientModel
    var body: some View {
        if let update = model.update {
            Panel {
                PanelRow(last: true) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if model.updateFailed {
                                    Text("Версия \(update.version) не прошла проверку").foregroundStyle(Palette.danger)
                                } else {
                                    Text((model.updating ? "Ставится " : "Есть версия ") + update.version + " ·")
                                    Link("что нового", destination: model.releaseNotes(update.version)).foregroundStyle(Palette.accent)
                                }
                            }
                            Text(model.updateDetail).font(.caption).foregroundStyle(model.updateFailed ? Palette.danger : .secondary)
                        }
                        Spacer()
                        Button("Обновить") { model.updateNow() }.disabled(model.updating)
                    }
                }
            }
        }
    }
}
