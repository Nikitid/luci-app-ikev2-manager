using System;
using System.IO;
using System.Text;
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
            Console.WriteLine("Policy transport checks passed: endpoint restrictions, bounded body, UTF-8, schema and safe errors");
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
