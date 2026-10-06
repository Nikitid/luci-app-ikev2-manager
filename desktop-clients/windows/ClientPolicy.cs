using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace IkeV2Manager.Client
{
    public sealed class PolicyTransport
    {
        public readonly string Protocol;
        public readonly ReadOnlyCollection<int> Ports;
        internal PolicyTransport(string protocol, IEnumerable<int> ports)
        { Protocol = protocol; Ports = Array.AsReadOnly(ports.OrderBy(p => p).ToArray()); }
    }

    public sealed class PolicyResource
    {
        public readonly string Id, Domain, Address;
        public readonly ReadOnlyCollection<PolicyTransport> Transports;
        internal PolicyResource(string id, string domain, string address, IEnumerable<PolicyTransport> transports)
        { Id = id; Domain = domain; Address = address; Transports = Array.AsReadOnly(transports.OrderBy(t => t.Protocol, StringComparer.Ordinal).ToArray()); }
    }

    // Validation does not authenticate a policy. The caller must verify its
    // enrolled source before accepting it or persisting the next history.
    public sealed class ClientPolicy
    {
        public readonly string Id, ServerAddress, RemoteId, VirtualSubnet, Exit;
        public readonly int Revision;
        public readonly ReadOnlyCollection<PolicyResource> Resources;
        internal readonly string Canonical;

        private ClientPolicy(Dictionary<string, object> root)
        {
            Fields(root, "version", "id", "revision", "server", "virtual_subnet", "exit", "resources");
            Integer(root["version"], 1, 1);
            Id = Identifier(root["id"]);
            Revision = Integer(root["revision"], 1, Int32.MaxValue);
            var server = Object(root["server"]);
            Fields(server, "address", "remote_id");
            ServerAddress = Domain(server["address"]); RemoteId = Domain(server["remote_id"]);
            Exit = Text(root["exit"]);
            Require(Regex.IsMatch(Exit, @"\A[1-7]s?\z"));
            VirtualSubnet = Text(root["virtual_subnet"]);
            string[] subnet = VirtualSubnet.Split('/');
            Require(subnet.Length == 2 && Regex.IsMatch(subnet[1], @"\A(?:1[6-9]|2[0-8])\z"));
            uint first = Address(subnet[0]);
            uint size = 1u << (32 - Int32.Parse(subnet[1], CultureInfo.InvariantCulture));
            Require((first >> 24 == 10 || first >> 20 == 0xAC1 || first >> 16 == 0xC0A8) && first % size == 0);
            var ids = new HashSet<string>(StringComparer.Ordinal);
            var domains = new HashSet<string>(StringComparer.Ordinal);
            var addresses = new HashSet<string>(StringComparer.Ordinal);
            var resources = new List<PolicyResource>();
            foreach (object item in ArrayValue(root["resources"], 1, 4096))
            {
                var resource = Object(item); Fields(resource, "id", "domain", "address", "transports");
                string id = Identifier(resource["id"]), domain = Domain(resource["domain"]), address = Text(resource["address"]);
                uint number = Address(address);
                Require(number > first && number < first + size - 1 && ids.Add(id) && domains.Add(domain) && addresses.Add(address));
                Require(domain != ServerAddress && domain != RemoteId);
                var protocols = new HashSet<string>(StringComparer.Ordinal);
                var transports = new List<PolicyTransport>();
                foreach (object entry in ArrayValue(resource["transports"], 1, 2))
                {
                    var transport = Object(entry); Fields(transport, "protocol", "ports");
                    string protocol = Text(transport["protocol"]);
                    Require((protocol == "tcp" || protocol == "udp") && protocols.Add(protocol));
                    var ports = new HashSet<int>();
                    foreach (object port in ArrayValue(transport["ports"], 1, 64)) Require(ports.Add(Integer(port, 1, 65535)));
                    transports.Add(new PolicyTransport(protocol, ports));
                }
                resources.Add(new PolicyResource(id, domain, address, transports));
            }
            Resources = Array.AsReadOnly(resources.OrderBy(r => r.Domain, StringComparer.Ordinal).ToArray());
            // All strings have constrained ASCII grammars, so delimiters cannot
            // occur in values. Ordering differences do not change policy identity.
            var canonical = new StringBuilder();
            canonical.Append(Id).Append('|').Append(Revision).Append('|').Append(ServerAddress).Append('|')
                .Append(RemoteId).Append('|').Append(VirtualSubnet).Append('|').Append(Exit);
            foreach (var resource in Resources)
            {
                canonical.Append('|').Append(resource.Id).Append(':').Append(resource.Domain).Append(':').Append(resource.Address);
                foreach (var transport in resource.Transports)
                    canonical.Append(':').Append(transport.Protocol).Append(':').Append(String.Join(",", transport.Ports));
            }
            Canonical = canonical.ToString();
        }

        internal Dictionary<string, object> Document()
        {
            return new Dictionary<string, object> {
                { "version", 1 }, { "id", Id }, { "revision", Revision },
                { "server", new Dictionary<string, object> { { "address", ServerAddress }, { "remote_id", RemoteId } } },
                { "virtual_subnet", VirtualSubnet }, { "exit", Exit },
                { "resources", Resources.Select(r => new Dictionary<string, object> {
                    { "id", r.Id }, { "domain", r.Domain }, { "address", r.Address },
                    { "transports", r.Transports.Select(t => new Dictionary<string, object> {
                        { "protocol", t.Protocol }, { "ports", t.Ports.ToArray() } }).ToArray() }
                }).ToArray() }
            };
        }

        public static ClientPolicy Parse(string json)
        {
            Require(json != null && Encoding.UTF8.GetByteCount(json) <= 1048576);
            return new ClientPolicy(Object(new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 12 }.DeserializeObject(json)));
        }
        internal static Dictionary<string, object> Object(object value)
        { var result = value as Dictionary<string, object>; Require(result != null); return result; }
        internal static void Fields(Dictionary<string, object> value, params string[] keys)
        { Require(value.Count == keys.Length && keys.All(k => value.ContainsKey(k) && value[k] != null)); }
        internal static IEnumerable<object> ArrayValue(object value, int min, int max)
        {
            var array = value as object[]; Require(array != null && array.Length >= min && array.Length <= max); return array;
        }
        internal static string Text(object value) { Require(value is string); return (string)value; }
        internal static int Integer(object value, int min, int max)
        { Require(value is int && (int)value >= min && (int)value <= max); return (int)value; }
        private static string Identifier(object value)
        { string text = Text(value); Require(Regex.IsMatch(text, @"\A[a-z][a-z0-9-]{0,47}\z")); return text; }
        internal static string Domain(object value)
        {
            string text = Text(value);
            Require(text.Length <= 253 && text.Contains('.') && !Regex.IsMatch(text, @"\A[0-9.]+\z") &&
                text.Split('.').All(label => Regex.IsMatch(label, @"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z")));
            return text;
        }
        internal static uint Address(string text)
        {
            string[] parts = text.Split('.'); Require(parts.Length == 4);
            uint result = 0;
            foreach (string part in parts)
            {
                byte number;
                Require(Regex.IsMatch(part, @"\A(?:0|[1-9][0-9]{0,2})\z") && Byte.TryParse(part, out number));
                result = (result << 8) | Byte.Parse(part, CultureInfo.InvariantCulture);
            }
            return result;
        }
        private static void Require(bool valid) { if (!valid) throw new ArgumentException("Invalid client policy"); }
    }

    // Immutable proposed state. Persist it transactionally with activation;
    // validating an update alone must not advance the committed revision.
    public sealed class PolicyHistory
    {
        public readonly ClientPolicy Current;
        private readonly Dictionary<string, string> allocations;
        private PolicyHistory(ClientPolicy policy, Dictionary<string, string> history)
        { Current = policy; allocations = history; }
        public static PolicyHistory Begin(ClientPolicy policy)
        {
            if (policy == null) throw new ArgumentNullException("policy");
            return new PolicyHistory(policy, policy.Resources.ToDictionary(r => r.Domain, r => r.Address, StringComparer.Ordinal));
        }
        public PolicyHistory Propose(ClientPolicy next)
        {
            if (next == null || next.Id != Current.Id || next.ServerAddress != Current.ServerAddress || next.RemoteId != Current.RemoteId ||
                next.VirtualSubnet != Current.VirtualSubnet || next.Revision < Current.Revision ||
                (next.Revision == Current.Revision && next.Canonical != Current.Canonical))
                throw new InvalidOperationException("Policy identity changed or revision did not advance");
            var history = new Dictionary<string, string>(allocations, StringComparer.Ordinal);
            var reverse = history.ToDictionary(p => p.Value, p => p.Key, StringComparer.Ordinal);
            foreach (var resource in next.Resources)
            {
                string previous, owner;
                if ((history.TryGetValue(resource.Domain, out previous) && previous != resource.Address) ||
                    (reverse.TryGetValue(resource.Address, out owner) && owner != resource.Domain))
                    throw new InvalidOperationException("Policy changed a reserved domain allocation");
                history[resource.Domain] = resource.Address; reverse[resource.Address] = resource.Domain;
            }
            if (history.Count > 4096) throw new InvalidOperationException("Client allocation history exceeds limit");
            return new PolicyHistory(next, history);
        }
        public string Export()
        {
            return new JavaScriptSerializer { MaxJsonLength = 2097152 }.Serialize(new Dictionary<string, object> {
                { "version", 1 }, { "current", Current.Document() },
                { "allocations", allocations.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p =>
                    new Dictionary<string, object> { { "domain", p.Key }, { "address", p.Value } }).ToArray() }
            });
        }

        public static PolicyHistory Restore(string json)
        {
            if (json == null || Encoding.UTF8.GetByteCount(json) > 2097152)
                throw new ArgumentException("Invalid policy history size");
            var serializer = new JavaScriptSerializer { MaxJsonLength = 2097152, RecursionLimit = 16 };
            var root = ClientPolicy.Object(serializer.DeserializeObject(json));
            ClientPolicy.Fields(root, "version", "current", "allocations");
            ClientPolicy.Integer(root["version"], 1, 1);
            var policy = ClientPolicy.Parse(serializer.Serialize(root["current"]));
            string[] subnet = policy.VirtualSubnet.Split('/');
            uint first = ClientPolicy.Address(subnet[0]);
            uint size = 1u << (32 - Int32.Parse(subnet[1], CultureInfo.InvariantCulture));
            var history = new Dictionary<string, string>(StringComparer.Ordinal);
            var addresses = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in ClientPolicy.ArrayValue(root["allocations"], 1, 4096))
            {
                var entry = ClientPolicy.Object(item); ClientPolicy.Fields(entry, "domain", "address");
                string domain = ClientPolicy.Domain(entry["domain"]), address = ClientPolicy.Text(entry["address"]);
                uint number = ClientPolicy.Address(address);
                if (number <= first || number >= first + size - 1 || domain == policy.ServerAddress || domain == policy.RemoteId ||
                    history.ContainsKey(domain) || !addresses.Add(address)) throw new ArgumentException("Invalid policy allocation history");
                history.Add(domain, address);
            }
            foreach (var resource in policy.Resources)
            {
                string address;
                if (!history.TryGetValue(resource.Domain, out address) || address != resource.Address)
                    throw new ArgumentException("Policy history omits a current allocation");
            }
            return new PolicyHistory(policy, history);
        }

        public string ReconcileHosts(string original)
        {
            // Revocation retains the reserved mapping. Deleting it would allow
            // the system resolver to expose the public destination again.
            var entries = allocations.OrderBy(p => p.Key, StringComparer.Ordinal)
                .Select(p => new HostEntry { domain = p.Key, address = p.Value }).ToList();
            return ManagedHosts.Reconcile(original, entries);
        }

        public ReadOnlyCollection<string> ProtectedAddresses()
        { return Array.AsReadOnly(allocations.Values.OrderBy(a => a, StringComparer.Ordinal).ToArray()); }
    }
}
