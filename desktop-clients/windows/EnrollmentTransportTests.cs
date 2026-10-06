using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

internal static class EnrollmentTransportTests
{
    private static int Main(string[] args)
    {
        try
        {
            const string key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
            foreach (string path in new[] { "/client/v1/enroll", "/client/v1/enrollment" })
            {
                bool claim = path.EndsWith("/enroll");
                EnrollmentTransportClient.ValidateEndpoint(new Uri("https://vpn.example.com:8443" + path), key, claim);
                foreach (string url in new[] { "http://vpn.example.com" + path, "https://user@vpn.example.com" + path,
                    "https://127.0.0.1" + path, "https://vpn.example.com" + path + "?token=secret",
                    "https://vpn.example.com" + path + "#secret", "https://vpn.example.com/ubus" })
                    Reject(() => EnrollmentTransportClient.ValidateEndpoint(new Uri(url), key, claim));
                Reject(() => EnrollmentTransportClient.ValidateEndpoint(new Uri("https://vpn.example.com" + path), key + "\n", claim));
                Reject(() => EnrollmentTransportClient.ValidateEndpoint(new Uri("https://vpn.example.com" + path), key, !claim));
            }
            Reject(() => EnrollmentTransportClient.Claim(new Uri("https://vpn.example.com/client/v1/enroll"), key, key));
            string pending = "{\"version\":1,\"state\":\"pending\",\"id\":\"laptop\"}";
            if (!Decode(pending, 202).Pending || Decode(pending, 202).Password != null)
                throw new Exception("Pending response exposed credentials");
            Reject(() => Decode(pending, 200));
            Reject(() => Decode(pending.Replace("laptop", "../secret"), 202));
            Reject(() => Decode(pending.Replace("1", "2"), 202));
            Reject(() => Decode(pending.Replace("}", ",\"password\":\"do-not-print\"}"), 202));
            var serializer = new JavaScriptSerializer();
            var fixture = (object[])serializer.DeserializeObject(File.ReadAllText(args[0]));
            var policy = (Dictionary<string, object>)((Dictionary<string, object>)fixture[0])["policy"];
            var credentials = new Dictionary<string, object> { { "username", policy["id"] }, { "password", key } };
            var bundle = new Dictionary<string, object> { { "version", 1 }, { "state", "enrolled" },
                { "policy", policy }, { "credentials", credentials } };
            string valid = serializer.Serialize(bundle);
            var result = Decode(valid, 200);
            if (result.Pending || result.Id != (string)policy["id"] || result.Password != key || result.ToString().Contains(key))
                throw new Exception("Bootstrap not decoded safely");
            Reject(() => Decode(valid, 202));
            credentials["username"] = "other";
            Reject(() => Decode(serializer.Serialize(bundle), 200));
            credentials["username"] = policy["id"];
            credentials["password"] = "do-not-print";
            Reject(() => Decode(serializer.Serialize(bundle), 200));
            Reject(() => EnrollmentTransportClient.Decode(new MemoryStream(Encoding.UTF8.GetBytes(valid)), "text/html", -1, 200));
            Reject(() => EnrollmentTransportClient.Decode(new MemoryStream(new byte[1048577]), "application/json", -1, 200));
            Reject(() => EnrollmentTransportClient.Decode(new MemoryStream(new byte[] { 255 }), "application/json", 1, 200));
            Reject(() => EnrollmentTransportClient.Decode(new MemoryStream(Encoding.UTF8.GetBytes(valid)), "application/json", 1, 200));
            Reject(() => Decode("{}", 200));
            Console.WriteLine("Enrollment transport checks passed: endpoint, schema, binding, size and safe errors");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
    }

    private static EnrollmentResult Decode(string json, int status)
    {
        return EnrollmentTransportClient.Decode(new MemoryStream(Encoding.UTF8.GetBytes(json)), "application/json", -1, status);
    }

    private static void Reject(Action action)
    {
        try { action(); }
        catch (ArgumentException) { return; }
        catch (EnrollmentException error)
        {
            if (error.Message.Contains("do-not-print")) throw new Exception("Secret escaped into error");
            return;
        }
        throw new Exception("Unsafe enrollment response accepted");
    }
}
