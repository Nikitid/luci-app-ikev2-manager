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
            var open = ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now);
            if (open.State != "protected" || !open.Protected || !(bool)new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(open.Report())["Protected"])
                throw new Exception("Confirmed protection was not reported");
            data["Protected"] = false; Check(data, 123, now, "status_invalid");
            data["Protected"] = true; data["ConnectionError"] = "path_unavailable"; Check(data, 123, now, "status_invalid");
            data["ConnectionError"] = "none"; data["GuardInstalled"] = false; Check(data, 123, now, "status_invalid");
            data["GuardInstalled"] = true; data["State"] = "tunnel_connected"; Check(data, 123, now, "status_invalid");
            data["Protected"] = false;
            foreach (string code in new[] {"path_unavailable", "path_connection_failed", "path_response_invalid", "path_different_policy", "device_access_revoked"}) {
                data["ConnectionError"] = code;
                var waiting = ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), 123, now);
                if (waiting.State != "tunnel_connected" || waiting.Protected || waiting.ConnectionError != code) throw new Exception("Path refusal was lost: " + code);
            }
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
        if (report.Count != 6 || report.ContainsKey("ProcessId") || report.ContainsKey("PrivateKey"))
            throw new Exception("Diagnostic report contains unexpected data");
    }
}
