using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using IkeV2Manager.Client;

internal static class PolicyTransportTests
{
    private static int Main(string[] args)
    {
        try
        {
            const string token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
            foreach (string url in new[] { "http://vpn.example.com/client/v1/policy", "https://user@vpn.example.com/client/v1/policy",
                "https://vpn.example.com/client/v1/policy?token=secret", "https://vpn.example.com/client/v1/policy#secret",
                "https://vpn.example.com/ubus", "https://127.0.0.1/client/v1/policy" })
                Reject(() => PolicyTransportClient.ValidateEndpoint(new Uri(url), token));
            var endpoint = new Uri("https://vpn.example.com:8443/client/v1/policy");
            PolicyTransportClient.ValidateEndpoint(endpoint, token);
            Reject(() => PolicyTransportClient.ValidateEndpoint(endpoint, token + "\n"));
            Reject(() => PolicyTransportClient.ValidateEndpoint(endpoint, "short"));
            var serializer = new JavaScriptSerializer();
            var fixtures = (object[])serializer.DeserializeObject(File.ReadAllText(args[0]));
            string json = serializer.Serialize(((Dictionary<string, object>)fixtures[0])["policy"]);
            byte[] bytes = Encoding.UTF8.GetBytes(json);
            if (PolicyTransportClient.Decode(new MemoryStream(bytes), "application/json; charset=utf-8", bytes.Length).Revision != 1)
                throw new Exception("Valid policy response not decoded");
            if (PolicyTransportClient.Decode(new MemoryStream(bytes), "application/json", -1).Revision != 1)
                throw new Exception("Bounded unknown-length response not decoded");
            Reject(() => PolicyTransportClient.Decode(new MemoryStream(bytes), "text/html", bytes.Length));
            Reject(() => PolicyTransportClient.Decode(new MemoryStream(bytes), "application/jsonx", bytes.Length));
            Reject(() => PolicyTransportClient.Decode(new MemoryStream(bytes), "application/json", bytes.Length + 1));
            Reject(() => PolicyTransportClient.Decode(new MemoryStream(new byte[1048577]), "application/json", -1), "policy_response_too_large");
            Reject(() => PolicyTransportClient.Decode(new MemoryStream(new byte[] { 255 }), "application/json", 1));
            Reject(() => PolicyTransportClient.Decode(new MemoryStream(Encoding.UTF8.GetBytes("{\"secret\":\"do-not-print\"}")), "application/json", -1));
            string ready = "{\"version\":1,\"state\":\"ready\",\"id\":\"office-pc\",\"revision\":4,\"policy_sha256\":\"" + new string('a', 64) +
                "\",\"address\":\"10.77.0.2\",\"generation\":3,\"expires_at\":1790000000}";
            var readiness = DeviceReadiness.Parse(ready);
            if (readiness.Id != "office-pc" || readiness.Address != "10.77.0.2" || readiness.Revision != 4) throw new Exception("Readiness was not read");
            foreach (string broken in new[] {
                ready.Replace("\"ready\"", "\"pending\""), ready.Replace("\"version\":1", "\"version\":2"),
                ready.Replace("\"revision\":4", "\"revision\":0"), ready.Replace("10.77.0.2", "10.77.0.256"),
                ready.Replace("\"generation\":3", "\"generation\":\"3\""), ready.Replace(",\"expires_at\":1790000000", ""),
                ready.Replace("}", ",\"extra\":1}"), ready.Replace(new string('a', 64), new string('a', 63)), "[]", "{" })
                Reject(() => DeviceReadiness.Parse(broken), "path_response_invalid");
            byte[] body = Encoding.UTF8.GetBytes(ready);
            if (PolicyTransportClient.ReadBody(new MemoryStream(body), "application/json", body.Length, 4096, "path_response_invalid") != ready)
                throw new Exception("Readiness body was not read");
            Reject(() => PolicyTransportClient.ReadBody(new MemoryStream(new byte[4097]), "application/json", -1, 4096, "path_response_invalid"), "path_response_invalid");
            Reject(() => PolicyTransportClient.ReadBody(new MemoryStream(body), "text/plain", body.Length, 4096, "path_response_invalid"), "path_response_invalid");
            string offered = "{\"version\":1,\"id\":\"office-pc\",\"revision\":4,\"selected\":[{\"id\":\"api\",\"domains\":3},{\"id\":\"mail\",\"domains\":2}],\"available\":[{\"id\":\"wiki\",\"domains\":9}]}";
            var names = DeviceServices.Parse(offered, "office-pc");
            if (names.Selected.Length != 2 || names.Available.Length != 1 || names.Available[0] != "wiki" || names.Domains != 5) throw new Exception("Service names were not read");
            Reject(() => DeviceServices.Parse(offered, "other-pc"), "services_response_invalid");
            Reject(() => DeviceServices.Parse(offered.Replace("\"mail\"", "\"api\""), "office-pc"), "services_response_invalid");
            Reject(() => DeviceServices.Parse(offered.Replace("\"wiki\"", "\"../wiki\""), "office-pc"), "services_response_invalid");
            Reject(() => DeviceServices.Parse(offered.Replace("\"domains\":9", "\"domains\":9,\"address\":\"10.0.0.1\""), "office-pc"), "services_response_invalid");
            if (PolicyTransportClient.ParseRelease("{\"version\":1,\"release\":\"2.3.0\"}") != "2.3.0") throw new Exception("Release was not read");
            Reject(() => PolicyTransportClient.ParseRelease("{\"version\":1,\"release\":\"2.3.0\",\"url\":\"https://example.com\"}"), "release_response_invalid");
            Reject(() => PolicyTransportClient.ParseRelease("{\"version\":1,\"release\":\"../2.3\"}"), "release_response_invalid");
            var about = PolicyTransportClient.Describe();
            if (!about.ContainsKey("X-Client-Host") || !Regex.IsMatch(about["X-Client-System"], @"\AWindows [0-9]+\.[0-9]+\.[0-9]+\z") ||
                !Regex.IsMatch(about["X-Client-Version"], @"\A[0-9]+\.[0-9]+\.[0-9]+\z")) throw new Exception("The computer was not described");
            Console.WriteLine("Policy transport checks passed: endpoint restrictions, bounded body, UTF-8, schema, readiness and safe errors");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }

    private static void Reject(Action action, string code = null)
    {
        try { action(); }
        catch (ArgumentException) { return; }
        catch (PolicyFetchException error)
        {
            if (code != null && error.Code != code) throw new Exception("Unexpected transport refusal reason: " + error.Code);
            if (error.Message.Contains("do-not-print")) throw new Exception("Response content escaped into an error");
            return;
        }
        throw new Exception("Unsafe policy transport input accepted");
    }
}
