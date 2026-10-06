using System;
using System.Collections.Generic;
using System.Linq;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

internal static class ClientPolicyTests
{
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static Dictionary<string, object> Resource(string name, string address)
    {
        return new Dictionary<string, object> { { "id", name }, { "domain", name + ".example.com" }, { "address", address },
            { "transports", new object[] { new Dictionary<string, object> { { "protocol", "tcp" }, { "ports", new[] { 443 } } } } } };
    }
    private static Dictionary<string, object> Policy(int revision, params Dictionary<string, object>[] resources)
    {
        return new Dictionary<string, object> { { "version", 1 }, { "id", "team" }, { "revision", revision },
            { "server", new Dictionary<string, object> { { "address", "vpn.example.com" }, { "remote_id", "vpn.example.com" } } },
            { "virtual_subnet", "172.31.254.0/24" }, { "exit", "1" }, { "resources", resources } };
    }
    private static ClientPolicy Parse(Dictionary<string, object> value) { return ClientPolicy.Parse(Json.Serialize(value)); }
    private static void Reject(Action action, string name)
    {
        try { action(); } catch (ArgumentException) { return; } catch (InvalidOperationException) { return; }
        throw new Exception("Policy unexpectedly accepted: " + name);
    }
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 1) throw new Exception("Policy fixtures path required");
            var fixtures = Json.DeserializeObject(System.IO.File.ReadAllText(args[0])) as object[];
            foreach (Dictionary<string, object> fixture in fixtures)
            {
                bool accepted = true;
                try { Parse((Dictionary<string, object>)fixture["policy"]); }
                catch (ArgumentException) { accepted = false; }
                catch (InvalidOperationException) { accepted = false; }
                if (accepted != (bool)fixture["valid"]) throw new Exception("Shared policy fixture failed: " + fixture["name"]);
            }
            Console.WriteLine("Shared policy fixtures passed: " + fixtures.Length);
            var histories = Json.DeserializeObject(System.IO.File.ReadAllText(System.IO.Path.Combine(
                System.IO.Path.GetDirectoryName(args[0]), "policy-histories.json"))) as object[];
            foreach (Dictionary<string, object> fixture in histories)
            {
                bool accepted = true;
                try { PolicyHistory.Restore(Json.Serialize(fixture["history"])); }
                catch (ArgumentException) { accepted = false; }
                catch (InvalidOperationException) { accepted = false; }
                if (accepted != (bool)fixture["valid"]) throw new Exception("Shared history fixture failed: " + fixture["name"]);
            }
            Console.WriteLine("Shared history fixtures passed: " + histories.Length);
            var first = Parse(Policy(1, Resource("api", "172.31.254.1")));
            var original = PolicyHistory.Begin(first);
            var same = original.Propose(Parse(Policy(1, Resource("api", "172.31.254.1"))));
            var second = original.Propose(Parse(Policy(2, Resource("api", "172.31.254.1"), Resource("chat", "172.31.254.2"))));
            if (original.ProtectedAddresses().Count != 1 || second.ProtectedAddresses().Count != 2 || same.Current.Revision != 1)
                throw new Exception("Proposing a policy mutated committed state");
            var retired = second.Propose(Parse(Policy(3, Resource("chat", "172.31.254.2"))));
            if (!retired.ProtectedAddresses().Contains("172.31.254.1")) throw new Exception("Retired protection disappeared");
            string hosts = second.ReconcileHosts("127.0.0.1 localhost\r\n");
            if (retired.ReconcileHosts(hosts) != hosts || !hosts.Contains("172.31.254.1 api.example.com\r\n"))
                throw new Exception("Revocation removed the protected hosts mapping");
            Reject(() => retired.ReconcileHosts("192.0.2.1 api.example.com\n"), "conflicting unmanaged hosts mapping");
            var recovered = PolicyHistory.Restore(retired.Export());
            if (recovered.Current.Revision != 3 || recovered.ReconcileHosts(hosts) != hosts ||
                !recovered.ProtectedAddresses().SequenceEqual(retired.ProtectedAddresses()))
                throw new Exception("History round trip lost protection or revision");
            Reject(() => recovered.Propose(first), "recovered revision rollback");
            Reject(() => recovered.Propose(Parse(Policy(4, Resource("other", "172.31.254.1")))), "recovered retired address reused");
            Reject(() => retired.Propose(first), "revision rollback");
            Reject(() => original.Propose(Parse(Policy(1, Resource("chat", "172.31.254.2")))), "same revision different contents");
            Reject(() => retired.Propose(Parse(Policy(4, Resource("other", "172.31.254.1")))), "retired address reused");
            Reject(() => retired.Propose(Parse(Policy(4, Resource("api", "172.31.254.3")))), "retired domain moved");
            var changedServer = Policy(4, Resource("api", "172.31.254.1"));
            ((Dictionary<string, object>)changedServer["server"])["address"] = "other.example.com";
            Reject(() => retired.Propose(Parse(changedServer)), "server changed");
            var reordered = Parse(Policy(2, Resource("chat", "172.31.254.2"), Resource("api", "172.31.254.1")));
            second.Propose(reordered);
            foreach (string address in new[] { "172.31.254.0", "172.31.254.255", "172.31.253.1", "172.31.254.01", "::1", "127.1" })
                Reject(() => Parse(Policy(1, Resource("api", address))), "invalid resource address");
            foreach (string domain in new[] { "*.example.com", "vpn.example.com", "API.example.com", "api.example.com\n", "1.2.3.4", "api..com" })
            {
                var resource = Resource("api", "172.31.254.1"); resource["domain"] = domain;
                Reject(() => Parse(Policy(1, resource)), "invalid or bootstrap domain");
            }
            foreach (object revision in new object[] { true, 1.5, "1", 0, 2147483648L })
            {
                var policy = Policy(1, Resource("api", "172.31.254.1")); policy["revision"] = revision;
                Reject(() => Parse(policy), "invalid revision type or range");
            }
            foreach (string subnet in new[] { "8.8.0.0/16", "172.32.0.0/16", "172.31.254.1/24", "172.31.254.0/29", "172.31.0.0/15" })
            {
                var policy = Policy(1, Resource("api", "172.31.254.1")); policy["virtual_subnet"] = subnet;
                Reject(() => Parse(policy), "invalid subnet");
            }
            Reject(() => Parse(Policy(1, Resource("api", "172.31.254.1"), Resource("chat", "172.31.254.1"))), "duplicate address");
            Reject(() => Parse(Policy(1)), "empty policy");
            var unknown = Policy(1, Resource("api", "172.31.254.1")); unknown["command"] = "ignored-command";
            Reject(() => Parse(unknown), "unknown field");
            var separate = Resource("api", "172.31.254.1");
            separate["transports"] = new object[] {
                new Dictionary<string, object> { { "protocol", "tcp" }, { "ports", new[] { 443, 80 } } },
                new Dictionary<string, object> { { "protocol", "udp" }, { "ports", new[] { 3478 } } } };
            var transports = Parse(Policy(1, separate)).Resources[0].Transports;
            if (!transports[0].Ports.SequenceEqual(new[] { 80, 443 }) || !transports[1].Ports.SequenceEqual(new[] { 3478 }))
                throw new Exception("Transport permissions were mixed");
            separate["transports"] = new object[] { new Dictionary<string, object> { { "protocol", "tcp" }, { "ports", new[] { 443, 443 } } } };
            Reject(() => Parse(Policy(1, separate)), "duplicate port");
            Reject(() => ClientPolicy.Parse(new string(' ', 1048577)), "oversized document");
            Console.WriteLine("Client policy checks passed: revisions, identity, retained allocations, schema and transport isolation");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
