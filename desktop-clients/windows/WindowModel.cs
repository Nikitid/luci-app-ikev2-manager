using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace IkeV2Manager.Client
{
    // A service as a line of the window: its rule without the tunnel in
    // words, and whether it works now.
    public sealed class ServiceLine
    {
        public string Id { get; internal set; }
        public string Label { get; internal set; }
        public bool Required { get; internal set; }
        public bool On { get; internal set; }
        public bool Closed { get; internal set; }
        // The rule without the tunnel is the person's to choose.
        public bool ChooseClosed { get; internal set; }
        public string Rule { get; internal set; }
        // Down now, and why in words; "" while it works or nothing is known.
        public bool Failed { get; internal set; }
        public string Problem { get; internal set; }
        // What the rule means, said in full where there is room (Flyout).
        public string RuleInFull { get; internal set; }
    }

    // The status of a section: a line, under it one line of text - on the
    // left what the section is or what is wrong, on the right the state and
    // when it was checked - and a notch per object.
    public sealed class SectionStatus
    {
        public string Left { get; internal set; }
        public string Right { get; internal set; }
        public bool Failed { get; internal set; }
        public bool Stale { get; internal set; }
        public Notch[] Notches { get; internal set; }
    }

    public sealed class Notch
    {
        public string Label { get; internal set; }
        public bool Failed { get; internal set; }
    }

    public sealed class TrayItem
    {
        public int Id { get; internal set; }
        public string Text { get; internal set; }
        public bool Checked { get; internal set; }
        public bool Enabled { get; internal set; }
        public bool Separator { get; internal set; }
        // "connect", "disconnect", "service:<id>", "update", "open", "quit".
        public string Action { get; internal set; }
    }

    // The window of layout Б, decided from one reading of the service:
    // navigation, Overview, Services, own sites, the update, the tray menu.
    // Nothing here draws; the window shows what this decides.
    public sealed class WindowModel
    {
        public string ServicesBadge { get; private set; }
        // Null where the administrator does not let the person add their own.
        public string OwnBadge { get; private set; }
        public ServiceLine[] Required { get; private set; }
        public ServiceLine[] Chosen { get; private set; }
        public ServiceLine[] Offered { get; private set; }
        public SectionStatus Status { get; private set; }
        public string Summary { get; private set; }
        public string SetRequired { get; private set; }
        public string SetChosen { get; private set; }
        public string SetOwn { get; private set; }
        public string ChosenCount { get; private set; }
        public string UpdateLine { get; private set; }
        // "Обновить", "Скачать" or null.
        public string UpdateAction { get; private set; }
        public bool UpdateFailed { get; private set; }
        // "Check now": whether it may be asked, and what the last one said.
        public bool CanCheck { get; private set; }
        public string CheckLine { get; private set; }
        public bool Registered { get; private set; }

        public static WindowModel Of(ClientView view, DateTime now)
        {
            var m = new WindowModel();
            var entries = (view.Entries ?? new ServiceChoice[0]).Where(e => !OwnAddresses.IsService(e.Id)).ToArray();
            var lines = entries.Select(Line).ToArray();
            m.Required = lines.Where(l => l.Required).ToArray();
            m.Chosen = lines.Where(l => !l.Required && l.On).ToArray();
            m.Offered = lines.Where(l => !l.Required && !l.On).OrderBy(l => l.Label, StringComparer.CurrentCultureIgnoreCase).ToArray();
            int on = m.Required.Length + m.Chosen.Length;
            m.ServicesBadge = entries.Length == 0 ? null : on + " из " + entries.Length;
            int own = view.Own == null ? 0 : view.Own.Domains.Length + view.Own.Networks.Length;
            m.OwnBadge = view.Own == null ? null : own + " из " + view.Own.Limit;
            m.Registered = view.State != "enrollment_required" && view.State != "registration_pending" && view.State != "registration_error" &&
                view.GuardInstalled;

            int closedRequired = m.Required.Count(l => l.Closed);
            m.SetRequired = m.Required.Length == 0 ? "Нет" : String.Join(", ", m.Required.Select(l => l.Label)) +
                (closedRequired == 0 ? "" : " · " + closedRequired + " " + Plural(closedRequired, "закрыт", "закрыты", "закрыты") + " без туннеля");
            m.ChosenCount = m.Chosen.Length + " из " + (m.Chosen.Length + m.Offered.Length) + " выданных";
            m.SetChosen = m.Chosen.Length + m.Offered.Length == 0 ? "Не выдано" :
                (m.Chosen.Length == 0 ? "Не выбраны" : String.Join(", ", m.Chosen.Select(l => l.Label))) +
                (m.Offered.Length == 0 ? "" : " · ещё " + m.Offered.Length + " выдано");
            if (view.Own != null)
                m.SetOwn = own == 0 ? "Не добавлены · до " + view.Own.Limit :
                    String.Join(", ", view.Own.Domains.Concat(view.Own.Networks.Select(n => n.EndsWith("/32", StringComparison.Ordinal) ? n.Substring(0, n.Length - 3) : n)).Take(3)) + (own > 3 ? " и ещё " + (own - 3) : "") + " · " + own + " из " + view.Own.Limit;

            m.Summary = view.State == "protected"
                ? on + " " + Plural(on, "сервис", "сервиса", "сервисов") + (own == 0 ? "" : " и " + own + " " + Plural(own, "свой адрес", "своих адреса", "своих адресов")) +
                  " " + (on + own == 1 ? "идёт" : "идут") + " через туннель, остальное напрямую."
                : null;
            m.Status = Section(view, m.Required.Concat(m.Chosen).ToArray(), now);

            m.CanCheck = m.Registered && entries.Length != 0 && (view.CheckNextAt == null || view.CheckNextAt.Value <= now);
            m.CheckLine = view.CheckAnswer == "too_often" || (view.CheckNextAt != null && view.CheckNextAt.Value > now)
                ? "Можно снова через " + Math.Max(1, (int)Math.Ceiling(((view.CheckNextAt ?? now) - now).TotalSeconds)) + " с"
                : view.CheckAnswer == "busy" ? "Роутер уже проверяет" : view.CheckAnswer == "failed" ? "Роутер не ответил" : "";

            var update = view.Update;
            if (update != null && update.Version != "")
            {
                switch (update.State)
                {
                    case "ready":
                        m.UpdateLine = "Есть версия " + update.Version + "." + (update.Auto ? " Поставится сама, когда туннель не нужен." : "");
                        m.UpdateAction = "Обновить";
                        break;
                    case "installing":
                        m.UpdateLine = "Ставится " + update.Version + ". Туннель на минуту отключится и вернётся сам.";
                        break;
                    case "failed":
                        m.UpdateLine = "Обновление " + update.Version + " не прошло проверку и не поставлено.";
                        m.UpdateFailed = true;
                        m.UpdateAction = "Скачать";
                        break;
                    default:
                        m.UpdateLine = "Есть версия " + update.Version + ".";
                        m.UpdateAction = "Скачать";
                        break;
                }
            }
            else if (ClientView.Newer(view.Release, typeof(WindowModel).Assembly.GetName().Version))
            {
                m.UpdateLine = "Есть версия " + view.Release + ".";
                m.UpdateAction = "Скачать";
            }
            return m;
        }

        static ServiceLine Line(ServiceChoice e)
        {
            bool failed = e.Health == "down";
            return new ServiceLine {
                Id = e.Id, Label = e.Label, Required = e.Required, On = e.On, Closed = e.Closed, ChooseClosed = e.ChooseClosed,
                Rule = e.Health == "direct" ? "идёт напрямую" : e.Closed ? "без туннеля закрыт" : "без туннеля напрямую",
                RuleInFull = e.Health == "direct" ? "Администратор направил сервис мимо туннеля." :
                    e.Closed ? "Без туннеля закрыт: не откроется и напрямую." : "Без туннеля открывается напрямую.",
                Failed = failed,
                Problem = !failed ? "" : e.Reason == "no_tunnel" ? "Роутер не отвечает по адресам сервиса: у его выхода нет туннеля" :
                    e.Reason == "silent" ? "Роутер не отвечает по адресам сервиса: через туннель ничего не проходит" : "Роутер не отвечает по адресам сервиса" };
        }

        // "Работают все · проверено 14:02"; on failure the problem by name,
        // in the colour of danger, and the rest calm.
        static SectionStatus Section(ClientView view, ServiceLine[] active, DateTime now)
        {
            string time = now.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture);
            var failed = active.Where(l => l.Failed).ToArray();
            var notches = active.Length >= 3 && active.Length <= 12 ? active.Select(l => new Notch { Label = l.Label, Failed = l.Failed }).ToArray() : new Notch[0];
            var status = new SectionStatus { Notches = notches, Left = view.ServerName ?? "" };
            if (view.State == "status_stale")
            {
                status.Stale = true; status.Right = "Служба не отвечает · последние данные " + time;
            }
            else if (view.State == "connection_error" || view.State == "needs_reset" || view.State == "error" || view.State == "blocked" && view.Wanted)
            {
                status.Failed = active.Any(l => l.Closed);
                status.Left = status.Failed ? "Закрытые без туннеля сервисы недоступны" : view.ServerName ?? "";
                status.Right = status.Failed ? (active.Any(l => !l.Closed) ? "остальные идут напрямую" : "") : "Без туннеля · " + time;
            }
            else if (failed.Length == 1)
            {
                status.Failed = true;
                status.Left = failed[0].Label + " не отвечает";
                status.Right = (active.Length > 1 ? "остальные работают · " : "") + time;
            }
            else if (failed.Length > 1)
            {
                status.Failed = true;
                status.Left = failed.Length + " " + Plural(failed.Length, "сервис не отвечает", "сервиса не отвечают", "сервисов не отвечают");
                status.Right = (failed.Length < active.Length ? "остальные работают · " : "") + time;
            }
            else if (active.Length != 0 && active.All(l => (view.Entries ?? new ServiceChoice[0]).Any(e => e.Id == l.Id && e.Health == "unknown")))
                status.Right = "Проверяю…";
            else status.Right = active.Length == 0 ? "" : "Работают все · проверено " + time;
            return status;
        }

        // Typed in the search of "Add service": by part of the name, any case.
        public static ServiceLine[] Search(ServiceLine[] offered, string query)
        {
            string wanted = (query ?? "").Trim();
            return wanted.Length == 0 ? offered : offered.Where(l => l.Label.IndexOf(wanted, StringComparison.CurrentCultureIgnoreCase) >= 0 ||
                l.Id.IndexOf(wanted, StringComparison.OrdinalIgnoreCase) >= 0).ToArray();
        }

        // What one field of "Own sites and addresses" makes of what was
        // typed: the site or network the router would take, or the reason it
        // would refuse it, in words; checked here before anything is sent.
        public static string OwnInput(string typed, ClientView view, out string refusal)
        {
            refusal = null;
            string reason, value;
            if (OwnAddresses.LooksLikeNetwork(typed)) value = OwnAddresses.CheckNetwork(typed, out reason);
            else value = OwnAddresses.CheckDomain(typed, view.ServerName, out reason);
            if (value == null) { refusal = OwnRefusal(reason); return null; }
            if (view.Own != null && (view.Own.Domains.Contains(value) || view.Own.Networks.Contains(value))) { refusal = "Уже в списке."; return null; }
            if (view.Own != null && view.Own.Domains.Length + view.Own.Networks.Length >= view.Own.Limit)
            {
                refusal = "Добавлено " + view.Own.Limit + " из " + view.Own.Limit + ": уберите один из адресов."; return null;
            }
            return value;
        }

        public static string OwnRefusal(string reason)
        {
            switch (reason)
            {
                case "private": return "Частный адрес: через туннель идут только публичные сайты и адреса.";
                case "shared": return "Общий адрес провайдера: через туннель идут только публичные адреса.";
                case "local": return "Локальный адрес: через туннель идут только публичные адреса.";
                case "documentation": return "Адрес из примеров документации: в интернете его нет.";
                case "fake_ip": return "Служебный адрес, его добавить нельзя.";
                case "multicast": return "Групповой адрес, его добавить нельзя.";
                case "network_size": return "Слишком широкая сеть: не шире /16.";
                case "invalid_network": return "Не похоже на адрес. Например: 8.8.8.8 или 8.8.4.0/24.";
                case "local_name": return "Имя локальной сети: через туннель идут только публичные сайты.";
                case "server_name": return "Это сам сервер Waypoint: через туннель его пустить нельзя.";
                case "over_limit": return "Предел адресов достигнут.";
                default: return "Не похоже на сайт. Например: docs.example.org.";
            }
        }

        // The account of a reset, as the window says it.
        public static string ResetSummary(RemovalResult result)
        {
            if (result == null) return "Сброс завершён.";
            var removed = new List<string>();
            if (result.Connections > 0) removed.Add(result.Connections == 1 ? "VPN-подключение" : "VPN-подключения (" + result.Connections + ")");
            if (result.Filters > 0) removed.Add("фильтры (" + result.Filters + ")");
            if (result.Hosts > 0) removed.Add("записи hosts (" + result.Hosts + ")");
            if (result.NameRules > 0) removed.Add("правила имён (" + result.NameRules + ")");
            if (result.Registration) removed.Add("регистрация");
            if (result.BrowserPolicies > 0) removed.Add("политики браузеров");
            string done = removed.Count == 0 ? "Удалять было нечего." : "Удалено: " + String.Join(", ", removed) + ".";
            if (result.Complete) return done + " Программа осталась.";
            var names = new Dictionary<string, string> { { "filters", "фильтры" }, { "connection", "VPN-подключение" }, { "names", "правила имён" },
                { "hosts", "записи hosts" }, { "folder", "папка службы" }, { "browsers", "политики браузеров" }, { "service_stop", "служба не остановилась" },
                { "service_start", "служба не запустилась" }, { "service_missing", "служба не установлена" }, { "service_running", "служба работала" } };
            return done + " Не удалось: " + String.Join(", ", result.Failed.Select(f => names.ContainsKey(f) ? names[f] : f)) + ". Повторите сброс.";
        }

        // The menu at the icon: the state, the switch, the services by choice
        // with a tick, an update, the window and the exit. The set is changed
        // only in the window.
        public static TrayItem[] Tray(ClientView view, ClientPresentation p, WindowModel m, DateTime now)
        {
            var items = new List<TrayItem>();
            int id = 1;
            Action<string, string, bool, bool> add = (text, action, enabled, ticked) =>
                items.Add(new TrayItem { Id = id++, Text = text, Action = action, Enabled = enabled, Checked = ticked });
            Action separate = () => items.Add(new TrayItem { Id = 0, Separator = true });
            add(p.Heading, null, false, false);
            if (!String.IsNullOrEmpty(view.ServerName)) add(view.ServerName + " · проверено " + now.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture), null, false, false);
            if (p.Disconnect) add("Отключить", "disconnect", true, false);
            else if (p.Connect) add("Подключить", "connect", true, false);
            if (m.Chosen.Length + m.Offered.Length != 0 && m.Registered)
            {
                separate();
                add("По выбору", null, false, false);
                foreach (var line in m.Chosen.Concat(m.Offered).Take(16))
                    add(line.Label, "service:" + line.Id, !view.ChoicePending, line.On);
            }
            if (m.UpdateAction != null) { separate(); add(m.UpdateLine.Split('.')[0] + " · " + m.UpdateAction, "update", true, false); }
            separate();
            add("Открыть Waypoint", "open", true, false);
            add("Выход из Waypoint", "quit", true, false);
            return items.ToArray();
        }

        public static string Plural(int count, string one, string few, string many)
        {
            int last = Math.Abs(count) % 100, unit = last % 10;
            if (last >= 11 && last <= 14) return many;
            return unit == 1 ? one : unit >= 2 && unit <= 4 ? few : many;
        }
    }
}
