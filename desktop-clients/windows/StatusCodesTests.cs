using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

// The shared table of status codes and their phrases, fixtures/status-codes.json,
// against what this client can produce and says: every state and cause the
// service publishes has its row, the reader accepts what the table promises,
// and the window says what the table says.
internal static class StatusCodesTests
{
    private static readonly Version Own = new Version(2, 3, 0, 0);

    private sealed class Row
    {
        public string Key;
        public string[] States, Errors, Warnings;
        public bool Wanted;
        public string Heading, Detail;
    }

    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception("FAIL " + name);
    }

    private static string[] Strings(object value)
    {
        return value == null ? new string[0] : ((IEnumerable)value).Cast<object>().Select(item => (string)item).ToArray();
    }

    private static IDictionary<string, object> Map(object value)
    {
        return (IDictionary<string, object>)value;
    }

    private static string Russian(object phrase, string key, string what)
    {
        var words = Map(phrase);
        Require(words.ContainsKey("en") && ((string)words["en"]).Length > 0, key + ": English " + what);
        Require(words.ContainsKey("ru") && ((string)words["ru"]).Length > 0, key + ": Russian " + what);
        return (string)words["ru"];
    }

    private static int Main(string[] args)
    {
        try
        {
            var table = Map(new JavaScriptSerializer().DeserializeObject(File.ReadAllText(args[0])));
            var rows = new List<Row>();
            foreach (object item in (IEnumerable)table["phrases"])
            {
                var phrase = Map(item);
                string key = (string)phrase["key"];
                var when = Map(phrase["when"]);
                if (!when.ContainsKey("windows")) continue;
                var mine = Map(when["windows"]);
                rows.Add(new Row {
                    Key = key, States = Strings(phrase["states"]),
                    Errors = mine.ContainsKey("error") ? Strings(mine["error"]) : new[] { "none" },
                    Warnings = mine.ContainsKey("warnings") ? Strings(mine["warnings"]) : new string[0],
                    Wanted = mine.ContainsKey("wanted") && (bool)mine["wanted"],
                    Heading = Russian(phrase["heading"], key, "heading"), Detail = Russian(phrase["detail"], key, "detail") });
            }

            // What the table has is what the client has, and the other way round.
            var published = ClientStatusCodes.Published.Concat(ClientStatusCodes.Unreadable).OrderBy(x => x).ToArray();
            var tabled = rows.SelectMany(r => r.States).Distinct().OrderBy(x => x).ToArray();
            Require(published.SequenceEqual(tabled), "states: client " + String.Join(",", published) + " against table " + String.Join(",", tabled));
            var named = rows.SelectMany(r => r.Errors).Where(e => e != "none").Distinct().ToArray();
            foreach (string cause in ClientStatusCodes.Causes)
                Require(named.Contains(cause), "the table has no phrase for cause " + cause);
            foreach (string code in named)
                Require(ClientStatusCodes.Causes.Contains(code) || ClientStatusCodes.NumberedCauses.Any(prefix => code.StartsWith(prefix, StringComparison.Ordinal)),
                    "the table names a cause the service never publishes: " + code);
            foreach (string prefix in ClientStatusCodes.NumberedCauses)
                Require(named.Any(code => code.StartsWith(prefix, StringComparison.Ordinal)), "the table has no example of " + prefix + "N");

            // The window says what the table says, for every state and cause.
            DateTime now = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
            int phrases = 0;
            foreach (Row row in rows)
                foreach (string state in row.States)
                    foreach (string error in row.Errors)
                    {
                        var view = new ClientView(state, state != "enrollment_required", error, wanted: row.Wanted) { Warnings = row.Warnings };
                        var window = ClientPresentation.Of(view, Own, null, false);
                        string where = row.Key + " " + state + "/" + error;
                        Require(window.Heading == row.Heading, where + ": heading is \"" + window.Heading + "\", the table says \"" + row.Heading + "\"");
                        Require(window.Description == row.Detail.Replace("{code}", error), where + ": description is \"" + window.Description + "\", the table says \"" + row.Detail + "\"");
                        phrases++;
                    }

            // A code is readable before it is written: the reader takes what the table promises.
            var serializer = new JavaScriptSerializer();
            foreach (Row row in rows)
                foreach (string state in row.States.Where(s => ClientStatusCodes.Published.Contains(s)))
                    foreach (string error in row.Errors)
                    {
                        var read = ClientStatusReader.Evaluate(Status(state, error, now, serializer), 123, now);
                        Require(read.State == state && read.ConnectionError == error, row.Key + ": the reader refused " + state + "/" + error + " as " + read.State);
                    }
            foreach (string cause in ClientStatusCodes.Causes.Concat(ClientStatusCodes.NumberedCauses.Select(prefix => prefix + "7")))
            {
                var read = ClientStatusReader.Evaluate(Status("error", cause, now, serializer), 123, now);
                Require(read.State == "error" && read.ConnectionError == cause, "the reader refused the cause " + cause);
            }

            // Failure reports the service sends by itself: the rules, as written once for both systems.
            var auto = Map(table["auto_report"]);
            Require((string)auto["kind"] == "crash" && (string)auto["project"] == "waypoint", "automatic reports are of the crash kind in the waypoint project");
            var limits = Map(auto["limits"]);
            Require((int)limits["per_device_per_day"] == 5 && (int)limits["per_fingerprint_per_day"] == 1, "automatic report limits per day");
            Require((int)limits["queue_entries"] == 20 && (int)limits["queue_days"] == 7 && (bool)limits["honour_retry_after"], "automatic report queue and Retry-After");
            var failures = ((IEnumerable)auto["failures"]).Cast<object>().Select(Map).ToArray();
            var codes = failures.Select(f => (string)f["failure_code"]).ToArray();
            Require(codes.Length > 0 && codes.Distinct().Count() == codes.Length, "a failure code is listed once");
            foreach (var failure in failures)
            {
                var platforms = Strings(failure["platforms"]);
                Require(platforms.Length > 0 && platforms.All(p => p == "macos" || p == "windows"), "failure platforms of " + failure["failure_code"]);
                Require(((string)failure["when"]).Length > 0, "failure rule of " + failure["failure_code"]);
            }
            var never = Map(auto["never_reported"]);
            var environment = Strings(never["codes"]).Concat(Strings(never["states"])).ToArray();
            Require(!environment.Intersect(codes).Any(), "an environment code is reported as a failure");
            var allowed = Strings(auto["context_keys"]).Concat(Strings(auto["project_context_keys"])).ToArray();
            var forbidden = Strings(auto["forbidden"]);
            Require(allowed.Length > 0 && !allowed.Intersect(forbidden).Any(), "a report key that may carry a name or an address");
            foreach (string key in new[] { "failure_code", "failure_phase", "app_version", "os_version", "architecture", "language" })
                Require(allowed.Contains(key), "report key " + key);

            Console.WriteLine("Status code tests passed: " + phrases + " phrases, " + published.Length + " states, " + named.Length + " causes");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
    }

    // A status of the shape the service writes (version 3), for one state and cause.
    private static string Status(string state, string error, DateTime now, JavaScriptSerializer serializer)
    {
        var data = new Dictionary<string, object> { { "Version", 3 }, { "State", state }, { "GuardInstalled", state != "enrollment_required" },
            { "Protected", state == "protected" }, { "UpdatedAtUtc", now.ToString("o") }, { "ProcessId", 123 }, { "ConnectionError", error },
            { "Services", new string[0] }, { "Available", new string[0] }, { "Release", "" }, { "Warnings", new string[0] },
            { "Domains", 0 }, { "Revision", 0 }, { "Wanted", true } };
        return serializer.Serialize(data);
    }
}
