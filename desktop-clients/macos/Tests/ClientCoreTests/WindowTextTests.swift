import Foundation
import Testing
@testable import ClientCore

private func status(_ state: String, error: String = "none", entries: [ServiceEntry]? = nil, own: OwnAddresses? = nil) -> ClientStatusReport {
    var report = ClientStatusReport(state: state, guardInstalled: true, protected: state == "protected", routed: false, wanted: true,
                                    profileInstalled: true, error: error, services: [], available: [], domains: 0, revision: 1, release: "", updatedAt: 0)
    report.entries = entries; report.own = own
    report.visible = StatusView.visible(state: state, error: error)
    return report
}
private func entry(_ id: String, label: String? = nil, on: Bool = true, required: Bool = true, closed: Bool = false, health: ServiceHealth.State = .ok) -> ServiceEntry {
    var item = ServiceEntry(id: id, required: required, on: on, closed: closed, chooseClosed: !required, domains: 1, networks: 0, resources: [], cidrs: [])
    item.label = label ?? id; item.health = ServiceHealth(state: health)
    return item
}

@Test func headingAndSentenceFollowTheOneState() {
    let five = (1...5).map { entry("s\($0)") } + [entry("yt", on: false, required: false)]
    let own = OwnAddresses(limit: 20, ports: [443], domains: ["docs.example.org"], networks: ["93.184.208.0/20"])
    let on = status("protected", entries: five, own: own)
    #expect(WindowText.heading(on) == "Подключено")
    #expect(WindowText.detail(on) == "5 сервисов и 2 своих адреса идут через туннель, остальное напрямую.")
    #expect(WindowText.detail(status("protected", entries: [entry("a")])) == "1 сервис идёт через туннель, остальное напрямую.")
    #expect(WindowText.heading(status("blocked")) == "Выключено")
    let ike = status("connection_error", error: "ike_no_answer")
    #expect(WindowText.heading(ike) == "Нет подключения" && WindowText.detail(ike).contains("UDP 500 и 4500"))
    #expect(WindowText.heading(nil) == "Состояние неизвестно")
    #expect(WindowText.counter(on) == "5 из 6" && WindowText.ownCounter(own) == "2 из 20")
    #expect(WindowText.plural(21, "сервис", "сервиса", "сервисов") == "21 сервис" && WindowText.plural(12, "сервис", "сервиса", "сервисов") == "12 сервисов")
}

@Test func oneServiceDownIsNamedAndTheRestWork() {
    let checked = Date(timeIntervalSince1970: 0)
    let time = WindowText.clock(checked)
    var entries = [entry("portal", label: "Рабочий портал"), entry("acc", label: "Бухгалтерия", health: .down), entry("mail", label: "Почта")]
    #expect(WindowText.healthLine(status("protected", entries: entries), checked: checked) == "Бухгалтерия не отвечает · остальные работают · \(time)")
    entries[1].health = ServiceHealth(state: .ok)
    #expect(WindowText.healthLine(status("protected", entries: entries), checked: checked) == "Работают все · проверено \(time)")
    // An older router says nothing of health: nothing is claimed.
    entries = entries.map { var item = $0; item.health = .unknown; return item }
    #expect(WindowText.healthLine(status("protected", entries: entries), checked: checked) == "проверено \(time)")
    #expect(WindowText.healthReason(ServiceHealth(state: .down, reason: "silent")) == "Роутер не отвечает по её адресам")
}

@Test func worstCaseDataStaysOneLine() {
    let many = (1...18).map { entry("s\($0)", label: String(repeating: "Очень длинное имя сервиса ", count: 3)) }
    let summary = WindowText.groupSummary(many, offeredMore: 13)
    #expect(summary.contains("и ещё 14") && summary.contains("ещё 13 выдано"))
    #expect(WindowText.groupSummary([]) == "нет")
    #expect(WindowText.detail(status("protected", entries: [])) == "0 сервисов идут через туннель, остальное напрямую.")
}

@Test func dataAreaSaysWhereItStands() {
    #expect(DataArea.of(nil, asked: false, failed: false) == .loading)
    #expect(DataArea.of(nil, asked: true, failed: true) == .error)
    #expect(DataArea.of(status("blocked"), asked: true, failed: false, items: 0) == .empty)
    #expect(DataArea.of(status("blocked"), asked: true, failed: false, items: 3) == .ready)
    #expect(DataArea.of(status("blocked"), asked: true, failed: true) == .error, "an old answer is not shown as current")
}

@Test func firstRunCannotFinishWithoutAnAnswerAboutReports() {
    var choices = FirstRunChoices()
    #expect(choices.openAtLogin && choices.installUpdates && choices.sendReports == nil && !choices.canFinish)
    choices.sendReports = false
    #expect(choices.canFinish)
}

@Test func resetIsToldStepByStep() {
    let done = ResetReport(steps: [.init(step: .profile, outcome: .removed), .init(step: .filter, outcome: .removed), .init(step: .registration, outcome: .removed), .init(step: .browsers, outcome: .absent)])
    #expect(WindowText.resetSummary(done) == "Удалено: профиль VPN, блокировка, регистрация.")
    let failed = ResetReport(steps: [.init(step: .profile, outcome: .failed, reason: "refused")])
    #expect(WindowText.resetSummary(failed).hasPrefix("Не удалось удалить: профиль VPN."))
    #expect(WindowText.ownRefusal("private").hasPrefix("Частный адрес"))
}
