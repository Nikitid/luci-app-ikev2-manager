using System;
using System.Collections.Generic;
using System.IO;
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
        else if (key == "GET /api/v1/reports/rep_1") { status = 200; text = "{\"id\":\"rep_1\",\"state\":\"in_progress\",\"replies\":[{\"body\":\"Thanks, looking.\",\"created_at\":\"2026-10-16T10:00:00Z\"}]}"; }
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
            var report = ProblemReport.Fresh("Tunnel drops\nmore text");
            Expect(report.Claim.Length == 64 && report.Claim.All(c => "0123456789abcdef".IndexOf(c) >= 0), "the claim is not 32 random bytes in hex");
            Expect(report.Title == "Tunnel drops", "the title is not the first line");
            var sent = new ProblemReporter(endpoint, service).Send(report, "Tunnel drops", "", context, null, r => { });
            Expect(sent.ReportId == "rep_1" && sent.Finished, "a text report was not sent");
            Expect(service.Calls.Count == 1 && service.Calls[0].Item1 == "POST" && service.Calls[0].Item2 == "/api/v1/reports", "a text report took more than one request");
            var body = service.Json(0);
            Expect((string)body["project"] == "waypoint" && (bool)body["submit"] && !body.ContainsKey("contact"), "the report request is not what the contract asks");
            Expect((string)body["claim_token"] == report.Claim && service.Calls[0].Item3["Authorization"] == "Bearer " + report.Claim, "the claim was not used");

            // With the state report: create, register, upload, finalize.
            service = new RecordingService();
            var file = Encoding.UTF8.GetBytes("{\"state\":\"blocked\"}");
            var kept = new List<ProblemReport>();
            new ProblemReporter(endpoint, service).Send(ProblemReport.Fresh("x"), "x", "me@example.com", context, file,
                r => kept.Add(new ProblemReport { ReportId = r.ReportId, Finished = r.Finished }));
            Expect(String.Join("|", service.Calls.Select(c => c.Item1 + " " + c.Item2)) ==
                "POST /api/v1/reports|POST /api/v1/reports/rep_1/attachments|POST /api/v1/uploads/|PATCH /api/v1/uploads/att_1|POST /api/v1/reports/rep_1/finalize",
                "the file did not follow the upload contract: " + String.Join("|", service.Calls.Select(c => c.Item1 + " " + c.Item2)));
            Expect(!service.Json(0).ContainsKey("submit") && (string)service.Json(0)["contact"] == "me@example.com", "a report with a file was submitted before it");
            Expect((int)service.Json(1)["size"] == file.Length, "the file was registered with another size");
            Expect(service.Calls[2].Item3["Upload-Metadata"] == "attachment_id " + Convert.ToBase64String(Encoding.UTF8.GetBytes("att_1")), "the upload is not for the registered file");
            Expect(service.Calls[3].Item4.SequenceEqual(file), "another file was uploaded");
            Expect(kept.Count == 2 && kept[0].ReportId == "rep_1" && !kept[0].Finished && kept[1].Finished, "the report number was not handed out to keep before the file");

            // Failures are told apart.
            service = new RecordingService { Down = true };
            try { new ProblemReporter(endpoint, service).Send(ProblemReport.Fresh("x"), "x", "", context, null, r => { }); Expect(false, "an unreachable service was reported as sent"); }
            catch (ProblemReportException error) { Expect(error.Kind == "unreachable", "unreachable was " + error.Kind); }
            service = new RecordingService { CreateStatus = 404 };
            try { new ProblemReporter(endpoint, service).Send(ProblemReport.Fresh("x"), "x", "", context, null, r => { }); Expect(false, "a paused project was reported as sent"); }
            catch (ProblemReportException error) { Expect(error.Kind == "unavailable", "a paused project was " + error.Kind); }

            // A sent report is read with its claim.
            service = new RecordingService();
            var read = ProblemReport.Fresh("x"); read.ReportId = "rep_1";
            var state = new ProblemReporter(endpoint, service).StateOf(read);
            Expect(state != null && state.State == "in_progress" && state.Replies.SequenceEqual(new[] { "Thanks, looking." }), "the replies were not read");
            Expect(service.Calls[0].Item3["Authorization"] == "Bearer " + read.Claim, "the state was not asked with the claim");

            // The book keeps one entry per report, the newest first.
            string dir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
            var book = new ProblemReportBook(Path.Combine(dir, "reports.json"));
            var first = ProblemReport.Fresh("first");
            book.Keep(first);
            first.ReportId = "rep_1";
            book.Keep(first);
            var loaded = book.Load();
            Expect(loaded.Count == 1 && loaded[0].ReportId == "rep_1" && loaded[0].Claim == first.Claim, "the book did not keep the report once");
            Directory.Delete(dir, true);

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
