using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

// A report service that answers as its contract says and keeps every request.
internal sealed class RecordingService : IReportTransport
{
    public readonly List<Tuple<string, string, IDictionary<string, string>, byte[]>> Calls = new List<Tuple<string, string, IDictionary<string, string>, byte[]>>();
    public bool Down;
    public int CreateStatus = 201;

    public int Exchange(string method, Uri url, IDictionary<string, string> headers, byte[] body, out byte[] response)
    {
        if (Down) throw new System.Net.WebException("down");
        Calls.Add(Tuple.Create(method, url.AbsolutePath, headers, body));
        string key = method + " " + url.AbsolutePath, text;
        int status;
        if (key == "POST /api/v1/reports") { status = CreateStatus; text = CreateStatus == 404 ? "{\"error\":\"project_unavailable\"}" : "{\"id\":\"rep_1\",\"state\":\"draft\"}"; }
        else if (key == "POST /api/v1/reports/rep_1/attachments") { status = 201; text = "{\"id\":\"att_1\"}"; }
        else if (key == "POST /api/v1/uploads/") { status = 201; text = ""; }
        else if (key == "PATCH /api/v1/uploads/att_1") { status = 204; text = ""; }
        else if (key == "POST /api/v1/reports/rep_1/finalize") { status = 200; text = "{\"id\":\"rep_1\",\"state\":\"received\"}"; }
        else if (key == "GET /api/v1/reports/rep_1") { status = 200; text = "{\"id\":\"rep_1\",\"state\":\"in_progress\",\"attachments\":[],\"replies\":[" +
            "{\"from\":\"reporter\",\"body\":\"It drops\",\"created_at\":\"2026-10-24T10:00:00Z\"},{\"from\":\"support\",\"body\":\"Which network?\",\"created_at\":\"2026-10-24T11:30:00.123Z\"},{\"from\":\"robot\",\"body\":\"x\"}]}"; }
        else if (key == "POST /api/v1/reports/rep_1/messages") { status = 201; text = ""; }
        else { status = 404; text = "{\"error\":\"not_found\"}"; }
        response = Encoding.UTF8.GetBytes(text);
        return status;
    }

    public Dictionary<string, object> Json(int index)
    {
        return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(Calls[index].Item4));
    }
}

internal static class ProblemReportsTests
{
    private static void Expect(bool condition, string what) { if (!condition) throw new Exception(what); }

