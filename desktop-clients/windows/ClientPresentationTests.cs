using System;
using System.Linq;
using IkeV2Manager.Client;

// What the window shows for a state, and what it asks the service for when a
// switch turns: the words, the actions offered and the two lists of a choice.
internal static class ClientPresentationTests
{
    private static readonly Version Own = new Version(2, 3, 0, 0);

    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception("FAIL " + name);
    }

    private static int Main()
    {
        try
        {
            var open = ClientPresentation.Of(new ClientView("protected", true, "none", new[] { "chat" }, 3, 1, true) { Release = "2.3.0" }, Own, null, false);
            Require(open.Tone == Tone.Open && open.Heading == "Доступ открыт" && open.Disconnect && !open.Connect && !open.Register && !open.Update,
                "protection reads as open with a way to switch it off");
            Require(open.Checks.Length == 4 && open.Checks.All(c => c.Tone == Tone.Open), "every check of a protected device is good");

            var fresh = ClientPresentation.Of(new ClientView("enrollment_required"), Own, null, false);
            Require(fresh.Register && !fresh.Connect && !fresh.Disconnect && fresh.Tone == Tone.Off, "an unregistered device is offered registration only");

            var idle = ClientPresentation.Of(new ClientView("access_closed", true) { Warnings = new[] { "idle" } }, Own, null, false);
            Require(idle.Heading == "Сервисы не назначены" && idle.Tone == Tone.Off && !idle.Connect, "a device without services is told so, not alarmed");

            var away = ClientPresentation.Of(new ClientView("error", true, "policy_connection_failed"), Own, null, false);
            Require(away.Heading == "Нет связи с сервером" && away.Tone == Tone.Attention, "an unreachable router is named as the cause");

            var newer = ClientPresentation.Of(new ClientView("blocked", true) { Release = "2.4.0" }, Own, new[] { "Chrome" }, false);
            Require(newer.Update && newer.Notes.Any(n => n.Contains("2.4.0")) && newer.Browsers && newer.Checks[3].Tone == Tone.Attention,
                "a newer release and a browser around the tunnel are both raised");

            var offered = ClientPresentation.Of(new ClientView("protected", true, "none", new[] { "chat" }, 3, 1, true) {
                Entries = new[] {
                    new ServiceChoice { Id = "chat", Label = "Чат", Required = true, On = true, Closed = true },
                    new ServiceChoice { Id = "api", Label = "API", On = false, ChooseClosed = true },
                    new ServiceChoice { Id = "wiki", Label = "Wiki", On = true, Closed = false } },
                ChoicePending = true }, Own, null, false);
            Require(offered.Services.Length == 3 && !offered.Services[0].CanTurn && !offered.Services[0].CanClose &&
                offered.Services[1].CanTurn && !offered.Services[1].CanClose && offered.Services[2].CanTurn && !offered.Services[2].CanClose,
                "only what the offer leaves to the person can be switched");
            Require(offered.Choosing && offered.Notes.Any(n => n.Contains("применяется")), "a choice on its way is shown");
            Require(offered.AvailableLine == "", "an offer replaces the list of services on request");

            string[] on, closed;
            ClientPresentation.Chosen(offered.Services, "api", true, null, out on, out closed);
            Require(on.SequenceEqual(new[] { "api", "wiki" }) && closed.Length == 0, "turning a service on keeps the others as they are");
            ClientPresentation.Chosen(offered.Services, "api", true, true, out on, out closed);
            Require(on.SequenceEqual(new[] { "api", "wiki" }) && closed.SequenceEqual(new[] { "api" }), "blocking a chosen service names it");
            ClientPresentation.Chosen(offered.Services, "wiki", false, null, out on, out closed);
            Require(on.Length == 0 && !on.Contains("chat"), "a required service is never part of a choice");

            Console.WriteLine("Window presentation checks passed: states, actions, services and choices");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
    }
}
