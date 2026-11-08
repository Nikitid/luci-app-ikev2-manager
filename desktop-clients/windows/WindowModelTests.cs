using System;
using System.Linq;
using IkeV2Manager.Client;

// The window of layout Б, decided from a reading of the service: the badges,
// the set in three lines, the section status with its notches, the search of
// "Add service", own addresses refused before they are sent, the update, the
// account of a reset and the menu at the icon.
internal static class WindowModelTests
{
    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception("FAIL " + name);
        Console.WriteLine("PASS " + name);
    }

    private static ServiceChoice S(string id, string label, bool required, bool on, bool closed, string health = "ok", string reason = "", bool choose = false)
    {
        return new ServiceChoice { Id = id, Label = label, Required = required, On = on, Closed = closed, Health = health, Reason = reason, ChooseClosed = choose };
    }

    private static int Main(string[] args)
    {
        // The window's demonstration statuses read as what they show.
        if (args.Length == 1)
            foreach (string file in System.IO.Directory.GetFiles(args[0], "*.json"))
            {
                var data = new System.Web.Script.Serialization.JavaScriptSerializer().Deserialize<System.Collections.Generic.Dictionary<string, object>>(System.IO.File.ReadAllText(file));
                var at = DateTime.Parse((string)data["UpdatedAtUtc"], System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal);
                at = DateTime.SpecifyKind(at, DateTimeKind.Utc);
                var read = ClientStatusReader.Evaluate(System.IO.File.ReadAllText(file), 4242, at);
                Require(read.State == (string)data["State"] && read.Entries.Length == 18, System.IO.Path.GetFileName(file) + " reads as " + data["State"]);
            }
        var now = new DateTime(2026, 11, 7, 14, 2, 0, DateTimeKind.Local);
        var offered = Enumerable.Range(1, 13).Select(i => S("opt" + i, i == 1 ? "Telegram" : i == 2 ? "Steam" : "Сервис " + i, false, false, false, "unknown")).ToArray();
        var entries = new[] { S("portal", "Рабочий портал", true, true, true), S("books", "Бухгалтерия", true, true, true),
            S("mail", "Почта", true, true, false), S("gpt", "ChatGPT", true, true, false), S("yt", "YouTube", false, true, false, choose: true) }.Concat(offered).ToArray();
        var own = (OwnStatus)Activator.CreateInstance(typeof(OwnStatus));
        own.Limit = 20; own.Ports = new[] { 80, 443 }; own.Domains = new[] { "docs.example.org" }; own.Networks = new[] { "203.0.113.7/32" }; own.Answer = "";
        var view = new ClientView("protected", true, "none", wanted: true) { Entries = entries, Own = own, ServerName = "vpn.example.net", CheckAnswer = "" };

        var m = WindowModel.Of(view, now);
        Require(m.ServicesBadge == "5 из 18" && m.OwnBadge == "2 из 20", "navigation badges: services and own addresses");
        Require(m.SetRequired == "Рабочий портал, Бухгалтерия, Почта, ChatGPT · 2 закрыты без туннеля", "the required line of the set");
        Require(m.SetChosen == "YouTube · ещё 13 выдано" && m.ChosenCount == "1 из 14 выданных", "the chosen line and its count");
        Require(m.Summary == "5 сервисов и 2 своих адреса идут через туннель, остальное напрямую.", "the summary under the heading");
        Require(!m.Status.Failed && m.Status.Right == "Работают все · проверено 14:02" && m.Status.Notches.Length == 5, "all working: one calm line and a notch per service");
        Require(m.Required.First(l => l.Id == "portal").Rule == "без туннеля закрыт" && m.Required.First(l => l.Id == "mail").Rule == "без туннеля напрямую",
            "the rule without the tunnel in words on every line");

        entries[1] = S("books", "Бухгалтерия", true, true, true, "down", "silent");
        m = WindowModel.Of(view, now);
        Require(m.Status.Failed && m.Status.Left == "Бухгалтерия не отвечает" && m.Status.Right == "остальные работают · 14:02" &&
            m.Status.Notches.Count(n => n.Failed) == 1, "one service down: named, in danger, the rest calm");
        Require(m.Required.First(l => l.Id == "books").Problem.StartsWith("Роутер не отвечает", StringComparison.Ordinal), "the line says why");

        Require(WindowModel.Search(m.Offered, "te").Select(l => l.Label).SequenceEqual(new[] { "Steam", "Telegram" }) &&
            WindowModel.Search(m.Offered, "TELE").Length == 1 && WindowModel.Search(m.Offered, "").Length == 13, "search among the offered by part of the name, any case");

        string refusal;
        Require(WindowModel.OwnInput("10.0.0.5", view, out refusal) == null && refusal.StartsWith("Частный", StringComparison.Ordinal), "a private address is refused before it is sent");
        Require(WindowModel.OwnInput("vpn.example.net", view, out refusal) == null && refusal.Contains("сервер"), "the server itself is refused");
        Require(WindowModel.OwnInput("https://Chat.Example.NET/x", view, out refusal) == "chat.example.net" && refusal == null, "a link is taken for its host");
        Require(WindowModel.OwnInput("docs.example.org", view, out refusal) == null && refusal == "Уже в списке.", "a site already there");
        own.Domains = Enumerable.Range(1, 19).Select(i => "s" + i + ".example.org").ToArray();
        Require(WindowModel.OwnInput("more.example.org", view, out refusal) == null && refusal.Contains("20 из 20"), "the limit is said before sending");

        view = new ClientView("protected", true, "none", wanted: true) { Entries = entries, ServerName = "vpn.example.net",
            Update = new UpdateStatus { Version = "3.0.1", State = "ready", Auto = true } };
        m = WindowModel.Of(view, now);
        Require(m.UpdateLine == "Есть версия 3.0.1. Поставится сама, когда туннель не нужен." && m.UpdateAction == "Обновить", "a checked update waits for its moment");
        view.Update = new UpdateStatus { Version = "3.0.1", State = "failed", Auto = true };
        m = WindowModel.Of(view, now);
        Require(m.UpdateFailed && m.UpdateLine.Contains("не прошло проверку"), "a forged update is said not installed");

        view.CheckNextAt = now.ToUniversalTime().AddSeconds(20); view.CheckAnswer = "too_often";
        m = WindowModel.Of(view, now.ToUniversalTime());
        Require(!m.CanCheck && m.CheckLine == "Можно снова через 20 с", "check now: the wait is said");

        var damaged = new ClientView("needs_reset", true, "damaged_plan", wanted: true) { Entries = entries };
        var broken = WindowModel.Of(damaged, now);
        var brokenWords = ClientPresentation.Of(damaged, new Version(2, 3, 0, 0), null, false);
        Require(broken.Status.Failed && broken.Status.Right != null && !broken.Status.Right.StartsWith("Работают", StringComparison.Ordinal) &&
            !brokenWords.Connect && !brokenWords.Disconnect, "a device that needs a reset never says its services work, and offers no switch");

        var reset = new RemovalResult { Connections = 1, Filters = 12, Hosts = 8, Registration = true, BrowserPolicies = 2 };
        Require(WindowModel.ResetSummary(reset) == "Удалено: VPN-подключение, фильтры (12), записи hosts (8), регистрация, политики браузеров. Программа осталась.",
            "the reset says what it removed");
        reset.Fail("filters");
        Require(WindowModel.ResetSummary(reset).EndsWith("Не удалось: фильтры. Повторите сброс.", StringComparison.Ordinal), "and what it could not");
        Require(WindowModel.ResetSummary(new RemovalResult()) == "Удалять было нечего. Программа осталась.", "a reset with nothing left");

        var p = ClientPresentation.Of(view, new Version(2, 3, 0, 0), null, false);
        var tray = WindowModel.Tray(view, p, WindowModel.Of(view, now), now);
        Require(tray[0].Text == "Доступ открыт" && !tray[0].Enabled && tray.Any(t => t.Action == "disconnect") &&
            tray.Any(t => t.Action == "service:yt" && t.Checked) && tray.Any(t => t.Action == "service:opt1" && !t.Checked) &&
            tray.Last().Action == "quit", "the tray menu: state, switch, services by choice with a tick, exit");
        Require(WindowModel.Plural(1, "a", "b", "c") == "a" && WindowModel.Plural(3, "a", "b", "c") == "b" && WindowModel.Plural(11, "a", "b", "c") == "c" &&
            WindowModel.Plural(22, "a", "b", "c") == "b", "Russian plurals");
        Console.WriteLine("Window model checks passed");
        return 0;
    }
}
