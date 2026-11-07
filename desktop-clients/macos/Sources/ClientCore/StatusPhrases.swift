import Foundation

/// The codes the daemon publishes in `ClientStatusReport.state` and `.error`,
/// spelled as the Windows service spells them. `fixtures/status-codes.json`
/// holds the phrase for each; a code added here is added there, and the tests
/// fail until it is.
public enum StatusCodes {
    /// Every state the daemon publishes.
    public static let states = [
        "starting", "enrollment_required", "registration_pending", "registration_error", "blocked", "profile_required",
        "connecting", "connection_error", "tunnel_connected", "protected", "access_closed", "error", "needs_reset", "reset_incomplete"]

    /// The cause codes each state is published with; "none" is no cause.
    public static let causes: [String: [String]] = [
        "starting": ["none"], "enrollment_required": ["none"], "registration_pending": ["none"],
        "registration_error": ["enrollment_connection_failed", "enrollment_access_rejected", "enrollment_http_rejected",
                               "enrollment_response_invalid", "enrollment_invalid_endpoint", "enrollment_internal"],
        "blocked": ["none"], "profile_required": ["none", "profile_removed"], "connecting": ["none"],
        "connection_error": [TunnelFault.unavailable.rawValue, TunnelFault.takesEverything.rawValue, "profile_mode",
                             "offline", "server_not_found", "ike_no_answer"],
        "tunnel_connected": ["path_connection_failed", "path_unavailable", "path_different_policy", "device_access_revoked",
                             "path_response_invalid"],
        "protected": ["none"], "access_closed": ["no_services", "synchronization"], "error": ["internal", "synchronization", "guard_restoring", "guard_unconfirmed"],
        "needs_reset": ["registration_unreadable", "policy_unreadable"], "reset_incomplete": ["none"]]

    /// What the router refused while a registration was under way.
    public static func enrollment(_ error: DeviceError) -> String {
        switch error {
        case .connectionFailed: return "enrollment_connection_failed"
        case .accessRejected: return "enrollment_access_rejected"
        case .httpRejected: return "enrollment_http_rejected"
        case .invalidResponse: return "enrollment_response_invalid"
        case .invalidEndpoint: return "enrollment_invalid_endpoint"
        default: return "enrollment_internal"
        }
    }

    /// What the router answered while the tunnel's path was being confirmed.
    public static func path(_ error: DeviceError) -> String {
        switch error {
        case .connectionFailed: return "path_connection_failed"
        case .accessRejected: return "device_access_revoked"
        case .differentPolicy: return "path_different_policy"
        case .pathUnavailable: return "path_unavailable"
        default: return "path_response_invalid"
        }
    }
}

/// The words the window and the menu say for a state: one heading and one
/// sentence, chosen by the state and its cause. The same table as the Windows
/// client's, in `fixtures/status-codes.json`.
public enum StatusPhrases {
    public struct Phrase: Equatable, Sendable {
        public let heading: String
        public let detail: String
    }

    /// The window has no answer from the daemon at all.
    public static let unavailable = Phrase(heading: "Состояние неизвестно", detail: "Подробности в отчёте.")

    /// `full`: everything goes into the tunnel; `direct`: services are not
    /// blocked while the tunnel is down.
    public static func phrase(state: String, error: String, full: Bool = false, direct: Bool = false) -> Phrase {
        switch state {
        case "protected":
            return Phrase(heading: "Доступ открыт", detail: full ? "Весь трафик идёт через туннель." : "Сервисы идут через туннель.")
        case "blocked":
            return Phrase(heading: "Доступ выключен", detail: direct ? "Сервисы идут напрямую, без туннеля." : "Сервисы заблокированы.")
        case "enrollment_required":
            return Phrase(heading: "Устройство не зарегистрировано", detail: "Нужна ссылка приглашения от администратора.")
        case "registration_pending":
            return Phrase(heading: "Регистрация", detail: "Ожидается ответ сервера.")
        case "registration_error":
            switch error {
            case "enrollment_connection_failed":
                return Phrase(heading: "Регистрация не завершена", detail: "Нет связи с сервером. Попытка повторится сама.")
            case "enrollment_access_rejected":
                return Phrase(heading: "Ссылка не принята",
                              detail: "Ссылка недействительна, истекла или уже использована. Попросите у администратора новую.")
            default:
                return Phrase(heading: "Регистрация не завершена",
                              detail: "Сервер ответил не так, как ожидалось (\(error)). Попытка повторится сама; если не проходит, нажмите «Отчёт…» и передайте его администратору.")
            }
        case "profile_required":
            return error == "profile_removed"
                ? Phrase(heading: "Нужен профиль VPN", detail: "Профиль VPN удалён в «Системных настройках». Установите его снова.")
                : Phrase(heading: "Нужен профиль VPN", detail: "Установите профиль в «Системных настройках».")
        case "needs_reset":
            return Phrase(heading: "Нужен сброс",
                          detail: "Данные регистрации на этом Mac повреждены. Нажмите «Сбросить…», затем зарегистрируйте его по новой ссылке.")
        case "reset_incomplete":
            return Phrase(heading: "Сброс не завершён", detail: "Waypoint удаляет оставшееся сам и повторяет попытки.")
        case "connecting":
            return Phrase(heading: "Подключение", detail: "Устанавливается туннель.")
        case "tunnel_connected":
            let detail: String
            switch error {
            case "path_connection_failed": detail = "Нет связи с сервером."
            case "path_different_policy": detail = "Настройки обновляются."
            case "device_access_revoked": detail = "Доступ отозван администратором."
            case "path_response_invalid": detail = "Ответ сервера не принят."
            default: detail = "Сервер ещё не подтвердил доступ."
            }
            return Phrase(heading: "Проверка доступа", detail: detail)
        case "connection_error":
            switch error {
            case "tunnel_takes_everything":
                return Phrase(heading: "Нет подключения", detail: "Сервер предложил направить в туннель весь трафик. Подключение отклонено.")
            case "profile_mode":
                return Phrase(heading: "Нет подключения", detail: "Режим изменён администратором. Установите профиль заново.")
            case "offline":
                return Phrase(heading: "Нет подключения", detail: "Mac не в сети.")
            case "server_not_found":
                return Phrase(heading: "Нет подключения", detail: "Имя сервера не находится. Проверьте интернет.")
            case "ike_no_answer":
                return Phrase(heading: "Нет подключения", detail: "Эта сеть не пропускает IKEv2: UDP 500 и 4500 к серверу закрыты.")
            default:
                return Phrase(heading: "Нет подключения", detail: "Туннель не установлен. Попытка повторится.")
            }
        case "access_closed":
            return error == "no_services"
                ? Phrase(heading: "Сервисы не назначены", detail: "Администратор не назначил этому устройству сервисов. Сайты открываются как обычно.")
                : Phrase(heading: "Доступ не разрешён", detail: "Доступ для этого устройства выключен администратором.")
        case "starting":
            return Phrase(heading: "Запуск", detail: "Состояние защиты не подтверждено. Подробности в отчёте.")
        case "error" where error == "guard_restoring":
            return Phrase(heading: "Защита восстанавливается", detail: "Другая программа выключила фильтр пакетов. Waypoint включает его снова.")
        case "error" where error == "guard_unconfirmed":
            return Phrase(heading: "Защита не подтверждена", detail: "Блокировка вне туннеля не действует: фильтр пакетов не включается.")
        case "error":
            return Phrase(heading: "Ошибка службы", detail: "Состояние защиты не подтверждено. Подробности в отчёте.")
        default:
            return unavailable
        }
    }
}
