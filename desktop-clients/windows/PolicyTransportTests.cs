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
            // A report is owed only to a clear request; anything else is "no".
            if (!PolicyTransportClient.ParseReportWanted("{\"version\":1,\"wanted\":true}")) throw new Exception("Report request not understood");
            foreach (string answer in new[] { "{\"version\":1,\"wanted\":false}", "{\"version\":2,\"wanted\":true}", "{\"wanted\":true}", "{\"version\":1,\"wanted\":\"true\"}", "[]", "not json" })
                if (PolicyTransportClient.ParseReportWanted(answer)) throw new Exception("Report sent without a clear request: " + answer);
            if (PolicyTransportClient.SendReport(endpoint, token, "") || PolicyTransportClient.SendReport(endpoint, token, new string('a', PolicyTransportClient.ReportLimit + 1)))
                throw new Exception("An empty or oversized report was attempted");
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
            string ready = "{\"version\":1,\"state\":\"ready\",\"id\":\"alice-pc\",\"revision\":4,\"policy_sha256\":\"" + new string('a', 64) +
                "\",\"address\":\"10.77.0.2\",\"generation\":3,\"expires_at\":1790000000}";
            var readiness = DeviceReadiness.Parse(ready);
            if (readiness.Id != "alice-pc" || readiness.Address != "10.77.0.2" || readiness.Revision != 4) throw new Exception("Readiness was not read");
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
            string offered = "{\"version\":1,\"id\":\"alice-pc\",\"revision\":4,\"selected\":[{\"id\":\"api\",\"domains\":3},{\"id\":\"mail\",\"domains\":2}],\"available\":[{\"id\":\"wiki\",\"domains\":9}]}";
            var names = DeviceServices.Parse(offered, "alice-pc");
            if (names.Selected.Length != 2 || names.Available.Length != 1 || names.Available[0] != "wiki" || names.Domains != 5) throw new Exception("Service names were not read");
            if (names.NamesHttps || !DeviceServices.Parse(offered.Replace("\"revision\":4", "\"revision\":4,\"names_https\":true"), "alice-pc").NamesHttps)
                throw new Exception("Names over HTTPS were not read as offered");
            Reject(() => DeviceServices.Parse(offered.Replace("\"revision\":4", "\"revision\":4,\"names_https\":\"yes\""), "alice-pc"), "services_response_invalid");
            Reject(() => DeviceServices.Parse(offered, "other-pc"), "services_response_invalid");
            // An offer: each entry read strictly, its name shown as plain text.
            string entry = "{\"id\":\"chat\",\"label\":\"Telegram\",\"required\":false,\"on\":true,\"closed\":false,\"choose_closed\":true,\"domains\":3,\"networks\":1,\"resources\":[\"host-4\"],\"cidrs\":[\"149.154.160.0/20\"]}";
            Func<string, string> withEntry = e => offered.Replace("\"revision\":4", "\"revision\":4,\"entries\":[" + e + "]");
            var chosen = DeviceServices.Parse(withEntry(entry), "alice-pc").Entries;
            if (chosen == null || chosen.Length != 1 || chosen[0].Label != "Telegram" || !chosen[0].On || chosen[0].Closed || !chosen[0].ChooseClosed ||
                chosen[0].Resources[0] != "host-4" || chosen[0].Cidrs[0] != "149.154.160.0/20")
                throw new Exception("The offer was not read as given");
            if (names.Entries != null) throw new Exception("A router without offers was read as giving one");
            foreach (string bad in new[] { entry.Replace("Telegram", "Tele\\ngram"), entry.Replace("\"required\":false,\"on\":true", "\"required\":true,\"on\":false"),
                entry.Replace("149.154.160.0/20", "127.0.0.0/8"), entry.Replace("host-4", "../4"), entry.Replace("\"cidrs\"", "\"extra\":1,\"cidrs\"") })
                Reject(() => DeviceServices.Parse(withEntry(bad), "alice-pc"), "services_response_invalid");
            Reject(() => DeviceServices.Parse(offered.Replace("\"mail\"", "\"api\""), "alice-pc"), "services_response_invalid");
            Reject(() => DeviceServices.Parse(offered.Replace("\"wiki\"", "\"../wiki\""), "alice-pc"), "services_response_invalid");
            Reject(() => DeviceServices.Parse(offered.Replace("\"domains\":9", "\"domains\":9,\"address\":\"10.0.0.1\""), "alice-pc"), "services_response_invalid");
            // The person's own addresses: read strictly where the router allows them.
            string own = "{\"limit\":5,\"ports\":[80,443],\"domains\":[\"home.example.org\"],\"networks\":[\"203.0.113.0/24\"]}";
            Func<string, string> withOwn = o => offered.Replace("\"revision\":4", "\"revision\":4,\"own\":" + o);
            var kept = DeviceServices.Parse(withOwn(own), "alice-pc").Own;
            if (kept == null || kept.Limit != 5 || kept.Ports.Length != 2 || kept.Domains[0] != "home.example.org" || kept.Networks[0] != "203.0.113.0/24")
                throw new Exception("The own addresses were not read as given");
            if (names.Own != null) throw new Exception("A router that allows none was read as allowing own addresses");
            foreach (string bad in new[] { own.Replace("\"limit\":5", "\"limit\":99"), own.Replace("[80,443]", "[]"), own.Replace("home.example.org", "Home Example"),
                own.Replace("203.0.113.0/24", "203.0.113.1/24"), own.Replace("\"networks\"", "\"extra\":1,\"networks\"") })
                Reject(() => DeviceServices.Parse(withOwn(bad), "alice-pc"), "services_response_invalid");
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
