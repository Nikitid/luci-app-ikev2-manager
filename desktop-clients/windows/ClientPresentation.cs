using System;
using System.Collections.Generic;
using System.Linq;

namespace IkeV2Manager.Client
{
    // How a state reads at a glance: one colour and one sign, the same on macOS.
    public enum Tone { Open, Working, Attention, Off }

    public sealed class CheckLine
    {
        public string Label { get; internal set; }
        public string Value { get; internal set; }
        public Tone Tone { get; internal set; }
    }

    // A service as a row of the window: what it is called, whether it is on
    // and blocked without the tunnel, and which of the two the person may change.
    public sealed class ServiceRow
    {
        public string Id { get; internal set; }
        public string Label { get; internal set; }
        public bool On { get; internal set; }
        public bool Closed { get; internal set; }
        public bool CanTurn { get; internal set; }
        // Whether blocking it without the tunnel is the person's to choose,
        // and whether that switch means anything now: only while it is on.
        public bool ChooseClosed { get; internal set; }
        public bool CanClose { get; internal set; }
        public string Note { get; internal set; }
    }

    // Everything the window says, from one reading of the service: the words,
    // the checks, the services and which actions are offered. Nothing here
    // draws; the window only shows what this decides, so it can be tested.
    public sealed class ClientPresentation
    {
        public Tone Tone { get; private set; }
        public string Heading { get; private set; }
        public string Description { get; private set; }
        public CheckLine[] Checks { get; private set; }
        public ServiceRow[] Services { get; private set; }
        // Shown instead of rows where the router gives no offer to choose from.
        public string ServicesLine { get; private set; }
        public string ServicesNote { get; private set; }
        public string AvailableLine { get; private set; }
        public string[] Notes { get; private set; }
        public bool Register { get; private set; }
        public bool Resume { get; private set; }
        public bool Connect { get; private set; }
        public bool Disconnect { get; private set; }
        public bool Update { get; private set; }
        public bool Browsers { get; private set; }
        public bool Registered { get; private set; }
        // While a choice is on its way the switches wait for it.
        public bool Choosing { get; private set; }
        // The person's own sites and networks, where allowed: the list, what
        // may still be added, and a line about it; null where not allowed.
        public string[] OwnItems { get; private set; }
        public bool OwnCanAdd { get; private set; }
        public string OwnLine { get; private set; }
        public string OwnProblem { get; private set; }
        public string[] Addresses { get; private set; }

        public static readonly string[] AddressLabels = { "Сервер", "IP сервера", "Сеть сервисов", "Сеть туннеля" };

        // What a registration that has not finished is waiting for, in words.
        public static string RegistrationNote(string code)
        {
            switch (code)
            {
                case null: case "": case "none": return null;
                case "enrollment_connection_failed": return "Нет связи с сервером. Попытка повторится сама.";
                case "enrollment_server_busy": return "Сервер занят другой регистрацией. Попытка повторится сама.";
                case "enrollment_access_rejected": return "Ссылка недействительна, истекла или уже использована. Попросите у администратора новую.";
                default: return "Сервер ответил не так, как ожидалось (" + code + "). Попытка повторится сама; если не проходит, нажмите «Отчёт…» и передайте его администратору.";
            }
        }

