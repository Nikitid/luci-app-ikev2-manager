using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace IkeV2Manager.Client
{
    // One request to the report service, so sending can be followed without
    // a network: the status, the seconds of a Retry-After, and the answer.
    internal interface IFailureTransport
    {
        int Post(Uri url, string bearer, string json, out int retryAfter, out string answer);
    }

    internal sealed class WebFailureTransport : IFailureTransport
    {
        public int Post(Uri url, string bearer, string json, out int retryAfter, out string answer)
        {
            retryAfter = 0; answer = "";
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "POST";
            request.Timeout = request.ReadWriteTimeout = 30000;
            request.AllowAutoRedirect = false;
            request.ContentType = "application/json";
            request.Headers["Authorization"] = "Bearer " + bearer;
            byte[] body = new UTF8Encoding(false).GetBytes(json);
            request.ContentLength = body.Length;
            using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
            HttpWebResponse response;
            try { response = (HttpWebResponse)request.GetResponse(); }
            catch (WebException failure)
            {
                response = failure.Response as HttpWebResponse;
                if (response == null) throw;
            }
            using (response)
            using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
                int.TryParse(response.Headers["Retry-After"], out retryAfter);
                var buffer = new char[16384];
                answer = new string(buffer, 0, reader.ReadBlock(buffer, 0, buffer.Length));
                return (int)response.StatusCode;
            }
        }
    }

    // Sends the failures waiting in the queue as reports of the crash kind
    // (desktop-clients/fixtures/status-codes.json, "auto_report"), and only
    // after the person said "send": until then nothing leaves the computer.
    // A failure goes once its self-repair had time to tell its outcome, one
    // report per failure and version a day - repeats are counted into the
    // next one - and at most five a day from the device; a Retry-After of the
    // service is kept. A report carries the failure's code and phase, the
    // program's version, Windows' version, the processor and the language,
    // and a machine-written description: never a name of the computer or the
    // person, an address, a service or a site.
    internal sealed class FailureReporter
    {
        internal const int PerDevicePerDay = 5;
        internal static readonly TimeSpan Settle = TimeSpan.FromSeconds(60), AfterStart = TimeSpan.FromSeconds(10);
        internal const int Size = 8192;
        private readonly FailureQueue queue;
        private readonly IFailureTransport transport;
        private readonly Uri endpoint;

        internal FailureReporter(FailureQueue queue, IFailureTransport transport = null, Uri endpoint = null)
        {
            this.queue = queue;
            this.transport = transport ?? new WebFailureTransport();
            this.endpoint = endpoint ?? ProblemReporter.DefaultEndpoint;
        }

        // Returns how many went. Never throws.
        internal int SendDue(DateTime startedAt, DateTime? at = null)
        {
            try
            {
                DateTime now = at ?? DateTime.UtcNow;
                if (queue.Consent != true || now - startedAt < AfterStart) return 0;
                {
                    DateTime wait;
                    if (DateTime.TryParse(Get("RetryAfter"), System.Globalization.CultureInfo.InvariantCulture,
                        System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out wait) && now < wait) return 0;
                    var ledger = Ledger(Get("Sent"), now);
                    int sent = 0;
                    foreach (var entry in queue.Pending(now).OrderBy(e => (string)e["last"], StringComparer.Ordinal).ToList())
                    {
                        DateTime last = Parse((string)entry["last"]);
                        if (now - last < Settle) continue;
                        string fingerprint = (string)entry["code"] + "|" + (string)entry["phase"] + "|" + (string)entry["version"];
                        if (ledger.Any(l => (string)l["fingerprint"] == fingerprint)) continue;
                        if (ledger.Count >= PerDevicePerDay) break;
                        string reporter = DeviceReporter(), json = Body(entry, reporter, fingerprint);
                        var claim = Claim();
                        var document = new JavaScriptSerializer().DeserializeObject(json) as Dictionary<string, object>;
                        document["claim_token"] = claim;
                        json = new JavaScriptSerializer().Serialize(document);
                        int retry; string answer;
                        int status = transport.Post(new Uri(endpoint, "api/v1/reports"), claim, json, out retry, out answer);
                        if (status == 429 || status == 503)
                        {
                            Set("RetryAfter", FailureQueue.Stamp(now.AddSeconds(retry > 0 && retry <= 86400 ? retry : 3600)));
                            break;
                        }
                        if (status != 200 && status != 201) break;
                        string id = null;
                        try { var said = new JavaScriptSerializer().DeserializeObject(answer) as Dictionary<string, object>; object value; if (said != null && said.TryGetValue("id", out value)) id = value as string; }
                        catch (ArgumentException) { }
                        ledger.Add(new Dictionary<string, object> { { "fingerprint", fingerprint }, { "at", FailureQueue.Stamp(now) } });
                        Set("Sent", new JavaScriptSerializer().Serialize(ledger));
                        if (id != null && Regex.IsMatch(id, @"\A[A-Za-z0-9_-]{1,64}\z")) Remember(id, claim, (string)entry["code"], now);
                        string sentCode = (string)entry["code"], sentPhase = (string)entry["phase"], sentVersion = (string)entry["version"];
                        queue.Remove(e => (string)e["code"] == sentCode && (string)e["phase"] == sentPhase && (string)e["version"] == sentVersion);
                        sent++;
                    }
                    return sent;
                }
            }
            catch (Exception failure) { if (Environment.GetEnvironmentVariable("WAYPOINT_DEBUG") != null) Console.Error.WriteLine(failure); return 0; }
        }

        // What goes, exactly; shown in the window under "What is sent" too.
        internal static string Body(Dictionary<string, object> entry, string reporter, string fingerprint)
        {
            string code = (string)entry["code"], phase = (string)entry["phase"];
            var faults = entry.ContainsKey("faults") ? ((object[])entry["faults"] ?? new object[0]).Select(f => Scrub(f as string)).ToArray() : new string[0];
            string description = "Waypoint failure: " + code + ", phase " + phase + "\n" +
                "occurrences: " + Convert.ToInt32(entry["count"]) + ", first " + entry["first"] + ", last " + entry["last"] + "\n" +
                "fingerprint: " + fingerprint + "\n" +
                "detail: " + Scrub(entry.ContainsKey("detail") ? entry["detail"] as string : "") + "\n" +
                (faults.Length == 0 ? "" : "faults:\n" + String.Join("\n", faults));
            while (Encoding.UTF8.GetByteCount(description) > Size - 1024) description = description.Substring(0, description.Length * 3 / 4);
            var version = (string)entry["version"];
            return new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                { "project", ProblemReporter.Project }, { "kind", "crash" }, { "submit", true }, { "client_id", Guid.NewGuid().ToString() },
                { "description", description }, { "reporter", new Dictionary<string, object> { { "id", reporter } } },
                { "context", new Dictionary<string, object> {
                    { "app_version", version }, { "app_build", BuildOf() }, { "os_version", Environment.OSVersion.Version.ToString() },
                    { "architecture", System.Runtime.InteropServices.RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant() },
                    { "language", System.Globalization.CultureInfo.InstalledUICulture.TwoLetterISOLanguageName },
                    { "failure_code", code }, { "failure_phase", phase } } } });
        }

        // The last defence: an address, a host name, the computer's or the
        // person's name never leave in a line of the journal.
        internal static string Scrub(string text)
        {
            string kept = text ?? "";
            kept = Regex.Replace(kept, @"\b\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?\b", "[address]");
            kept = Regex.Replace(kept, @"\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}\b", "[name]");
            foreach (string own in new[] { Environment.MachineName, Environment.UserName })
                if (!String.IsNullOrEmpty(own) && own.Length >= 3) kept = Regex.Replace(kept, Regex.Escape(own), "[name]", RegexOptions.IgnoreCase);
            return kept;
        }

        private static string BuildOf()
        {
            var version = typeof(FailureReporter).Assembly.GetName().Version;
            return version == null ? "0" : Math.Max(version.Revision, 0).ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        // Each value read and written through a key opened for that alone.
        private string Get(string name)
        {
            using (var key = Registry.LocalMachine.OpenSubKey(queue.Key)) return key == null ? null : key.GetValue(name) as string;
        }

        private void Set(string name, string value)
        {
            using (var key = Registry.LocalMachine.CreateSubKey(queue.Key)) key.SetValue(name, value, RegistryValueKind.String);
        }

        private static List<Dictionary<string, object>> Ledger(string text, DateTime now)
        {
            var kept = new List<Dictionary<string, object>>();
            try
            {
                foreach (object item in new JavaScriptSerializer().DeserializeObject(text ?? "[]") as object[] ?? new object[0])
                {
                    var entry = item as Dictionary<string, object>;
                    if (entry != null && entry.ContainsKey("at") && entry["at"] is string && now - Parse((string)entry["at"]) < TimeSpan.FromDays(1)) kept.Add(entry);
                }
            }
            catch (ArgumentException) { }
            return kept;
        }

        // A random ID of the device for its automatic reports, made once.
        private string DeviceReporter()
        {
            Guid known;
            string id = Get("ReporterId");
            if (id != null && Guid.TryParse(id, out known)) return id;
            id = Guid.NewGuid().ToString();
            Set("ReporterId", id);
            return id;
        }

        // The window lists automatic reports beside the person's own.
        private void Remember(string id, string claim, string code, DateTime at)
        {
            var list = new List<object>();
            try { list.AddRange(new JavaScriptSerializer().DeserializeObject(Get("Reports") ?? "[]") as object[] ?? new object[0]); }
            catch (ArgumentException) { }
            list.Add(new Dictionary<string, object> { { "id", id }, { "claim", claim }, { "code", code }, { "sent_at", FailureQueue.Stamp(at) } });
            while (list.Count > 50) list.RemoveAt(0);
            Set("Reports", new JavaScriptSerializer().Serialize(list));
        }

        private static string Claim()
        {
            var bytes = new byte[32];
            using (var random = RandomNumberGenerator.Create()) random.GetBytes(bytes);
            return String.Concat(bytes.Select(b => b.ToString("x2")));
        }

        private static DateTime Parse(string stamp)
        {
            return DateTime.Parse(stamp, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal);
        }
    }
}
