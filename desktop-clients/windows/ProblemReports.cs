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
    // A report carries what the person wrote, an optional address for a reply,
    // pictures they pasted and, if they ask, the same state report the window
    // shows. It is sent and forgotten: nothing of it is kept on this computer.
    // Each report has its own random claim token, which the service takes as
    // the proof that the files and the finishing step belong to it.
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

        // Sends a fresh report with the person's text, contact and context, and
        // FILES in their order. Returns the service's report number.
        public string Send(string description, string contact, IDictionary<string, string> context, IList<ReportFile> files)
        {
            var report = ProblemReport.Fresh();
            var create = new Dictionary<string, object> { { "project", Project }, { "client_id", report.ClientId },
                { "claim_token", report.Claim }, { "description", description }, { "context", context } };
            if (!String.IsNullOrEmpty(contact)) create["contact"] = contact;
            // Without files the report is submitted in this one request.
            if (files.Count == 0) create["submit"] = true;
            Dictionary<string, object> answer;
            int status = Call("POST", "api/v1/reports", report.Claim, create, null, null, out answer);
            if (status != 200 && status != 201) throw Fail(status, answer);
            string id = Id(answer);
            if (id == null) throw new ProblemReportException("refused", "The service gave no report number.");
            if (files.Count == 0) return id;
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
            return id;
        }
    }
}
