using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

internal static class ClientStatusTests
{
    private static int Main()
    {
        try
        {
            DateTime now = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
            var data = new Dictionary<string, object> { { "Version", 1 }, { "State", "blocked" },
                { "GuardInstalled", true }, { "Protected", false }, { "UpdatedAtUtc", now.ToString("o") }, { "ProcessId", 123 } };
            Check(data, 123, now, "blocked");
            Check(data, 124, now, "status_process_mismatch");
            Check(data, 123, now.AddSeconds(16), "status_stale");
            Check(data, 123, now.AddSeconds(-3), "status_stale");
            data["Protected"] = true;
            Check(data, 123, now, "status_invalid");
            data["Protected"] = false;
            data["GuardInstalled"] = false;
            Check(data, 123, now, "status_invalid");
            data["State"] = "enrollment_required";
            Check(data, 123, now, "enrollment_required");
            data["State"] = "registration_pending";
            Check(data, 123, now, "registration_pending");
            data["State"] = "registration_error";
            Check(data, 123, now, "registration_error");
            data["Version"] = 2; data["ConnectionError"] = "native_868"; data["State"] = "connection_error"; data["GuardInstalled"] = true;
            Check(data, 123, now, "connection_error");
            foreach (string code in new[] {"interface_missing", "projection_missing", "route_interface", "route_source", "route_prefix", "route_loopback", "route_fields_127"}) {
                data["ConnectionError"] = code;
                var view = ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now);
                if (view.State != "connection_error" || view.ConnectionError != code ||
                    (string)new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(view.Report())["ConnectionError"] != code)
                    throw new Exception("Safe connection diagnosis was lost");
            }
            // Protection is one consistent statement or it is not accepted.
            data["ConnectionError"] = "none"; data["State"] = "protected"; data["Protected"] = true;
            Check(data, 123, now, "status_invalid");
            data["Version"] = 3; data["Services"] = new[] { "api", "mail" }; data["Available"] = new[] { "wiki" }; data["Release"] = "2.3.0"; data["Warnings"] = new[] { "proxy" }; data["Domains"] = 5; data["Revision"] = 4; data["Wanted"] = true;
            var open = ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now);
            if (open.State != "protected" || !open.Protected || !(bool)new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(open.Report())["Protected"])
                throw new Exception("Confirmed protection was not reported");
            if (open.Services.Length != 2 || open.Available.Length != 1 || open.Domains != 5 || open.Revision != 4 || !open.Wanted || !open.Routed) throw new Exception("Assigned services were lost");
            if (open.Release != "2.3.0" || !ClientView.Newer("2.3.0", new Version(2, 2, 9, 0)) || ClientView.Newer("2.3.0", new Version(2, 3, 0, 0)) ||
                ClientView.Newer("", new Version(1, 0, 0, 0)) || ClientView.Newer("2.2.9", new Version(2, 3, 0, 0))) throw new Exception("Release comparison is wrong");
            data["Version"] = 4;
            data["ServerName"] = "vpn.example.com"; data["ServerIP"] = "203.0.113.7";
            data["ServicesSubnet"] = "172.30.16.0/20"; data["TunnelSubnet"] = "10.40.50.0/24";
            var addressed = ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now);
            if (addressed.State != "protected" || addressed.ServerName != "vpn.example.com" || addressed.ServerIP != "203.0.113.7" ||
                addressed.ServicesSubnet != "172.30.16.0/20" || addressed.TunnelSubnet != "10.40.50.0/24") throw new Exception("Connection addresses were lost");
            foreach (string invalid in new[] { "0.0.0.0/0", "10.40.50.1/24", "10.40.50.0/33", "10.40.50.0/024", "https://example.com/" }) {
                data["TunnelSubnet"] = invalid;
                if (ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now).State != "status_invalid") throw new Exception("Invalid network accepted");
            }
            data["TunnelSubnet"] = "";
            if (ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now).State != "protected") throw new Exception("Unknown address changed protection");
            if (addressed.Entries.Length != 0 || addressed.ChoicePending) throw new Exception("An older status claimed services to choose");
            // Version 5 carries the offered services as the window shows them,
            // each in the one shape the service writes, or nothing is taken.
            data["Version"] = 5; data["ChoicePending"] = true;
            Func<string, string, bool, bool, Dictionary<string, object>> service = (id, label, required, on) => new Dictionary<string, object> {
                { "Id", id }, { "Label", label }, { "Required", required }, { "On", on }, { "Closed", required }, { "ChooseClosed", !required } };
            data["Entries"] = new object[] { service("mail", "Почта", true, true), service("wiki", "Wiki", false, false) };
            var offered = ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now);
            if (offered.State != "protected" || offered.Entries.Length != 2 || !offered.ChoicePending || offered.Entries[0].Label != "Почта" ||
                !offered.Entries[0].Required || !offered.Entries[0].Closed || offered.Entries[1].On || !offered.Entries[1].ChooseClosed)
                throw new Exception("Offered services were lost");
            var extra = service("wiki", "Wiki", false, false); extra["Domains"] = 3;
            var many = new object[65];
            for (int i = 0; i < many.Length; i++) many[i] = service("s" + i, "S", false, false);
            foreach (object[] spoiled in new[] {
                new object[] { extra }, new object[] { service("../wiki", "Wiki", false, false) }, new object[] { service("wiki", "<b>", false, false) },
                new object[] { service("wiki", "", false, false) }, new object[] { service("wiki", new string('x', 65), false, false) },
                new object[] { service("mail", "Mail", true, false) }, new object[] { service("wiki", "Wiki", false, false), service("wiki", "Wiki", false, false) },
                many })
            {
                data["Entries"] = spoiled; Check(data, 123, now, "status_invalid");
            }
            // Version 6 adds the person's own addresses, null where not allowed.
            data["Entries"] = new object[0];
            data["Version"] = 6; Check(data, 123, now, "status_invalid");
            data["Own"] = null;
            if (ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now).Own != null) throw new Exception("No right was read as one");
            Func<Dictionary<string, object>> own = () => new Dictionary<string, object> { { "Limit", 3 }, { "Ports", new[] { 80, 443 } },
                { "Domains", new[] { "home.example.org" } }, { "Networks", new[] { "203.0.113.0/24" } }, { "Pending", true }, { "Answer", "" } };
            data["Own"] = own();
            var kept = ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now).Own;
            if (kept == null || kept.Limit != 3 || kept.Domains[0] != "home.example.org" || kept.Networks[0] != "203.0.113.0/24" || !kept.Pending)
                throw new Exception("The own addresses were lost");
            foreach (var spoil in new Action<Dictionary<string, object>>[] { d => d["Limit"] = 40, d => d["Ports"] = new int[0], d => d["Domains"] = new[] { "not a name" },
                d => d["Networks"] = new[] { "999.1.1.1/32" }, d => d["Answer"] = "<b>", d => d["Extra"] = 1 })
            {
                var spoiled = own(); spoil(spoiled); data["Own"] = spoiled; Check(data, 123, now, "status_invalid");
            }
            data.Remove("Own"); data["Version"] = 5;
            data.Remove("ChoicePending"); Check(data, 123, now, "status_invalid");
            data.Remove("Entries"); data["Version"] = 4;
            data["Version"] = 3; foreach (string key in new[] { "ServerName", "ServerIP", "ServicesSubnet", "TunnelSubnet" }) data.Remove(key);
            if (open.Warnings.Length != 1 || open.Warnings[0] != "proxy") throw new Exception("A warning was lost");
            data["Warnings"] = new[] { "<b>" }; Check(data, 123, now, "status_invalid");
            data["Warnings"] = new string[0];
            data["Release"] = "https://example.com/setup.exe"; Check(data, 123, now, "status_invalid");
            data["Release"] = "2.3.0";
            data["Available"] = new[] { "../wiki" }; Check(data, 123, now, "status_invalid");
            data["Available"] = new[] { "wiki" };
            data["Services"] = new[] { "Not A Service" }; Check(data, 123, now, "status_invalid");
            data["Services"] = new[] { "api", "mail" }; data["Wanted"] = false; Check(data, 123, now, "status_invalid");
            data["Wanted"] = true;
            data["Protected"] = false; Check(data, 123, now, "status_invalid");
            data["Protected"] = true; data["ConnectionError"] = "path_unavailable"; Check(data, 123, now, "status_invalid");
            data["ConnectionError"] = "none"; data["GuardInstalled"] = false; Check(data, 123, now, "status_invalid");
            data["GuardInstalled"] = true; data["State"] = "tunnel_connected"; Check(data, 123, now, "status_invalid");
            data["Protected"] = false;
            foreach (string code in new[] {"path_unavailable", "path_connection_failed", "path_response_invalid", "path_different_policy", "device_access_revoked", "path_stalled"}) {
                data["ConnectionError"] = code;
                var waiting = ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now);
                if (waiting.State != "tunnel_connected" || waiting.Protected || waiting.ConnectionError != code) throw new Exception("Path refusal was lost: " + code);
            }
            data["ConnectionError"] = "none"; data["State"] = "access_closed"; data["Wanted"] = false;
            if (ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now).State != "access_closed") throw new Exception("Closed access was not reported");
            data["State"] = "registration_pending"; data["ConnectionError"] = "enrollment_connection_failed"; data["GuardInstalled"] = false;
            if (ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now).ConnectionError != "enrollment_connection_failed") throw new Exception("The reason a registration waits was lost");
            // The window names why the service stands in error.
            data["State"] = "error";
            foreach (string code in new[] {"policy_connection_failed", "policy_http_rejected", "services_unavailable", "service_fault"}) {
                data["ConnectionError"] = code;
                if (ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now).ConnectionError != code) throw new Exception("The cause of an error was lost: " + code);
            }
            data["GuardInstalled"] = true;
            data["State"] = "connection_error";
            data["ConnectionError"] = "credential=secret";
            Check(data, 123, now, "status_invalid");
            data["ConnectionError"] = "none";
            data["PrivateKey"] = "not-a-real-key";
            Check(data, 123, now, "status_invalid");
            if (ClientStatusReader.Evaluate("{", 123, now).State != "status_invalid") throw new Exception("Malformed status was accepted");
            if (ClientStatusReader.Read("IKEv2Manager-Test-" + Guid.NewGuid().ToString("N")).State != "service_missing")
                throw new Exception("Missing SCM service was not recognized");
            Console.WriteLine("Client status checks passed: freshness, process identity, inconsistent state, unsupported protection and missing service");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }

    private static void Check(Dictionary<string, object> data, uint pid, DateTime now, string expected)
    {
        var view = ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), pid, now);
        if (view.State != expected || view.Protected) throw new Exception("Client status check failed: " + expected);
        var report = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(view.Report());
        if (report.Count != 15 || report.ContainsKey("ProcessId") || report.ContainsKey("PrivateKey"))
            throw new Exception("Diagnostic report contains unexpected data");
    }
}