        public static ClientPresentation Of(ClientView view, Version own, string[] selfResolving, bool browsersTold)
        {
            var p = new ClientPresentation();
            var warnings = view.Warnings ?? new string[0];
            string code = view.ConnectionError;
            bool unassigned = view.State == "access_closed" && warnings.Contains("idle");
            p.Tone = unassigned ? Tone.Off : view.State == "protected" ? Tone.Open :
                view.State == "connecting" || view.State == "tunnel_connected" || view.State == "registration_pending" ? Tone.Working :
                view.State == "blocked" || view.State == "enrollment_required" ? Tone.Off : Tone.Attention;
            switch (view.State)
            {
                case "blocked":
                    p.Heading = view.Wanted ? "Доступ закрыт" : "Доступ выключен";
                    p.Description = warnings.Contains("open") ? "Сервисы идут напрямую, без туннеля." :
                        view.Wanted ? "Нет подключения. Сервисы заблокированы." : "Сервисы заблокированы.";
                    break;
                case "enrollment_required":
                    p.Heading = "Устройство не зарегистрировано";
                    p.Description = "Нужна ссылка приглашения от администратора.";
                    break;
                case "registration_pending":
                    p.Heading = "Регистрация";
                    p.Description = RegistrationNote(code) ?? "Ожидается ответ сервера.";
                    break;
                case "registration_error":
                    // The service goes on trying by itself; the window says what
                    // stands in the way and whether anything is asked of the person.
                    p.Heading = code == "enrollment_access_rejected" ? "Ссылка не принята" : "Регистрация не завершена";
                    p.Description = RegistrationNote(code) ?? "Настройки пока не получены. Попытка повторится сама.";
                    break;
                case "connecting":
                    p.Heading = "Подключение";
                    p.Description = "Устанавливается туннель.";
                    break;
                case "protected":
                    p.Heading = "Доступ открыт";
                    p.Description = warnings.Contains("full") ? "Весь трафик идёт через туннель." : "Сервисы идут через туннель.";
                    break;
                case "tunnel_connected":
                    p.Heading = "Проверка доступа";
                    p.Description = code == "path_connection_failed" ? "Нет связи с сервером." :
                        code == "path_different_policy" ? "Настройки обновляются." :
                        code == "device_access_revoked" ? "Доступ отозван администратором." :
                        code == "path_response_invalid" ? "Ответ сервера не принят." :
                        code == "path_stalled" ? "Туннель установлен, но данные через него не идут. Если включён другой VPN, он может их блокировать." :
                        "Сервер ещё не подтвердил доступ.";
                    break;
                case "connection_error":
                    p.Heading = "Нет подключения";
                    p.Description = code == "path_stalled" ? "Данные через туннель не идут. Если включён другой VPN, он может их блокировать. Попытка повторится." :
                        "Туннель не установлен. Попытка повторится.";
                    break;
                case "access_closed":
                    p.Heading = unassigned ? "Сервисы не назначены" : "Доступ не разрешён";
                    p.Description = unassigned ? "Администратор не назначил этому устройству сервисов. Сайты открываются как обычно." :
                        "Доступ для этого устройства выключен администратором.";
                    break;
                case "error":
                    // The service names the cause; only its own failure is an error of the service.
                    bool unreachable = code == "path_connection_failed" || code == "path_unavailable" || code == "policy_connection_failed" ||
                        code == "services_unavailable" || code == "release_unavailable";
                    bool rejected = code == "policy_http_rejected" || code == "policy_update_rejected";
                    bool garbled = (code != null && code.EndsWith("_invalid", StringComparison.Ordinal)) || code == "policy_response_too_large";
                    if (code == "enrollment_missing")
                    {
                        p.Heading = "Регистрация потеряна";
                        p.Description = "Данные регистрации на этом компьютере не найдены. Нажмите «Сбросить…», затем зарегистрируйте устройство по новой ссылке.";
                        break;
                    }
                    p.Heading = unreachable ? "Нет связи с сервером" : rejected ? "Сервер не выдал настройки" : garbled ? "Ответ сервера не принят" : "Ошибка службы";
                    p.Description = unreachable ? "Настройки не получены: сервер недоступен из этой сети. Попытка повторится сама." :
                        rejected ? "Сервер отказал в настройках. Если это повторяется, отправьте отчёт администратору." :
                        garbled ? "Настройки от сервера повреждены. Попытка повторится сама." :
                        "Состояние защиты не подтверждено. Подробности в отчёте.";
                    break;
                case "service_missing":
                    p.Heading = "Служба не установлена";
                    p.Description = "Переустановите программу.";
                    break;
                case "service_stopped":
                    p.Heading = "Служба остановлена";
                    p.Description = "Состояние защиты не подтверждено.";
                    break;
                default:
                    p.Heading = "Состояние неизвестно";
                    p.Description = "Подробности в отчёте.";
                    break;
            }

            bool fresh = view.State == "enrollment_required";
            bool relaxed = warnings.Contains("open");
            selfResolving = selfResolving ?? new string[0];
            p.Checks = new[] {
                new CheckLine { Label = "Блокировка вне туннеля",
                    Value = unassigned ? "не нужна" : relaxed ? "выключена администратором" : view.GuardInstalled ? "включена" : fresh ? "после регистрации" : "не подтверждена",
                    Tone = unassigned || relaxed ? Tone.Off : view.GuardInstalled ? Tone.Open : fresh ? Tone.Off : Tone.Attention },
                new CheckLine { Label = "Туннель", Value = view.Routed ? "подключён" : view.State == "connecting" ? "подключается" : "нет",
                    Tone = view.Routed ? Tone.Open : view.State == "connecting" ? Tone.Working : Tone.Off },
                new CheckLine { Label = "Подтверждение сервера", Value = view.Protected ? "получено" : "нет",
                    Tone = view.Protected ? Tone.Open : view.Routed ? Tone.Working : Tone.Off },
                new CheckLine { Label = "DNS в браузерах",
                    Value = selfResolving.Length != 0 ? String.Join(", ", selfResolving) + ": свой DoH, в обход туннеля" : browsersTold ? "системный DNS, задано Waypoint" : "системный DNS",
                    Tone = selfResolving.Length != 0 ? Tone.Attention : fresh ? Tone.Off : Tone.Open } };
            p.Browsers = selfResolving.Length != 0 || browsersTold;

            // With an offer the services are rows the person can change where
            // it is theirs to; without one, the names the router assigned.
            // The person's own addresses have their own part of the window.
            var entries = (view.Entries ?? new ServiceChoice[0]).Where(e => !OwnAddresses.IsService(e.Id)).ToArray();
            p.Choosing = view.ChoicePending;
            if (view.Own != null)
            {
                p.OwnItems = view.Own.Domains.Concat(view.Own.Networks).ToArray();
                p.OwnCanAdd = !view.Own.Pending && p.OwnItems.Length < view.Own.Limit;
                p.OwnLine = "Добавлено " + p.OwnItems.Length + " из " + view.Own.Limit + " · порты " + String.Join(", ", view.Own.Ports) +
                    " · без туннеля идут напрямую" + (view.Own.Pending ? " · отправляется на сервер" : "") +
                    ". Если сайт уже был открыт, браузеру может понадобиться до минуты.";
                p.OwnProblem = view.Own.Answer == "refused" ? "Сервер не принял список: нужен публичный сайт или адрес, не частная сеть." :
                    view.Own.Answer == "not_allowed" ? "Добавлять свои адреса больше не разрешено." :
                    view.Own.Answer == "too_often" ? "Слишком много изменений за сутки. Попробуйте завтра." : "";
            }
            p.Services = entries.Select(e => new ServiceRow {
                Id = e.Id, Label = e.Label, On = e.On, Closed = e.Closed, CanTurn = !e.Required, ChooseClosed = e.ChooseClosed, CanClose = e.ChooseClosed && e.On,
                Note = e.Required ? (e.Closed ? "обязательный · без туннеля закрыт" : "обязательный · без туннеля напрямую") :
                    !e.On ? "выключен" : e.Closed ? "без туннеля закрыт" : "без туннеля напрямую" }).ToArray();
            p.ServicesLine = unassigned ? "Не назначены" : view.Services.Length != 0 ? String.Join(" · ", view.Services) :
                view.Domains == 0 ? "Не назначены" : "Доменов: " + view.Domains;
            p.ServicesNote = view.Services.Length == 0 ? "" : "Доменов: " + view.Domains;
            var available = view.Available.Where(id => !OwnAddresses.IsService(id)).ToArray();
            p.AvailableLine = available.Length == 0 || entries.Length != 0 ? "" : "По запросу: " + String.Join(", ", available);

            p.Registered = view.GuardInstalled && view.State != "registration_pending" && view.State != "registration_error";
            p.Register = view.State == "enrollment_required" || view.State == "registration_error";
            p.Resume = view.State == "registration_pending" || view.State == "registration_error";
            // Nothing to switch on until the administrator assigns a service or opens access.
            p.Connect = p.Registered && !view.Wanted && view.State != "access_closed";
            p.Disconnect = p.Registered && view.Wanted && view.State != "access_closed";
            p.Update = ClientView.Newer(view.Release, own);

            var notes = new List<string>();
            if (p.Update) notes.Add("Доступна версия " + view.Release + ".");
            if (warnings.Contains("vpn")) notes.Add("Работает другой VPN: сервисы могут не открываться, пока он включён.");
            if (warnings.Contains("proxy")) notes.Add("Включён системный прокси: трафик через него идёт в обход туннеля.");
            if (p.Choosing) notes.Add("Выбор сервисов применяется на сервере.");
            p.Notes = notes.ToArray();
            p.Addresses = new[] { view.ServerName ?? "", view.ServerIP ?? "", view.ServicesSubnet ?? "", view.TunnelSubnet ?? "" };
            return p;
        }

