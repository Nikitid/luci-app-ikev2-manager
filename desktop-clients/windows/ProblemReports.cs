using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace IkeV2Manager.Client
{
    // Problem reports from this computer to the developer's report service.
    //
    // A report carries what the person wrote, an optional address for a reply
    // and, if they ask, the same state report the window shows. Each report has
    // its own random claim token: it opens that report's status and the replies
    // to it and nothing else. The client ID and the claim are kept before the
    // first request, so a send that was cut off is taken up again and returns
    // the same report instead of a second one.
    internal sealed class ProblemReport
    {
        public string ClientId { get; set; }
        public string Claim { get; set; }
        public string Title { get; set; }
        public DateTime SentUtc { get; set; }
        public string ReportId { get; set; }
        public bool Finished { get; set; }

        public static ProblemReport Fresh(string title)
        {
            var bytes = new byte[32];
            using (var random = new RNGCryptoServiceProvider()) random.GetBytes(bytes);
            string first = (title ?? "").Split('\n')[0].Trim();
            if (first.Length > 120) first = first.Substring(0, 120);
            return new ProblemReport
            {
                ClientId = Guid.NewGuid().ToString(),
                Claim = String.Concat(bytes.Select(b => b.ToString("x2"))),
                Title = first,
                SentUtc = DateTime.UtcNow
            };
        }
    }

    internal sealed class ProblemReportState
    {
        public string State;
        public List<string> Replies = new List<string>();
    }

    // One HTTP exchange, so the protocol can be followed without a network.
    internal interface IReportTransport
    {
        int Exchange(string method, Uri url, IDictionary<string, string> headers, byte[] body, out byte[] response);
    }

    internal sealed class WebReportTransport : IReportTransport
    {
        public int Exchange(string method, Uri url, IDictionary<string, string> headers, byte[] body, out byte[] response)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = method;
            request.Timeout = 60000;
            request.ReadWriteTimeout = 60000;
            request.AllowAutoRedirect = false;
            request.Headers["Cache-Control"] = "no-store";
            foreach (var pair in headers)
            {
                if (pair.Key == "Content-Type") request.ContentType = pair.Value;
                else request.Headers[pair.Key] = pair.Value;
            }
            if (body != null)
            {
                request.ContentLength = body.Length;
                using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
            }
            else if (method == "POST" || method == "PATCH") request.ContentLength = 0;
            HttpWebResponse answer;
            try { answer = (HttpWebResponse)request.GetResponse(); }
            catch (WebException error)
            {
                answer = error.Response as HttpWebResponse;
                if (answer == null) throw;
            }
            using (answer)
            using (var stream = answer.GetResponseStream())
            using (var memory = new MemoryStream())
            {
                if (stream != null) stream.CopyTo(memory);
                response = memory.ToArray();
                return (int)answer.StatusCode;
            }
        }
    }

    internal sealed class ProblemReportException : Exception
    {
        // unavailable, busy, unreachable or refused
        public readonly string Kind;
        public ProblemReportException(string kind, string message) : base(message) { Kind = kind; }
    }

    internal sealed class ProblemReporter
    {
        public static readonly Uri DefaultEndpoint = new Uri("https://reports.nikitid.ru/");
        public const string Project = "waypoint";
        private readonly Uri endpoint;
        private readonly IReportTransport transport;
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

        public ProblemReporter() : this(DefaultEndpoint, new WebReportTransport()) { }
        public ProblemReporter(Uri endpoint, IReportTransport transport) { this.endpoint = endpoint; this.transport = transport; }

        private int Call(string method, string path, string claim, object json, byte[] raw, IDictionary<string, string> extra, out Dictionary<string, object> answer)
        {
            var headers = new Dictionary<string, string>();
            if (extra != null) foreach (var pair in extra) headers[pair.Key] = pair.Value;
            headers["Authorization"] = "Bearer " + claim;
            byte[] body = raw;
            if (json != null)
            {
                body = new UTF8Encoding(false).GetBytes(Json.Serialize(json));
                headers["Content-Type"] = "application/json";
            }
            byte[] response;
            int status;
            try { status = transport.Exchange(method, new Uri(endpoint, path), headers, body, out response); }
            catch (Exception) { throw new ProblemReportException("unreachable", "The report service could not be reached."); }
            answer = null;
            try { if (response != null && response.Length > 0) answer = Json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(response)); }
            catch (ArgumentException) { answer = null; }
            return status;
        }

        private static ProblemReportException Fail(int status, Dictionary<string, object> answer)
        {
            object code;
            string text = answer != null && answer.TryGetValue("error", out code) ? code as string ?? "" : "";
            if (status == 404) return new ProblemReportException("unavailable", "The report service does not take Waypoint reports now.");
            if (status == 429 || status == 503) return new ProblemReportException("busy", "The report service is busy.");
            return new ProblemReportException("refused", "Refused (" + status + (text.Length > 0 ? ", " + text : "") + ").");
        }

        private static string Id(Dictionary<string, object> answer)
        {
            object value;
            string id = answer != null && answer.TryGetValue("id", out value) ? value as string : null;
            if (id == null || id.Length == 0 || id.Any(c => !(Char.IsLetterOrDigit(c) && c < 128) && c != '_' && c != '-')) return null;
            return id;
        }

        // Sends REPORT with the person's text, contact and context, and the
        // attachment when given. KEEP is called each time the report learns
        // more, so the caller holds it before the next step.
        public ProblemReport Send(ProblemReport report, string description, string contact, IDictionary<string, string> context,
            byte[] attachment, Action<ProblemReport> keep)
        {
            var create = new Dictionary<string, object> { { "project", Project }, { "client_id", report.ClientId },
                { "claim_token", report.Claim }, { "description", description }, { "context", context } };
            if (!String.IsNullOrEmpty(contact)) create["contact"] = contact;
            // Without a file the report is submitted in this one request.
            if (attachment == null) create["submit"] = true;
            Dictionary<string, object> answer;
            int status = Call("POST", "api/v1/reports", report.Claim, create, null, null, out answer);
            if (status != 200 && status != 201) throw Fail(status, answer);
            string id = Id(answer);
            if (id == null) throw new ProblemReportException("refused", "The service gave no report number.");
            report.ReportId = id;
            keep(report);
            if (attachment != null)
            {
                string sum;
                using (var sha = SHA256.Create()) sum = String.Concat(sha.ComputeHash(attachment).Select(b => b.ToString("x2")));
                status = Call("POST", "api/v1/reports/" + id + "/attachments", report.Claim, new Dictionary<string, object> {
                    { "filename", "waypoint-state.json" }, { "content_type", "application/json" },
                    { "size", attachment.Length }, { "sha256", sum } }, null, null, out answer);
                if (status != 200 && status != 201) throw Fail(status, answer);
                string file = Id(answer);
                if (file == null) throw new ProblemReportException("refused", "The service gave no attachment number.");
                // Created once; a creation that already happened answers 409.
                status = Call("POST", "api/v1/uploads/", report.Claim, null, null, new Dictionary<string, string> {
                    { "Tus-Resumable", "1.0.0" }, { "Upload-Length", attachment.Length.ToString() },
                    { "Upload-Metadata", "attachment_id " + Convert.ToBase64String(Encoding.UTF8.GetBytes(file)) } }, out answer);
                if (status != 201 && status != 409) throw Fail(status, answer);
                status = Call("PATCH", "api/v1/uploads/" + file, report.Claim, null, attachment, new Dictionary<string, string> {
                    { "Tus-Resumable", "1.0.0" }, { "Upload-Offset", "0" }, { "Content-Type", "application/offset+octet-stream" } }, out answer);
                if (status != 204 && status != 409) throw Fail(status, answer);
                status = Call("POST", "api/v1/reports/" + id + "/finalize", report.Claim, new Dictionary<string, object>(), null, null, out answer);
                if (status != 200 && status != 201) throw Fail(status, answer);
            }
            report.Finished = true;
            keep(report);
            return report;
        }

        // What the service says of a sent report and the replies to it.
        public ProblemReportState StateOf(ProblemReport report)
        {
            if (String.IsNullOrEmpty(report.ReportId)) return null;
            Dictionary<string, object> answer;
            try { if (Call("GET", "api/v1/reports/" + report.ReportId, report.Claim, null, null, null, out answer) != 200 || answer == null) return null; }
            catch (ProblemReportException) { return null; }
            var state = new ProblemReportState();
            object value;
            if (answer.TryGetValue("state", out value)) state.State = value as string;
            if (answer.TryGetValue("replies", out value) && value is System.Collections.ArrayList)
                foreach (var reply in (System.Collections.ArrayList)value)
                {
                    var fields = reply as Dictionary<string, object>;
                    object body;
                    if (fields != null && fields.TryGetValue("body", out body) && body is string) state.Replies.Add((string)body);
                }
            return state;
        }
    }

    // The reports this person sent from this computer, kept with the claim
    // that reads them, in their own profile.
    internal sealed class ProblemReportBook
    {
        private readonly string file;
        public ProblemReportBook() : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Waypoint", "reports.json")) { }
        public ProblemReportBook(string file) { this.file = file; }

        public List<ProblemReport> Load()
        {
            try { return new JavaScriptSerializer().Deserialize<List<ProblemReport>>(File.ReadAllText(file, Encoding.UTF8)) ?? new List<ProblemReport>(); }
            catch (Exception) { return new List<ProblemReport>(); }
        }

        public void Keep(ProblemReport report)
        {
            var all = Load().Where(item => item.ClientId != report.ClientId).ToList();
            all.Insert(0, report);
            Directory.CreateDirectory(Path.GetDirectoryName(file));
            string temporary = file + ".new";
            File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(all.Take(20).ToList()), new UTF8Encoding(false));
            if (File.Exists(file)) File.Replace(temporary, file, null); else File.Move(temporary, file);
        }
    }
}
