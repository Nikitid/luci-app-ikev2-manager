using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace IkeV2Manager.Client
{
    // Reports from this computer to the developer's report service.
    //
    // A report carries its kind, what the person wrote, an optional address
    // for a reply, pictures they pasted and, if they ask, the same state
    // report the window shows. Each report has its own random claim token,
    // which the service takes as the proof that the files, the finishing step
    // and the conversation belong to it; the journal keeps it so the person
    // can read support's answers and reply. A random reporter ID, made once
    // for this user, tells the service that reports come from the same person.
    internal sealed class ProblemReport
    {
        public string ClientId { get; set; }
        public string Claim { get; set; }

        public static ProblemReport Fresh()
        {
            var bytes = new byte[32];
            using (var random = new RNGCryptoServiceProvider()) random.GetBytes(bytes);
            return new ProblemReport { ClientId = Guid.NewGuid().ToString(), Claim = String.Concat(bytes.Select(b => b.ToString("x2"))) };
        }
    }

    // What a report is about, as the person picks it: the service's name and
    // the window's word for it.
    public static class ReportKinds
    {
        public static readonly string[][] All = {
            new[] { "bug", "Проблема" }, new[] { "feature", "Идея" }, new[] { "question", "Вопрос" }, new[] { "feedback", "Отзыв" } };

        public static string Label(string kind)
        {
            foreach (var pair in All) if (pair[0] == kind) return pair[1];
            // Sent by the service on its own; never a kind the person picks.
            return kind == "crash" ? "Сбой · отправлен автоматически" : "Обращение";
        }
    }

    // The reporter ID of this user: random, made once, kept in the user's own
    // settings. Only a keyed hash of it is stored by the service.
    public static class ReporterIdentity
    {
        public static string Id(string key = @"Software\Waypoint")
        {
            using (var settings = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(key))
            {
                Guid known;
                string id = settings.GetValue("ReporterId") as string;
                if (id != null && Guid.TryParse(id, out known)) return id;
                id = Guid.NewGuid().ToString();
                settings.SetValue("ReporterId", id);
                return id;
            }
        }
    }

    // A report sent from here, as the journal keeps it: enough to show it in
    // a list and to read and continue its conversation.
    public sealed class SentReport
    {
        public string Id { get; set; }
        public string Claim { get; set; }
        public string Kind { get; set; }
        // The first line of what the person wrote, at most 80 characters.
        public string Title { get; set; }
        public DateTime SentAt { get; set; }
        // How many of support's replies the person has seen.
        public int Seen { get; set; }

        internal static string TitleOf(string text)
        {
            string line = (text ?? "").Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            return line.Length > 80 ? line.Substring(0, 79) + "\u2026" : line;
        }
    }

    // One message of a report's conversation.
    public sealed class ReportReply
    {
        // "support" or "reporter".
        public string From { get; set; }
        public string Body { get; set; }
        public DateTime? CreatedAt { get; set; }
    }

    // Where a report stands and what was said about it.
    public sealed class ReportConversation
    {
        // received, in_progress, resolved or closed.
        public string State { get; set; }
        public List<ReportReply> Replies { get; set; }
        public int FromSupport { get { return Replies.Count(r => r.From == "support"); } }

        public string StateLabel
        {
            get
            {
                switch (State)
                {
                    case "received": return "получено";
                    case "in_progress": return "в работе";
                    case "resolved": return "решено";
                    case "closed": return "закрыто";
                    default: return "отправляется";
                }
            }
        }
    }

    // The reports sent from here, newest first, at most fifty, in a file
    // encrypted for this user alone: the claims in it open the conversations.
    public sealed class ReportJournal
    {
        public const int Limit = 50;
        private readonly string file;

        public ReportJournal() : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Waypoint", "reports.dat")) { }
        public ReportJournal(string file) { this.file = file; }

        public List<SentReport> Load()
        {
            try
            {
                if (!File.Exists(file)) return new List<SentReport>();
                byte[] plain = ProtectedData.Unprotect(File.ReadAllBytes(file), null, DataProtectionScope.CurrentUser);
                var items = new JavaScriptSerializer { MaxJsonLength = 1048576 }.DeserializeObject(Encoding.UTF8.GetString(plain)) as object[];
                var reports = new List<SentReport>();
                foreach (var item in items ?? new object[0])
                {
                    var data = item as Dictionary<string, object>;
                    if (data == null) continue;
                    object id, claim, kind, title, sent, seen;
                    if (!data.TryGetValue("id", out id) || !(id is string) || !data.TryGetValue("claim", out claim) || !(claim is string)) continue;
                    data.TryGetValue("kind", out kind); data.TryGetValue("title", out title); data.TryGetValue("sent_at", out sent); data.TryGetValue("seen", out seen);
                    DateTime at;
                    reports.Add(new SentReport { Id = (string)id, Claim = (string)claim, Kind = kind as string ?? "bug", Title = title as string ?? "",
                        SentAt = DateTime.TryParse(sent as string, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out at) ? at : DateTime.MinValue,
                        Seen = seen is int ? (int)seen : 0 });
                }
                return reports;
            }
            catch (Exception) { return new List<SentReport>(); }
        }

        public void Save(IEnumerable<SentReport> reports)
        {
            var items = reports.Take(Limit).Select(r => new Dictionary<string, object> { { "id", r.Id }, { "claim", r.Claim }, { "kind", r.Kind },
                { "title", r.Title }, { "sent_at", r.SentAt.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture) }, { "seen", r.Seen } }).ToArray();
            byte[] plain = new UTF8Encoding(false).GetBytes(new JavaScriptSerializer { MaxJsonLength = 1048576 }.Serialize(items));
            Directory.CreateDirectory(Path.GetDirectoryName(file));
            string temporary = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllBytes(temporary, ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser));
            if (File.Exists(file)) File.Replace(temporary, file, null); else File.Move(temporary, file);
        }

        public void Add(SentReport report) { Save(new[] { report }.Concat(Load().Where(r => r.Id != report.Id))); }

        // Notes that the person has seen SEEN of support's replies to ID.
        public void MarkSeen(string id, int seen)
        {
            var reports = Load();
            var report = reports.FirstOrDefault(r => r.Id == id);
            if (report == null || report.Seen == seen) return;
            report.Seen = seen;
            Save(reports);
        }

        public void Remove(string id) { Save(Load().Where(r => r.Id != id)); }
    }

    // A file sent with a report.
    internal sealed class ReportFile
    {
        public string Name;
        public string ContentType;
        public byte[] Data;
        public ReportFile(string name, string contentType, byte[] data) { Name = name; ContentType = contentType; Data = data; }
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
        // unavailable, busy, unreachable, refused, or gone: the service no
        // longer knows the report
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

        // Sends a fresh report of KIND with the person's text, contact and
        // context, and FILES in their order, from REPORTER. Returns what the
        // journal keeps of it.
        public SentReport Send(string description, string kind, string reporter, string contact, IDictionary<string, string> context, IList<ReportFile> files)
        {
            var report = ProblemReport.Fresh();
            var create = new Dictionary<string, object> { { "project", Project }, { "client_id", report.ClientId },
                { "claim_token", report.Claim }, { "description", description }, { "kind", kind ?? "bug" },
                { "reporter", new Dictionary<string, object> { { "id", reporter } } }, { "context", context } };
            if (!String.IsNullOrEmpty(contact)) create["contact"] = contact;
            // Without files the report is submitted in this one request.
            if (files.Count == 0) create["submit"] = true;
            Dictionary<string, object> answer;
            int status = Call("POST", "api/v1/reports", report.Claim, create, null, null, out answer);
            if (status != 200 && status != 201) throw Fail(status, answer);
            string id = Id(answer);
            if (id == null) throw new ProblemReportException("refused", "The service gave no report number.");
            var sent = new SentReport { Id = id, Claim = report.Claim, Kind = kind ?? "bug", Title = SentReport.TitleOf(description), SentAt = DateTime.UtcNow };
            if (files.Count == 0) return sent;
            foreach (var file in files)
            {
                string sum;
                using (var sha = SHA256.Create()) sum = String.Concat(sha.ComputeHash(file.Data).Select(b => b.ToString("x2")));
                status = Call("POST", "api/v1/reports/" + id + "/attachments", report.Claim, new Dictionary<string, object> {
                    { "filename", file.Name }, { "content_type", file.ContentType },
                    { "size", file.Data.Length }, { "sha256", sum } }, null, null, out answer);
                if (status != 200 && status != 201) throw Fail(status, answer);
                string attachment = Id(answer);
                if (attachment == null) throw new ProblemReportException("refused", "The service gave no attachment number.");
                status = Call("POST", "api/v1/uploads/", report.Claim, null, null, new Dictionary<string, string> {
                    { "Tus-Resumable", "1.0.0" }, { "Upload-Length", file.Data.Length.ToString() },
                    { "Upload-Metadata", "attachment_id " + Convert.ToBase64String(Encoding.UTF8.GetBytes(attachment)) } }, out answer);
                if (status != 201) throw Fail(status, answer);
                status = Call("PATCH", "api/v1/uploads/" + attachment, report.Claim, null, file.Data, new Dictionary<string, string> {
                    { "Tus-Resumable", "1.0.0" }, { "Upload-Offset", "0" }, { "Content-Type", "application/offset+octet-stream" } }, out answer);
                if (status != 204) throw Fail(status, answer);
            }
            status = Call("POST", "api/v1/reports/" + id + "/finalize", report.Claim, new Dictionary<string, object>(), null, null, out answer);
            if (status != 200 && status != 201) throw Fail(status, answer);
            return sent;
        }

        // Where REPORT stands and the conversation about it.
        public ReportConversation Conversation(SentReport report)
        {
            Dictionary<string, object> answer;
            int status = Call("GET", "api/v1/reports/" + report.Id, report.Claim, null, null, null, out answer);
            if (status == 404) throw new ProblemReportException("gone", "The report is no longer known.");
            if (status != 200 || answer == null) throw Fail(status, answer);
            var replies = new List<ReportReply>();
            object list;
            foreach (var item in answer.TryGetValue("replies", out list) ? (list as System.Collections.IEnumerable ?? new object[0]) : new object[0])
            {
                var data = item as Dictionary<string, object>;
                object from, body, created;
                if (data == null || !data.TryGetValue("from", out from) || (from as string != "support" && from as string != "reporter") ||
                    !data.TryGetValue("body", out body) || String.IsNullOrEmpty(body as string)) continue;
                DateTime at;
                data.TryGetValue("created_at", out created);
                replies.Add(new ReportReply { From = (string)from, Body = (string)body,
                    CreatedAt = DateTime.TryParse(created as string, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out at) ? at : (DateTime?)null });
            }
            object state;
            return new ReportConversation { State = answer.TryGetValue("state", out state) ? state as string ?? "" : "", Replies = replies };
        }

        // The person's answer to support on REPORT; it reopens a resolved or
        // closed report.
        public void Reply(SentReport report, string body)
        {
            string text = (body ?? "").Trim();
            if (text.Length == 0 || text.Length > 5000) throw new ProblemReportException("refused", "Refused (400, invalid_body).");
            Dictionary<string, object> answer;
            int status = Call("POST", "api/v1/reports/" + report.Id + "/messages", report.Claim, new Dictionary<string, object> { { "body", text } }, null, null, out answer);
            if (status == 404) throw new ProblemReportException("gone", "The report is no longer known.");
            if (status != 200 && status != 201) throw Fail(status, answer);
        }
    }
}
