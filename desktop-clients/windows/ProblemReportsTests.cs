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
            string sent = new ProblemReporter(endpoint, service).Send("Tunnel drops", "", context, none);
            Expect(sent == "rep_1", "a text report was not sent");
            Expect(service.Calls.Count == 1 && service.Calls[0].Item1 == "POST" && service.Calls[0].Item2 == "/api/v1/reports", "a text report took more than one request");
            var body = service.Json(0);
            Expect((string)body["project"] == "waypoint" && (bool)body["submit"] && !body.ContainsKey("contact"), "the report request is not what the contract asks");
            string claim = (string)body["claim_token"];
            Expect(claim.Length == 64 && claim.All(c => "0123456789abcdef".IndexOf(c) >= 0), "the claim is not 32 random bytes in hex");
            Expect(service.Calls[0].Item3["Authorization"] == "Bearer " + claim, "the claim was not used");

            // Each file: register, upload; the report is finalized last.
            service = new RecordingService();
            var picture = new ReportFile("picture-1.png", "image/png", new byte[] { 0x89, 0x50, 0x4e, 0x47 });
            var state = new ReportFile("waypoint-state.json", "application/json", Encoding.UTF8.GetBytes("{\"state\":\"blocked\"}"));
            new ProblemReporter(endpoint, service).Send("x", "me@example.com", context, new List<ReportFile> { picture, state });
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
            try { new ProblemReporter(endpoint, service).Send("x", "", context, none); Expect(false, "an unreachable service was reported as sent"); }
            catch (ProblemReportException error) { Expect(error.Kind == "unreachable", "unreachable was " + error.Kind); }
            service = new RecordingService { CreateStatus = 404 };
            try { new ProblemReporter(endpoint, service).Send("x", "", context, none); Expect(false, "a paused project was reported as sent"); }
            catch (ProblemReportException error) { Expect(error.Kind == "unavailable", "a paused project was " + error.Kind); }

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
