using System;
using System.Collections.Generic;
using System.Linq;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

// Automatic failure reports against a recording of the report service: the
// shared rules of desktop-clients/fixtures/status-codes.json ("auto_report").
internal static class FailureReportsTests
{
    private sealed class Recorder : IFailureTransport
    {
        internal readonly List<string> Sent = new List<string>();
        internal int Status = 201, Retry;
        public int Post(Uri url, string bearer, string json, out int retryAfter, out string answer)
        {
            if (url.AbsolutePath != "/api/v1/reports" || bearer.Length != 64) throw new Exception("FAIL the request goes elsewhere");
            Sent.Add(json);
            retryAfter = Retry;
            answer = Status == 201 ? "{\"id\":\"r" + Sent.Count + "\"}" : "{\"error\":\"rate_limited\"}";
            return Status;
        }
    }

    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception("FAIL " + name);
        Console.WriteLine("PASS " + name);
    }

    private static int Main(string[] args)
    {
        var table = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(System.IO.File.ReadAllText(args[0]));
        var rules = (Dictionary<string, object>)table["auto_report"];
        var allowed = ((object[])rules["context_keys"]).Cast<string>().ToArray();
        string name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
        var queue = new FailureQueue(name);
        var started = new DateTime(2026, 11, 8, 8, 0, 0, DateTimeKind.Utc);
        var now = started.AddHours(1);
        try
        {
            var recorder = new Recorder();
            var reporter = new FailureReporter(queue, recorder, new Uri("https://reports.example.invalid/"));
            string[] faults = { "2026-11-08T08:59:00Z tick InvalidOperationException Guard filter changed",
                "2026-11-08T08:59:01Z policy WebException host vpn.example.com 203.0.113.7 " + Environment.MachineName };
            foreach (string code in new[] { "guard_changed", "needs_reset", "tick_stalled" })
                queue.Record(code, "tick", "seen at 203.0.113.7 by " + Environment.MachineName, faults, now.AddMinutes(-5));
            Require(reporter.SendDue(started, now) == 0 && recorder.Sent.Count == 0, "nothing is sent before the person answers");
            Require(queue.Pending(now).Count == 3, "until then failures wait in the queue");
            queue.Consent = false; queue.Clear();
            Require(reporter.SendDue(started, now) == 0 && queue.Pending(now).Count == 0 && recorder.Sent.Count == 0, "\"do not send\" empties the queue and sends nothing");

            queue.Consent = true;
            foreach (string code in new[] { "guard_changed", "needs_reset", "tick_stalled", "start_failed_acl", "reset_incomplete", "profile_changed" })
                queue.Record(code, "tick", "seen at 203.0.113.7 by " + Environment.MachineName, faults, now.AddMinutes(-5));
            queue.Record("guard_changed", "tick", "again", faults, now.AddMinutes(-5));
            queue.Record("guard_engine_lost", "tick", "fresh", faults, now.AddSeconds(-10));
            Require(reporter.SendDue(started, started.AddSeconds(5)) == 0, "nothing goes in the first seconds after start");
            Require(reporter.SendDue(started, now) == 5 && recorder.Sent.Count == 5, "at most five automatic reports a day from the device");
            Require(queue.Pending(now).Any(e => (string)e["code"] == "guard_engine_lost"), "a failure goes only after its repair had time to tell the outcome");
            var first = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(recorder.Sent[0]);
            var context = (Dictionary<string, object>)first["context"];
            Require((string)first["kind"] == "crash" && (bool)first["submit"] && (string)first["project"] == "waypoint", "a crash report, submitted in one request");
            Require(context.Keys.All(allowed.Contains) && context.ContainsKey("failure_code") && context.ContainsKey("failure_phase"), "only the allowed context keys");
            Require(recorder.Sent.Count(json => json.Contains("guard_changed")) == 1 && recorder.Sent.First(json => json.Contains("guard_changed")).Contains("occurrences: 2"),
                "a repeat of the same failure is counted, not sent twice");
            foreach (string json in recorder.Sent)
                Require(!json.Contains("203.0.113.7") && !json.Contains("vpn.example.com") &&
                    json.IndexOf(Environment.MachineName, StringComparison.OrdinalIgnoreCase) < 0 && !json.Contains("\"host\"") &&
                    System.Text.Encoding.UTF8.GetByteCount(json) <= FailureReporter.Size, "no address, server or computer name, within 8 KB");

            // The next day: the sixth goes; the same failure again within a day stays.
            var tomorrow = now.AddDays(1).AddMinutes(1);
            queue.Record("guard_changed", "tick", "again", faults, tomorrow.AddMinutes(-3));
            int before = recorder.Sent.Count;
            Require(reporter.SendDue(started, tomorrow) >= 1 && recorder.Sent.Count > before, "the next day the queue goes on");
            queue.Record("guard_changed", "tick", "once more", faults, tomorrow.AddMinutes(-2));
            int counted = recorder.Sent.Count;
            reporter.SendDue(started, tomorrow.AddMinutes(1));
            Require(recorder.Sent.Count == counted && queue.Pending(tomorrow).Any(e => (string)e["code"] == "guard_changed"),
                "one report per failure a day; a repeat waits and is counted");

            // The service asks to wait: nothing more before the time it gave.
            recorder.Status = 429; recorder.Retry = 600;
            var later = tomorrow.AddDays(1).AddMinutes(5);
            reporter.SendDue(started, later);
            int asked = recorder.Sent.Count;
            recorder.Status = 201;
            Require(reporter.SendDue(started, later.AddMinutes(5)) == 0 && recorder.Sent.Count == asked, "Retry-After is kept");
            Require(reporter.SendDue(started, later.AddMinutes(11)) >= 1, "and sending goes on after it");
            Console.WriteLine("Failure report checks passed");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
        finally { queue.Forget(); }
    }
}