        // The whole own list the service is asked for after one is added or
        // taken away: null when what was typed is neither a site nor an address.
        public static bool OwnChanged(ClientView view, string add, string remove, out string[] domains, out string[] networks)
        {
            domains = view.Own == null ? new string[0] : view.Own.Domains.Where(d => d != remove).ToArray();
            networks = view.Own == null ? new string[0] : view.Own.Networks.Where(n => n != remove).ToArray();
            if (view.Own == null) return false;
            if (add == null) return true;
            var parsed = OwnAddresses.Input(add);
            if (parsed == null) return false;
            if (parsed[0] != null && !domains.Contains(parsed[0])) domains = domains.Concat(new[] { parsed[0] }).ToArray();
            if (parsed[1] != null && !networks.Contains(parsed[1])) networks = networks.Concat(new[] { parsed[1] }).ToArray();
            return domains.Length + networks.Length <= view.Own.Limit;
        }

        // The lists the service is asked for when one switch of one row turns:
        // every optional service that stays on, and every one the person blocks.
        public static void Chosen(ServiceRow[] rows, string id, bool? on, bool? closed, out string[] chosenOn, out string[] chosenClosed)
        {
            var turned = new List<string>(); var blocked = new List<string>();
            foreach (var row in rows ?? new ServiceRow[0])
            {
                bool isOn = row.Id == id && on.HasValue ? on.Value : row.On;
                bool isClosed = row.Id == id && closed.HasValue ? closed.Value : row.Closed;
                if (row.CanTurn && isOn) turned.Add(row.Id);
                if (row.ChooseClosed && isClosed) blocked.Add(row.Id);
            }
            chosenOn = turned.ToArray(); chosenClosed = blocked.ToArray();
        }
    }
}
