using System;
using System.IO;
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

    // The names a device shows its user. Informational: permission never
    // depends on it, so it carries no addresses and grants nothing.
    public sealed class DeviceServices
    {
        public readonly string[] Selected, Available;
        public readonly int Domains;

        private DeviceServices(string[] selected, string[] available, int domains) { Selected = selected; Available = available; Domains = domains; }

        internal static DeviceServices Parse(string json, string id)
        {
            try
            {
                var data = ClientPolicy.Object(new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = 65536, RecursionLimit = 5 }.DeserializeObject(json));
                ClientPolicy.Fields(data, "version", "id", "revision", "selected", "available");
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
                return new DeviceServices(lists[0], lists[1], domains);
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
