using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IkeV2Manager.Client
{
    public sealed class PolicyFetchException : Exception
    {
        public readonly string Code;
        internal PolicyFetchException(string code) : base(code) { Code = code; }
    }

    // What the router attests for one device at one tunnel address.
    public sealed class DeviceReadiness
    {
        public readonly string Id, Address;
        public readonly int Revision;

        private DeviceReadiness(string id, string address, int revision) { Id = id; Address = address; Revision = revision; }

        internal static DeviceReadiness Parse(string json)
        {
            try
            {
                var data = ClientPolicy.Object(new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = 4096, RecursionLimit = 3 }.DeserializeObject(json));
                ClientPolicy.Fields(data, "version", "state", "id", "revision", "policy_sha256", "address", "generation", "expires_at");
                if (ClientPolicy.Integer(data["version"], 1, 1) != 1 || ClientPolicy.Text(data["state"]) != "ready" ||
                    !Regex.IsMatch(ClientPolicy.Text(data["id"]), @"\A[a-z][a-z0-9-]{0,47}\z") ||
                    !Regex.IsMatch(ClientPolicy.Text(data["policy_sha256"]), @"\A[a-f0-9]{64}\z"))
                    throw new ArgumentException();
                ClientPolicy.Integer(data["generation"], 1, Int32.MaxValue);
                if (!(data["expires_at"] is int) && !(data["expires_at"] is long)) throw new ArgumentException();
                string address = ClientPolicy.Text(data["address"]);
                ClientPolicy.Address(address);
                return new DeviceReadiness((string)data["id"], address, ClientPolicy.Integer(data["revision"], 1, Int32.MaxValue));
            }
            catch (ArgumentException) { throw new PolicyFetchException("path_response_invalid"); }
            catch (InvalidOperationException) { throw new PolicyFetchException("path_response_invalid"); }
        }
    }

    // One service a person was offered, as this device has it: on or off,
    // required or not, blocked without the tunnel or not and whether that is
    // the person's to choose, and which of the policy's resources and networks
    // it holds. It grants nothing; the router decides what passes.
    public sealed class ServiceEntry
    {
        public string Id { get; set; }
        public string Label { get; set; }
        public bool Required { get; set; }
        public bool On { get; set; }
        public bool Closed { get; set; }
        public bool ChooseClosed { get; set; }
        public int Domains { get; set; }
        public int Networks { get; set; }
        public string[] Resources { get; set; }
        public string[] Cidrs { get; set; }
        // Whether the service works now, as the router routes it: "ok", "down",
        // "direct" or "unknown"; why it is down ("no_tunnel", "silent"), and
        // since when it works, in seconds of the router's clock (0 unknown).
        public string Health { get; set; }
        public string HealthReason { get; set; }
        public int HealthSince { get; set; }

        // Read leniently: a state this program does not know yet is "unknown",
        // and fields it does not know are left alone, so a newer router never
        // takes the list of services away from an older client.
        internal static void ReadHealth(ServiceEntry entry, object value)
        {
            entry.Health = "unknown"; entry.HealthReason = ""; entry.HealthSince = 0;
            var data = value as System.Collections.Generic.IDictionary<string, object>;
            if (data == null) return;
            object state, reason, since;
            if (data.TryGetValue("state", out state) && (state as string == "ok" || state as string == "down" || state as string == "direct"))
                entry.Health = (string)state;
            if (entry.Health == "down" && data.TryGetValue("reason", out reason) && (reason as string == "no_tunnel" || reason as string == "silent"))
                entry.HealthReason = (string)reason;
            if (entry.Health == "ok" && data.TryGetValue("since", out since) && since is int && (int)since > 0) entry.HealthSince = (int)since;
        }

        internal static ServiceEntry[] ParseAll(object value)
        {
            var entries = new System.Collections.Generic.List<ServiceEntry>();
            var seen = new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal);
            foreach (object item in ClientPolicy.ArrayValue(value, 0, 128))
            {
                var data = ClientPolicy.Object(item);
                string[] keys = { "id", "required", "on", "closed", "choose_closed", "domains", "networks", "resources", "cidrs" };
                var optional = new[] { "label", "health" }.Where(data.ContainsKey);
                ClientPolicy.Fields(data, keys.Concat(optional).ToArray());
                string id = ClientPolicy.Text(data["id"]);
                if (!Regex.IsMatch(id, @"\A[a-z0-9][a-z0-9_-]{0,47}\z") || !seen.Add(id)) throw new ArgumentException();
                foreach (string flag in new[] { "required", "on", "closed", "choose_closed" })
                    if (!(data[flag] is bool)) throw new ArgumentException();
                var resources = ClientPolicy.ArrayValue(data["resources"], 0, 4096).Select(ClientPolicy.Text).ToArray();
                if (!resources.All(r => Regex.IsMatch(r, @"\Ahost-[0-9]{1,7}\z"))) throw new ArgumentException();
                var cidrs = ClientPolicy.ArrayValue(data["cidrs"], 0, 64).Select(ClientPolicy.Text).ToArray();
                foreach (string cidr in cidrs) { uint first, last; ClientPolicy.Network(cidr, out first, out last); }
                string label = id;
                if (data.ContainsKey("label"))
                {
                    // Shown as text, never markup: one line of at most 64 characters.
                    label = ClientPolicy.Text(data["label"]);
                    if (label.Length < 1 || label.Length > 64 || label.Any(Char.IsControl)) throw new ArgumentException();
                }
                var entry = new ServiceEntry { Id = id, Label = label, Required = (bool)data["required"], On = (bool)data["on"],
                    Closed = (bool)data["closed"], ChooseClosed = (bool)data["choose_closed"],
                    Domains = ClientPolicy.Integer(data["domains"], 0, 65536), Networks = ClientPolicy.Integer(data["networks"], 0, 64),
                    Resources = resources, Cidrs = cidrs };
                if (entry.Required && !entry.On) throw new ArgumentException();
                ReadHealth(entry, data.ContainsKey("health") ? data["health"] : null);
                entries.Add(entry);
            }
            return entries.ToArray();
        }
    }

    // The names a device shows its user. Informational: permission never
    // depends on it. Its informational tunnel network grants no access.
    public sealed class DeviceServices
    {
        // What the person was offered, where the router gives an offer.
        public ServiceEntry[] Entries { get; private set; }
        // Present where the person may add addresses of their own.
        public OwnAddresses Own { get; private set; }
        public readonly string[] Selected, Available;
        public readonly int Domains;
        // Whether services stay blocked while the tunnel is down. That is the
        // rule; a router that says nothing about it means the rule.
        public readonly bool Block;
        // Whether everything goes into the tunnel, or the services alone.
        public readonly bool Full;
        // Whether the router answers names over HTTPS at the resolver address.
        public readonly bool NamesHttps;
        public string TunnelSubnet { get; private set; }

        private DeviceServices(string[] selected, string[] available, int domains, bool block, bool full, bool namesHttps) { Selected = selected; Available = available; Domains = domains; Block = block; Full = full; NamesHttps = namesHttps; }

        internal static DeviceServices Parse(string json, string id)
        {
            try
            {
                var data = ClientPolicy.Object(new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = 65536, RecursionLimit = 5 }.DeserializeObject(json));
                // This answer describes; it grants nothing. A field a later
                // router adds is ignored, so an installed client keeps working
                // with it. What is known must still be in its exact form.
                foreach (string needed in new[] { "version", "id", "revision", "selected", "available" })
                    if (!data.ContainsKey(needed)) throw new ArgumentException();
                bool block = true;
                if (data.ContainsKey("block_without_tunnel"))
                {
                    if (!(data["block_without_tunnel"] is bool)) throw new ArgumentException();
                    block = (bool)data["block_without_tunnel"];
                }
                bool full = false;
                if (data.ContainsKey("mode"))
                {
                    string mode = data["mode"] as string;
                    if (mode != "services" && mode != "full") throw new ArgumentException();
                    full = mode == "full";
                }
                bool namesHttps = false;
                if (data.ContainsKey("names_https"))
                {
                    if (!(data["names_https"] is bool)) throw new ArgumentException();
                    namesHttps = (bool)data["names_https"];
                }
                if (ClientPolicy.Integer(data["version"], 1, 1) != 1 || ClientPolicy.Text(data["id"]) != id) throw new ArgumentException();
                ClientPolicy.Integer(data["revision"], 1, Int32.MaxValue);
                int domains = 0;
                var lists = new System.Collections.Generic.List<string[]>();
                foreach (string key in new[] { "selected", "available" })
                {
                    var names = new System.Collections.Generic.List<string>();
                    foreach (object item in ClientPolicy.ArrayValue(data[key], 0, 512))
                    {
                        var service = ClientPolicy.Object(item);
                        ClientPolicy.Fields(service, "id", "domains");
                        string name = ClientPolicy.Text(service["id"]);
                        if (!Regex.IsMatch(name, @"\A[a-z0-9][a-z0-9_-]{0,47}\z") || names.Contains(name)) throw new ArgumentException();
                        int count = ClientPolicy.Integer(service["domains"], 0, 65536);
                        if (key == "selected") domains += count;
                        names.Add(name);
                    }
                    lists.Add(names.ToArray());
                }
                string tunnel = data.ContainsKey("tunnel_subnet") ? data["tunnel_subnet"] as string : "";
                if (tunnel == null) throw new ArgumentException();
                if (tunnel != "") {
                    var pieces = tunnel.Split('/'); int prefix;
                    if (pieces.Length != 2 || !Int32.TryParse(pieces[1], out prefix) || prefix < 1 || prefix > 32 || prefix.ToString() != pieces[1]) throw new ArgumentException();
                    uint address = ClientPolicy.Address(pieces[0]);
                    if ((address & (UInt32.MaxValue << (32-prefix))) != address) throw new ArgumentException();
                }
                return new DeviceServices(lists[0], lists[1], domains, block, full, namesHttps) { TunnelSubnet = tunnel,
                    Entries = data.ContainsKey("entries") ? ServiceEntry.ParseAll(data["entries"]) : null,
                    Own = data.ContainsKey("own") ? OwnAddresses.Parse(data["own"]) : null };
            }
            catch (ArgumentException) { throw new PolicyFetchException("services_response_invalid"); }
            catch (InvalidOperationException) { throw new PolicyFetchException("services_response_invalid"); }
        }
    }

    public static class PolicyTransportClient
    {
        private const int Limit = 1048576;

        // Call only with the endpoint, token and initial policy authenticated at
        // enrollment. This method does not enroll, commit or grant permission.
        public static ClientPolicy Fetch(Uri endpoint, string token, PolicyHistory committed)
        {
            ValidateEndpoint(endpoint, token);
            if (committed == null) throw new ArgumentNullException("committed");
            // This service owns its process. Require TLS 1.2; leave certificate
            // chain and hostname verification to Windows, with no override.
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = (HttpWebRequest)WebRequest.Create(endpoint);
            request.Method = "GET";
            request.AllowAutoRedirect = false;
            request.Proxy = null;
            request.UseDefaultCredentials = false;
            request.KeepAlive = false;
            request.Timeout = request.ReadWriteTimeout = 10000;
            request.MaximumResponseHeadersLength = 16;
            request.Accept = "application/json";
            request.Headers[HttpRequestHeader.Authorization] = "Bearer " + token;
            // For the administrator's list of devices: which computer this is.
            // Nothing depends on it, and only well-formed values are sent.
            foreach (var about in Describe()) request.Headers[about.Key] = about.Value;
            using (var deadline = new Timer(ignored => request.Abort(), null, 10000, Timeout.Infinite))
            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    if (response.StatusCode != HttpStatusCode.OK) throw new PolicyFetchException("policy_http_rejected");
                    using (var stream = response.GetResponseStream())
                    {
                        var next = Decode(stream, response.ContentType, response.ContentLength);
                        try { committed.Propose(next); }
                        catch (InvalidOperationException) { throw new PolicyFetchException("policy_update_rejected"); }
                        return next;
                    }
                }
            }
            catch (WebException error)
            {
                using (var response = error.Response as HttpWebResponse)
                {
                    if (response != null && response.StatusCode == HttpStatusCode.Unauthorized)
                        throw new PolicyFetchException("device_access_revoked");
                    // Known to the router and not switched off, only without a service.
                    if (response != null && response.StatusCode == HttpStatusCode.Conflict)
                        throw new PolicyFetchException("device_no_services");
                }
                throw new PolicyFetchException("policy_connection_failed");
            }
            catch (IOException) { throw new PolicyFetchException("policy_connection_failed"); }
        }

        // The router's answer to "is my required path in effect for this
        // tunnel address now". It is produced only from an admission the router
        // installed for this device's authenticated SA, lives a few seconds and
        // is asked for again before it lapses. A failure of any kind is "no".
        public static DeviceReadiness FetchReadiness(Uri policyEndpoint, string token, IPAddress tunnelAddress)
        {
            ValidateEndpoint(policyEndpoint, token);
            if (tunnelAddress == null || tunnelAddress.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
                throw new ArgumentException("IPv4 tunnel address required");
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = (HttpWebRequest)WebRequest.Create(new UriBuilder(policyEndpoint) { Path = "/client/v1/readiness" }.Uri);
            request.Method = "GET";
            request.AllowAutoRedirect = false;
            request.Proxy = null;
            request.UseDefaultCredentials = false;
            request.KeepAlive = false;
            request.Timeout = request.ReadWriteTimeout = 3000;
            request.MaximumResponseHeadersLength = 16;
            request.Accept = "application/json";
            request.Headers[HttpRequestHeader.Authorization] = "Bearer " + token;
            request.Headers["X-Client-Address"] = tunnelAddress.ToString();
            using (var deadline = new Timer(ignored => request.Abort(), null, 3000, Timeout.Infinite))
            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    if (response.StatusCode != HttpStatusCode.OK) throw new PolicyFetchException("path_unavailable");
                    using (var stream = response.GetResponseStream())
                        return DeviceReadiness.Parse(ReadBody(stream, response.ContentType, response.ContentLength, 4096, "path_response_invalid"));
                }
            }
            catch (WebException error)
            {
                using (var response = error.Response as HttpWebResponse)
                {
                    if (response != null && response.StatusCode == HttpStatusCode.Unauthorized)
                        throw new PolicyFetchException("device_access_revoked");
                    // Known to the router and not switched off, only without a service.
                    if (response != null && response.StatusCode == HttpStatusCode.Conflict)
                        throw new PolicyFetchException("device_no_services");
                    if (response != null) throw new PolicyFetchException("path_unavailable");
                }
                throw new PolicyFetchException("path_connection_failed");
            }
            catch (IOException) { throw new PolicyFetchException("path_connection_failed"); }
        }

        // The version of the router's package, which the clients are released
        // with. Only a number: where to download is the client's own knowledge.
        public static string FetchRelease(Uri policyEndpoint, string token)
        {
            ValidateEndpoint(policyEndpoint, token);
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = (HttpWebRequest)WebRequest.Create(new UriBuilder(policyEndpoint) { Path = "/client/v1/release" }.Uri);
            request.Method = "GET";
            request.AllowAutoRedirect = false;
            request.Proxy = null;
            request.UseDefaultCredentials = false;
            request.KeepAlive = false;
            request.Timeout = request.ReadWriteTimeout = 5000;
            request.MaximumResponseHeadersLength = 16;
            request.Accept = "application/json";
            request.Headers[HttpRequestHeader.Authorization] = "Bearer " + token;
            using (var deadline = new Timer(ignored => request.Abort(), null, 5000, Timeout.Infinite))
            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    if (response.StatusCode != HttpStatusCode.OK) throw new PolicyFetchException("release_unavailable");
                    using (var stream = response.GetResponseStream())
                        return ParseRelease(ReadBody(stream, response.ContentType, response.ContentLength, 1024, "release_response_invalid"));
                }
            }
            catch (WebException) { throw new PolicyFetchException("release_unavailable"); }
            catch (IOException) { throw new PolicyFetchException("release_unavailable"); }
        }

        internal static string ParseRelease(string json)
        {
            try
            {
                var data = ClientPolicy.Object(new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = 1024, RecursionLimit = 2 }.DeserializeObject(json));
                ClientPolicy.Fields(data, "version", "release");
                string release = ClientPolicy.Text(data["release"]);
                if (ClientPolicy.Integer(data["version"], 1, 1) != 1 || !Regex.IsMatch(release, @"\A[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}\z")) throw new ArgumentException();
                return release;
            }
            catch (ArgumentException) { throw new PolicyFetchException("release_response_invalid"); }
            catch (InvalidOperationException) { throw new PolicyFetchException("release_response_invalid"); }
        }

        public static DeviceServices FetchServices(Uri policyEndpoint, string token, string id)
        {
            ValidateEndpoint(policyEndpoint, token);
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = (HttpWebRequest)WebRequest.Create(new UriBuilder(policyEndpoint) { Path = "/client/v1/services" }.Uri);
            request.Method = "GET";
            request.AllowAutoRedirect = false;
            request.Proxy = null;
            request.UseDefaultCredentials = false;
            request.KeepAlive = false;
            request.Timeout = request.ReadWriteTimeout = 5000;
            request.MaximumResponseHeadersLength = 16;
            request.Accept = "application/json";
            request.Headers[HttpRequestHeader.Authorization] = "Bearer " + token;
            using (var deadline = new Timer(ignored => request.Abort(), null, 5000, Timeout.Infinite))
            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    if (response.StatusCode != HttpStatusCode.OK) throw new PolicyFetchException("services_unavailable");
                    using (var stream = response.GetResponseStream())
                        return DeviceServices.Parse(ReadBody(stream, response.ContentType, response.ContentLength, 65536, "services_response_invalid"), id);
                }
            }
            catch (WebException) { throw new PolicyFetchException("services_unavailable"); }
            catch (IOException) { throw new PolicyFetchException("services_unavailable"); }
        }

        // Whether the administrator asked this device for a report. Any
        // failure is "no": a report is never owed.
        public static bool ReportWanted(Uri policyEndpoint, string token)
        {
            ValidateEndpoint(policyEndpoint, token);
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = ReportRequest(policyEndpoint, token, "GET");
            using (var deadline = new Timer(ignored => request.Abort(), null, 5000, Timeout.Infinite))
            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    if (response.StatusCode != HttpStatusCode.OK) return false;
                    using (var stream = response.GetResponseStream())
                        return ParseReportWanted(ReadBody(stream, response.ContentType, response.ContentLength, 1024, "report_response_invalid"));
                }
            }
            catch (WebException) { return false; }
            catch (IOException) { return false; }
            catch (PolicyFetchException) { return false; }
        }

        internal static bool ParseReportWanted(string json)
        {
            try
            {
                var data = ClientPolicy.Object(new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = 1024, RecursionLimit = 2 }.DeserializeObject(json));
                return data.ContainsKey("version") && ClientPolicy.Integer(data["version"], 1, 1) == 1 &&
                    data.ContainsKey("wanted") && data["wanted"] is bool && (bool)data["wanted"];
            }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
        }

        public const int ReportLimit = 32768;

        // The report goes to the router that asked, over the same verified
        // connection as everything else, and nowhere else.
        public static bool SendReport(Uri policyEndpoint, string token, string report)
        {
            ValidateEndpoint(policyEndpoint, token);
            byte[] body = new UTF8Encoding(false).GetBytes(report ?? "");
            if (body.Length == 0 || body.Length > ReportLimit) return false;
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = ReportRequest(policyEndpoint, token, "POST");
            request.ContentType = "application/json";
            request.ContentLength = body.Length;
            request.ServicePoint.Expect100Continue = false;
            using (var deadline = new Timer(ignored => request.Abort(), null, 10000, Timeout.Infinite))
            try
            {
                using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
                using (var response = (HttpWebResponse)request.GetResponse())
                    return response.StatusCode == HttpStatusCode.OK;
            }
            catch (WebException) { return false; }
            catch (IOException) { return false; }
        }

        // What this device chose of its offer: the optional services it turns
        // on, and those it blocks without the tunnel where that is its choice.
        // Whether the router took it; what it allows comes with the next poll.
        // Asks the router to check the services now. Returns the seconds until
        // the next check may be asked for, and what the router said:
        // "accepted", "too_often", "busy", or "failed" when it could not be asked.
        public static string RequestCheck(Uri policyEndpoint, string token, out int wait)
        {
            ValidateEndpoint(policyEndpoint, token);
            wait = 30;
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = ReportRequest(policyEndpoint, token, "POST", "/client/v1/check");
            request.ContentLength = 0;
            request.ServicePoint.Expect100Continue = false;
            using (var deadline = new Timer(ignored => request.Abort(), null, 10000, Timeout.Infinite))
            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    if (response.StatusCode != HttpStatusCode.Accepted) return "failed";
                    var answer = ReadSmall(response);
                    object next;
                    if (answer != null && answer.TryGetValue("next_after", out next) && next is int && (int)next >= 1 && (int)next <= 3600) wait = (int)next;
                    return "accepted";
                }
            }
            catch (WebException failure)
            {
                var response = failure.Response as HttpWebResponse;
                if (response == null) return "failed";
                using (response)
                {
                    if ((int)response.StatusCode == 409) { wait = 5; return "busy"; }
                    if ((int)response.StatusCode != 429) return "failed";
                    int after;
                    if (Int32.TryParse(response.Headers["Retry-After"], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out after) &&
                        after >= 1 && after <= 3600) wait = after;
                    return "too_often";
                }
            }
            catch (IOException) { return "failed"; }
        }

        private static System.Collections.Generic.IDictionary<string, object> ReadSmall(HttpWebResponse response)
        {
            try
            {
                using (var stream = response.GetResponseStream())
                using (var reader = new StreamReader(stream, new UTF8Encoding(false, true)))
                {
                    var buffer = new char[4096];
                    int read = reader.ReadBlock(buffer, 0, buffer.Length);
                    return new System.Web.Script.Serialization.JavaScriptSerializer().DeserializeObject(new string(buffer, 0, read)) as System.Collections.Generic.IDictionary<string, object>;
                }
            }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }

        public static bool SendChoices(Uri policyEndpoint, string token, string[] on, string[] closed)
        {
            ValidateEndpoint(policyEndpoint, token);
            if (on == null || closed == null || on.Length > 128 || closed.Length > 128 ||
                !on.Concat(closed).All(id => Regex.IsMatch(id ?? "", @"\A[a-z0-9][a-z0-9_-]{0,47}\z"))) return false;
            byte[] body = new UTF8Encoding(false).GetBytes(new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(
                new System.Collections.Generic.Dictionary<string, object> { { "on", on }, { "closed", closed } }));
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = ReportRequest(policyEndpoint, token, "POST", "/client/v1/choices");
            request.ContentType = "application/json";
            request.ContentLength = body.Length;
            request.ServicePoint.Expect100Continue = false;
            using (var deadline = new Timer(ignored => request.Abort(), null, 10000, Timeout.Infinite))
            try
            {
                using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
                using (var response = (HttpWebResponse)request.GetResponse())
                    return response.StatusCode == HttpStatusCode.Accepted;
            }
            catch (WebException) { return false; }
            catch (IOException) { return false; }
        }

        // This device's own sites and networks, as a whole list. What the router
        // said: "accepted", "refused" (not valid), "not_allowed", "too_often",
        // or "failed" when it could not be asked.
        public static string SendOwn(Uri policyEndpoint, string token, string[] domains, string[] networks)
        {
            ValidateEndpoint(policyEndpoint, token);
            if (domains == null || networks == null || domains.Length + networks.Length > 32 ||
                domains.Concat(networks).Any(item => item == null || item.Length > 253)) return "refused";
            byte[] body = new UTF8Encoding(false).GetBytes(new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(
                new System.Collections.Generic.Dictionary<string, object> { { "domains", domains }, { "networks", networks } }));
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = ReportRequest(policyEndpoint, token, "POST", "/client/v1/own");
            request.ContentType = "application/json";
            request.ContentLength = body.Length;
            request.ServicePoint.Expect100Continue = false;
            using (var deadline = new Timer(ignored => request.Abort(), null, 10000, Timeout.Infinite))
            try
            {
                using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
                using (var response = (HttpWebResponse)request.GetResponse())
                    return response.StatusCode == HttpStatusCode.Accepted ? "accepted" : "failed";
            }
            catch (WebException error)
            {
                var answer = error.Response as HttpWebResponse;
                int status = answer == null ? 0 : (int)answer.StatusCode;
                if (answer != null) answer.Close();
                return status == 400 ? "refused" : status == 403 ? "not_allowed" : status == 429 ? "too_often" : "failed";
            }
            catch (IOException) { return "failed"; }
        }

        private static HttpWebRequest ReportRequest(Uri policyEndpoint, string token, string method, string path = "/client/v1/report")
        {
            var request = (HttpWebRequest)WebRequest.Create(new UriBuilder(policyEndpoint) { Path = path }.Uri);
            request.Method = method;
            request.AllowAutoRedirect = false;
            request.Proxy = null;
            request.UseDefaultCredentials = false;
            request.KeepAlive = false;
            request.Timeout = request.ReadWriteTimeout = method == "POST" ? 10000 : 5000;
            request.MaximumResponseHeadersLength = 16;
            request.Accept = "application/json";
            request.Headers[HttpRequestHeader.Authorization] = "Bearer " + token;
            return request;
        }

        internal static System.Collections.Generic.Dictionary<string, string> Describe()
        {
            var result = new System.Collections.Generic.Dictionary<string, string>();
            try
            {
                string host = Environment.MachineName;
                if (Regex.IsMatch(host ?? "", @"\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z")) result["X-Client-Host"] = host;
                using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    string system = key == null ? null : String.Format(System.Globalization.CultureInfo.InvariantCulture, "Windows {0}.{1}.{2}",
                        key.GetValue("CurrentMajorVersionNumber"), key.GetValue("CurrentMinorVersionNumber"), key.GetValue("CurrentBuild"));
                    if (Regex.IsMatch(system ?? "", @"\AWindows [0-9][0-9.]{0,30}\z")) result["X-Client-System"] = system;
                }
                var own = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
                result["X-Client-Version"] = String.Format(System.Globalization.CultureInfo.InvariantCulture, "{0}.{1}.{2}", own.Major, own.Minor, Math.Max(own.Build, 0));
            }
            catch (System.Security.SecurityException) { }
            catch (UnauthorizedAccessException) { }
            catch (IOException) { }
            return result;
        }

        internal static string ReadBody(Stream stream, string contentType, long contentLength, int limit, string invalid)
        {
            if (stream == null || contentType == null ||
                !String.Equals(contentType.Split(';')[0].Trim(), "application/json", StringComparison.OrdinalIgnoreCase) ||
                contentLength > limit || contentLength == 0)
                throw new PolicyFetchException(invalid);
            using (var data = new MemoryStream())
            {
                var buffer = new byte[4096];
                int read;
                while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (data.Length + read > limit) throw new PolicyFetchException(invalid);
                    data.Write(buffer, 0, read);
                }
                if (data.Length == 0 || (contentLength >= 0 && data.Length != contentLength)) throw new PolicyFetchException(invalid);
                try { return new UTF8Encoding(false, true).GetString(data.ToArray()); }
                catch (ArgumentException) { throw new PolicyFetchException(invalid); }
            }
        }

        internal static void ValidateEndpoint(Uri endpoint, string token)
        {
            if (endpoint == null || !endpoint.IsAbsoluteUri || endpoint.Scheme != "https" ||
                endpoint.HostNameType != UriHostNameType.Dns || endpoint.Host.Length > 253 || !endpoint.Host.Contains(".") ||
                endpoint.UserInfo.Length != 0 || endpoint.Query.Length != 0 || endpoint.Fragment.Length != 0 ||
                endpoint.AbsolutePath != "/client/v1/policy" || endpoint.OriginalString.Length > 2048 ||
                token == null || !Regex.IsMatch(token, @"\A[a-f0-9]{64}\z"))
                throw new ArgumentException("Invalid enrolled policy endpoint or device key");
        }

        internal static ClientPolicy Decode(Stream stream, string contentType, long contentLength)
        {
            if (stream == null || contentType == null ||
                !String.Equals(contentType.Split(';')[0].Trim(), "application/json", StringComparison.OrdinalIgnoreCase) ||
                contentLength > Limit || contentLength == 0)
                throw new PolicyFetchException("policy_response_invalid");
            using (var data = new MemoryStream())
            {
                var buffer = new byte[4096];
                int read;
                while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (data.Length + read > Limit) throw new PolicyFetchException("policy_response_too_large");
                    data.Write(buffer, 0, read);
                }
                if (data.Length == 0 || (contentLength >= 0 && data.Length != contentLength))
                    throw new PolicyFetchException("policy_response_invalid");
                try { return ClientPolicy.Parse(new UTF8Encoding(false, true).GetString(data.ToArray())); }
                catch (ArgumentException) { throw new PolicyFetchException("policy_response_invalid"); }
                catch (InvalidOperationException) { throw new PolicyFetchException("policy_response_invalid"); }
            }
        }
    }
}
