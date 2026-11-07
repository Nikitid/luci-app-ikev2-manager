import Foundation

/// What a part of the window shows while it waits for the daemon: the frame
/// of the window never waits, each data area says where it stands.
public enum DataArea: Equatable, Sendable {
    case loading
    case ready
    case empty
    /// No answer from the daemon: the last known state is not shown as current.
    case error

    /// The daemon's status and whether the window has asked at all yet.
    public static func of(_ status: ClientStatusReport?, asked: Bool, failed: Bool, items: Int? = nil) -> DataArea {
        if status == nil { return failed ? .error : asked ? .loading : .loading }
        if failed { return .error }
        if let items, items == 0 { return .empty }
        return .ready
    }
}

/// The words of the window and the menu, made from the daemon's status. One
/// place, so the menu, the window and the tests say the same thing.
public enum WindowText {
    public static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = count % 100, units = count % 10
        if (11...14).contains(tens) { return "\(count) \(many)" }
        if units == 1 { return "\(count) \(one)" }
        if (2...4).contains(units) { return "\(count) \(few)" }
        return "\(count) \(many)"
    }

    /// The heading by the one visible state; attention and setup name what it is.
    public static func heading(_ status: ClientStatusReport?) -> String {
        guard let status else { return StatusPhrases.unavailable.heading }
        switch status.visible ?? StatusView.visible(state: status.state, error: status.error) {
        case "on": return "Подключено"
        case "off": return "Выключено"
        case "connecting": return status.state == "tunnel_connected" ? "Проверка доступа" : "Подключение"
        default: return phrase(status).heading
        }
    }

    public static func phrase(_ status: ClientStatusReport) -> StatusPhrases.Phrase {
        StatusPhrases.phrase(state: status.state, error: status.error, full: status.fullTunnel, direct: !status.blockWithoutTunnel)
    }

    /// The services this device has on, apart from the person's own list.
    public static func servicesOn(_ status: ClientStatusReport) -> [ServiceEntry] {
        (status.entries ?? []).filter { $0.on && !OwnAddresses.isService($0.id) }
    }

    /// One sentence under the heading.
    public static func detail(_ status: ClientStatusReport?) -> String {
        guard let status else { return StatusPhrases.unavailable.detail }
        let visible = status.visible ?? StatusView.visible(state: status.state, error: status.error)
        guard visible == "on", !status.fullTunnel else { return phrase(status).detail }
        let services = status.entries == nil ? status.services.count : servicesOn(status).count
        let own = (status.own?.domains.count ?? 0) + (status.own?.networks.count ?? 0)
        var subject = plural(services, "сервис", "сервиса", "сервисов")
        if own > 0 { subject += " и " + plural(own, "свой адрес", "своих адреса", "своих адресов") }
        let verb = services + own == 1 ? "идёт" : "идут"
        return "\(subject) \(verb) через туннель, остальное напрямую."
    }

    /// The services that do not work now, by their names.
    public static func failing(_ status: ClientStatusReport?) -> [ServiceEntry] {
        guard let status else { return [] }
        return servicesOn(status).filter { $0.health.state == .down }
    }

    /// The line under the heading's rule: which service fails, or that all work, and when it was checked.
    public static func healthLine(_ status: ClientStatusReport?, checked: Date, now: Date = Date()) -> String {
        let time = clock(checked)
        let down = failing(status)
        if down.isEmpty {
            let known = status.map { servicesOn($0).contains { $0.health.state != .unknown } } ?? false
            return known ? "Работают все · проверено \(time)" : "проверено \(time)"
        }
        let names = down.prefix(2).map(\.label).joined(separator: ", ") + (down.count > 2 ? " и ещё \(down.count - 2)" : "")
        let rest = (status.map { servicesOn($0).count } ?? 0) > down.count ? " · остальные работают" : ""
        return "\(names) \(down.count == 1 ? "не отвечает" : "не отвечают")\(rest) · \(time)"
    }

    /// What a service that does not work says in its row and its details.
    public static func healthReason(_ health: ServiceHealth) -> String? {
        switch (health.state, health.reason) {
        case (.down, "no_tunnel"?): return "У роутера нет туннеля для этого сервиса"
        case (.down, _): return "Роутер не отвечает по её адресам"
        default: return nil
        }
    }

    /// The rule without the tunnel, in words.
    public static func withoutTunnel(_ entry: ServiceEntry) -> String {
        entry.closed ? "без туннеля закрыт" : "без туннеля напрямую"
    }

    /// "5 из 18": what this device has on of what it was given.
    public static func counter(_ status: ClientStatusReport?) -> String {
        guard let status, let entries = status.entries else { return status.map { "\($0.services.count)" } ?? "" }
        let offered = entries.filter { !OwnAddresses.isService($0.id) }
        return "\(offered.filter(\.on).count) из \(offered.count)"
    }

    public static func ownCounter(_ own: OwnAddresses?) -> String {
        guard let own else { return "" }
        return "\(own.domains.count + own.networks.count) из \(own.limit)"
    }

    /// The summary of a group of services on Overview.
    public static func groupSummary(_ entries: [ServiceEntry], offeredMore: Int = 0) -> String {
        guard !entries.isEmpty else { return offeredMore > 0 ? "ничего не включено · выдано \(offeredMore)" : "нет" }
        var text = entries.prefix(4).map(\.label).joined(separator: ", ")
        if entries.count > 4 { text += " и ещё \(entries.count - 4)" }
        let closed = entries.filter(\.closed).count
        if closed > 0 { text += " · \(closed) закрыт\(closed == 1 ? "" : "ы") без туннеля" }
        if offeredMore > 0 { text += " · ещё \(offeredMore) выдано" }
        return text
    }

    /// When the next attempt is, said once under the rule on the right.
    public static func nextAttempt(_ status: ClientStatusReport?, now: Date = Date()) -> String? {
        guard let next = status?.next else { return nil }
        let seconds = Int(Date(timeIntervalSince1970: TimeInterval(next)).timeIntervalSince(now).rounded(.up))
        return seconds > 0 ? "снова через \(seconds) с" : "пробую снова"
    }

    public static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// What the window says of a reset, step by step.
    public static func resetSummary(_ report: ResetReport) -> String {
        let names: [ResetStep: String] = [.connection: "подключение", .profile: "профиль VPN", .browsers: "профиль для браузеров",
                                          .hosts: "блок в /etc/hosts", .names: "имена сервисов", .filter: "блокировка",
                                          .registration: "регистрация"]
        let removed = report.steps.filter { $0.outcome == .removed }.compactMap { names[$0.step] }
        let failed = report.steps.filter { $0.outcome == .failed }.compactMap { names[$0.step] }
        if failed.isEmpty { return removed.isEmpty ? "Удалять было нечего." : "Удалено: " + removed.joined(separator: ", ") + "." }
        return "Не удалось удалить: " + failed.joined(separator: ", ") + ". Waypoint повторяет сам" +
            (failed.contains("профиль VPN") ? "; профиль можно удалить в «Системных настройках» → «Управление устройством»." : ".")
    }

    /// The person's own address refused before it is sent, in words.
    public static func ownRefusal(_ reason: String) -> String {
        switch reason {
        case "private": return "Частный адрес: через туннель идут только публичные сайты и адреса."
        case "shared": return "Адрес общей сети провайдера: через туннель идут только публичные адреса."
        case "local": return "Локальный адрес этого Mac или сети."
        case "documentation": return "Адрес из диапазона для примеров, он никуда не ведёт."
        case "fake_ip": return "Служебный адрес роутера."
        case "multicast": return "Групповой адрес, не сайт."
        case "network_size": return "Сеть шире /16: добавьте сеть поуже."
        case "invalid_network": return "Это не адрес IPv4."
        case "local_name": return "Имя локальной сети, через туннель оно не откроется."
        case "server_name": return "Это имя самого сервера VPN."
        case "over_limit": return "Список полон: уберите один из адресов."
        default: return "Нужен сайт (example.org) или адрес IPv4."
        }
    }
}

/// The choices of the first launch: opening at login and updates are offered
/// on, reports about failures have no answer until the person gives one.
public struct FirstRunChoices: Equatable, Sendable {
    public var openAtLogin = true
    public var installUpdates = true
    /// nil until answered: nothing is sent before.
    public var sendReports: Bool?
    public init() {}
    public var canFinish: Bool { sendReports != nil }
}