    private static int Main()
    {
        try
        {
            var endpoint = new Uri("https://reports.example/");
            var context = new Dictionary<string, string> { { "app_version", "2.3.0" } };

            // Text alone: one request that submits it, with the claim.
            var service = new RecordingService();
            var none = new List<ReportFile>();
            var sent = new ProblemReporter(endpoint, service).Send("Tunnel drops\r\nsince Monday", "question", "me-1", "", context, none);
            Expect(sent.Id == "rep_1" && sent.Kind == "question" && sent.Title == "Tunnel drops" && sent.Seen == 0, "a text report was not sent");
            Expect(service.Calls.Count == 1 && service.Calls[0].Item1 == "POST" && service.Calls[0].Item2 == "/api/v1/reports", "a text report took more than one request");
            var body = service.Json(0);
            Expect((string)body["project"] == "waypoint" && (bool)body["submit"] && !body.ContainsKey("contact"), "the report request is not what the contract asks");
            Expect((string)body["kind"] == "question" && (string)((Dictionary<string, object>)body["reporter"])["id"] == "me-1", "the kind or the reporter was not sent");
            Expect(sent.Claim == (string)body["claim_token"], "the journal would keep another claim");
            string claim = (string)body["claim_token"];
            Expect(claim.Length == 64 && claim.All(c => "0123456789abcdef".IndexOf(c) >= 0), "the claim is not 32 random bytes in hex");
            Expect(service.Calls[0].Item3["Authorization"] == "Bearer " + claim, "the claim was not used");

            // Each file: register, upload; the report is finalized last.
            service = new RecordingService();
            var picture = new ReportFile("picture-1.png", "image/png", new byte[] { 0x89, 0x50, 0x4e, 0x47 });
            var state = new ReportFile("waypoint-state.json", "application/json", Encoding.UTF8.GetBytes("{\"state\":\"blocked\"}"));
            new ProblemReporter(endpoint, service).Send("x", "bug", "me-1", "me@example.com", context, new List<ReportFile> { picture, state });
            string upload = "POST /api/v1/reports/rep_1/attachments|POST /api/v1/uploads/|PATCH /api/v1/uploads/att_1|";
            Expect(String.Join("|", service.Calls.Select(c => c.Item1 + " " + c.Item2)) ==
                "POST /api/v1/reports|" + upload + upload + "POST /api/v1/reports/rep_1/finalize",
                "the files did not follow the upload contract: " + String.Join("|", service.Calls.Select(c => c.Item1 + " " + c.Item2)));
            Expect(!service.Json(0).ContainsKey("submit") && (string)service.Json(0)["contact"] == "me@example.com", "a report with files was submitted before them");
            Expect((string)service.Json(1)["filename"] == "picture-1.png" && (string)service.Json(1)["content_type"] == "image/png", "the picture was registered wrongly");
            Expect((int)service.Json(1)["size"] == picture.Data.Length, "the picture was registered with another size");
            Expect(service.Calls[2].Item3["Upload-Metadata"] == "attachment_id " + Convert.ToBase64String(Encoding.UTF8.GetBytes("att_1")), "the upload is not for the registered file");
            Expect(service.Calls[3].Item4.SequenceEqual(picture.Data) && service.Calls[6].Item4.SequenceEqual(state.Data), "another file was uploaded");
            Expect(service.Calls.Select(c => c.Item3["Authorization"]).Distinct().Count() == 1, "the requests did not carry one claim");

            // Failures are told apart.
            service = new RecordingService { Down = true };
            try { new ProblemReporter(endpoint, service).Send("x", "bug", "me-1", "", context, none); Expect(false, "an unreachable service was reported as sent"); }
            catch (ProblemReportException error) { Expect(error.Kind == "unreachable", "unreachable was " + error.Kind); }
            service = new RecordingService { CreateStatus = 404 };
            try { new ProblemReporter(endpoint, service).Send("x", "bug", "me-1", "", context, none); Expect(false, "a paused project was reported as sent"); }
            catch (ProblemReportException error) { Expect(error.Kind == "unavailable", "a paused project was " + error.Kind); }

            // The conversation is read and answered with the report's claim.
            service = new RecordingService();
            var reporter = new ProblemReporter(endpoint, service);
            var report = new SentReport { Id = "rep_1", Claim = new string('a', 64), Kind = "bug", Title = "x", SentAt = DateTime.UtcNow };
            var conversation = reporter.Conversation(report);
            Expect(conversation.State == "in_progress" && conversation.StateLabel == "в работе", "the state was read wrongly");
            Expect(String.Join(",", conversation.Replies.Select(r => r.From)) == "reporter,support" && conversation.FromSupport == 1, "the replies were read wrongly");
            Expect(conversation.Replies[1].Body == "Which network?" && conversation.Replies[1].CreatedAt.HasValue, "a reply lost its text or time");
            Expect(service.Calls[0].Item1 == "GET" && service.Calls[0].Item3["Authorization"] == "Bearer " + report.Claim, "the conversation was not asked with the claim");
            reporter.Reply(report, "  Home Wi-Fi  ");
            Expect(service.Calls[1].Item1 == "POST" && service.Calls[1].Item2 == "/api/v1/reports/rep_1/messages" &&
                service.Json(1).Count == 1 && (string)service.Json(1)["body"] == "Home Wi-Fi", "the answer was not sent as the contract asks");
            try { reporter.Reply(report, "   "); Expect(false, "an empty answer was sent"); }
            catch (ProblemReportException error) { Expect(error.Kind == "refused", "an empty answer was " + error.Kind); }
            try { reporter.Conversation(new SentReport { Id = "old", Claim = report.Claim }); Expect(false, "an unknown report was read"); }
            catch (ProblemReportException error) { Expect(error.Kind == "gone", "an unknown report was " + error.Kind); }

            // The reporter is the same every time.
            string key = @"Software\Waypoint-Test-" + Guid.NewGuid().ToString("N");
            try
            {
                string first = ReporterIdentity.Id(key);
                Guid parsed;
                Expect(Guid.TryParse(first, out parsed) && ReporterIdentity.Id(key) == first, "the reporter changed between reports");
            }
            finally { Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(key, false); }

            // The journal: newest first, at most fifty, readable by this user only.
            string folder = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "waypoint-journal-" + Guid.NewGuid().ToString("N"));
            try
            {
                string file = System.IO.Path.Combine(folder, "reports.dat");
                var journal = new ReportJournal(file);
                Expect(journal.Load().Count == 0, "an empty journal listed reports");
                for (int i = 0; i < 55; i++) journal.Add(new SentReport { Id = "r" + i, Claim = "c" + i, Kind = "feedback", Title = "t", SentAt = new DateTime(2026, 1, 1, 0, 0, i, DateTimeKind.Utc) });
                var kept = journal.Load();
                Expect(kept.Count == ReportJournal.Limit && kept[0].Id == "r54" && kept[0].Claim == "c54" && kept[0].SentAt.Second == 54, "the journal kept the wrong reports");
                journal.MarkSeen("r54", 2);
                journal.Remove("r53");
                kept = journal.Load();
                Expect(kept[0].Seen == 2 && !kept.Any(r => r.Id == "r53"), "seen or removed reports were not kept");
                Expect(!Encoding.UTF8.GetString(System.IO.File.ReadAllBytes(file)).Contains("c54"), "the claims are stored in the clear");
            }
            finally { if (System.IO.Directory.Exists(folder)) System.IO.Directory.Delete(folder, true); }

            Console.WriteLine("problem reports tests OK");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("problem reports: " + error.Message);
            return 1;
        }
    }
}
