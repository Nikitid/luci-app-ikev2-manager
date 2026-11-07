using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Linq;
using System.Web.Script.Serialization;

namespace IkeV2Manager.Client
{
    // A service as the window shows it: offered to this person, on or off,
    // blocked without the tunnel or not, and what of it is theirs to change.
    public sealed class ServiceChoice
    {
        public string Id { get; set; }
        public string Label { get; set; }
        public bool Required { get; set; }
        public bool On { get; set; }
        public bool Closed { get; set; }
        public bool ChooseClosed { get; set; }
    }

    // Sites and networks the person added for this device, and how many and on
    // which ports the administrator allows. The router checks every one again.
    public sealed class OwnAddresses
    {
        public int Limit { get; private set; }
        public int[] Ports { get; private set; }
        public string[] Domains { get; private set; }
        public string[] Networks { get; private set; }

        // The service the router makes of them, which the window shows apart.
        public static bool IsService(string id) { return id != null && id.StartsWith("own-", StringComparison.Ordinal); }

        internal static OwnAddresses Parse(object value)
        {
            var data = ClientPolicy.Object(value);
            ClientPolicy.Fields(data, "limit", "ports", "domains", "networks");
            int limit = ClientPolicy.Integer(data["limit"], 1, 32);
            var ports = ClientPolicy.ArrayValue(data["ports"], 1, 16).Select(port => ClientPolicy.Integer(port, 1, 65535)).ToArray();
            var domains = ClientPolicy.ArrayValue(data["domains"], 0, 32).Select(ClientPolicy.Text).ToArray();
            var networks = ClientPolicy.ArrayValue(data["networks"], 0, 32).Select(ClientPolicy.Text).ToArray();
            if (domains.Length + networks.Length > 32 ||
                domains.Any(name => name.Length > 253 || !Regex.IsMatch(name, @"\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z")) ||
                networks.Any(network => Input(network) == null || Input(network)[1] != network)) throw new ArgumentException();
            return new OwnAddresses { Limit = limit, Ports = ports, Domains = domains, Networks = networks };
        }

        // What the person typed or pasted: a link is taken for its host, an
        // address alone is the host itself, a range is kept as written. Null
        // for anything else; otherwise { domain, null } or { null, network }.
        public static string[] Input(string text)
        {
            string value = (text ?? "").Trim().ToLowerInvariant();
            int scheme = value.IndexOf("://", StringComparison.Ordinal);
            if (scheme >= 0) value = value.Substring(scheme + 3);
            if (value.Length > 0 && value.All(c => Char.IsDigit(c) || c == '.' || c == '/'))
            {
                string network = value.Contains("/") ? value : value + "/32";
                var pieces = network.Split('/'); int prefix; uint address;
                try { address = ClientPolicy.Address(pieces[0]); } catch (ArgumentException) { return null; }
                if (pieces.Length != 2 || !Int32.TryParse(pieces[1], out prefix) || prefix < 1 || prefix > 32 || prefix.ToString() != pieces[1] ||
                    (address & (UInt32.MaxValue << (32 - prefix))) != address) return null;
                return new[] { null, network };
            }
            int cut = value.IndexOfAny(new[] { '/', '?', '#', ':' });
            if (cut >= 0) value = value.Substring(0, cut);
            if (value.EndsWith(".", StringComparison.Ordinal)) value = value.Substring(0, value.Length - 1);
            var labels = value.Split('.');
            if (labels.Length < 2 || labels.Last().All(Char.IsDigit) || value.Length > 253 ||
                labels.Any(label => label.Length < 1 || label.Length > 63 || !Regex.IsMatch(label, @"\A[a-z0-9-]+\z"))) return null;
            return new[] { value, null };
        }
    }

    // The person's own sites and networks as the window shows them: what the
    // administrator allows, what this device keeps or is sending, and what the
    // router said of the last list ("" when it was taken).
    public sealed class OwnStatus
    {
        public int Limit { get; set; }
        public int[] Ports { get; set; }
        public string[] Domains { get; set; }
        public string[] Networks { get; set; }
        public bool Pending { get; set; }
        public string Answer { get; set; }
    }

    public sealed class ClientView
    {
        public string State { get; private set; }
        public bool GuardInstalled { get; private set; }
        // Derived, never stored: the one state the service publishes only
        // while the router's readiness for this tunnel is fresh.
        public bool Protected { get { return State == "protected"; } }
        public string ConnectionError { get; private set; }
        public string[] Services { get; private set; }
        public int Domains { get; private set; }
        public int Revision { get; private set; }
        public bool Wanted { get; private set; }
        // The tunnel and the selected routes through it are confirmed in both.
        public bool Routed { get { return State == "tunnel_connected" || State == "protected"; } }
        internal ClientView(string state, bool installed = false, string connectionError = "none",
            string[] services = null, int domains = 0, int revision = 0, bool wanted = false, string[] available = null)
        {
            State = state; GuardInstalled = installed; ConnectionError = connectionError;
            Services = services ?? new string[0]; Available = available ?? new string[0]; Domains = domains; Revision = revision; Wanted = wanted;
            Entries = new ServiceChoice[0];
        }
        public string[] Available { get; private set; }
        public string Release { get; internal set; }
        public string ServerName { get; internal set; }
        public string ServerIP { get; internal set; }
        public string ServicesSubnet { get; internal set; }
        public string TunnelSubnet { get; internal set; }
        public string[] Warnings { get; internal set; }
        // The service's own journal of what went wrong; empty when unreadable.
        public string[] Faults { get; internal set; }
        // The offered services, empty where the router gives none; and whether
        // a choice made here is still on its way to the router.
        public ServiceChoice[] Entries { get; internal set; }
        public bool ChoicePending { get; internal set; }
        // Where the person may add addresses of their own; null where not.
        public OwnStatus Own { get; internal set; }

        // Whether the router runs a newer release than this program.
        public static bool Newer(string release, Version own)
        {
            Version offered;
            return !String.IsNullOrEmpty(release) && Version.TryParse(release, out offered) &&
                offered > new Version(own.Major, own.Minor, Math.Max(own.Build, 0));
        }

        public string Report()
        {
            return new JavaScriptSerializer().Serialize(new { Version = 3, State = State,
                GuardInstalled = GuardInstalled, Protected = Protected, Routed = Routed, ConnectionWanted = Wanted,
                ConnectionError = ConnectionError, RouterRelease = Release ?? "", Warnings = Warnings ?? new string[0], Faults = Faults ?? new string[0], Services = Services, AvailableServices = Available, Domains = Domains, PolicyRevision = Revision, CreatedAtUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) });
        }
    }

    // Every state and cause code the service publishes or this reader makes up
    // for it. fixtures/status-codes.json holds the phrase for each; a code
    // added here is added there, and the tests fail until it is.
    public static class ClientStatusCodes
    {
        // Written by the service into status.json.
        public static readonly string[] Published = {
            "blocked", "enrollment_required", "error", "access_closed", "registration_pending", "registration_error",
            "connecting", "tunnel_connected", "connection_error", "protected" };

        // Made up by the reader when there is no status to read.
        public static readonly string[] Unreadable = {
            "service_unavailable", "service_missing", "service_stopped", "status_missing", "status_untrusted",
            "status_unavailable", "status_invalid", "status_process_mismatch", "status_stale" };

        // The named causes; the numbered ones are the prefixes below plus a number.
        public static readonly string[] Causes = {
            "route_or_identity", "interface_missing", "route_mismatch", "route_loopback", "route_interface", "route_source",
            "route_prefix", "projection_missing", "path_unavailable", "path_connection_failed", "path_stalled",
            "path_response_invalid", "path_different_policy", "device_access_revoked", "device_no_services", "service_fault",
            "policy_connection_failed", "policy_http_rejected", "policy_update_rejected", "policy_response_invalid",
            "policy_response_too_large", "services_unavailable", "services_response_invalid", "release_unavailable",
            "release_response_invalid", "enrollment_connection_failed", "enrollment_server_busy", "enrollment_access_rejected",
            "enrollment_http_rejected", "enrollment_response_invalid", "enrollment_response_too_large", "enrollment_internal",
            "enrollment_missing" };

        public static readonly string[] NumberedCauses = { "route_fields_", "native_" };
    }

    public static class ClientStatusReader
    {
        public static ClientView Read(string name = "IKEv2ManagerClient")
        {
            if (name != "IKEv2ManagerClient" && !Regex.IsMatch(name ?? "", @"\AIKEv2Manager-Test-[a-f0-9]{32}\z"))
                throw new ArgumentException("Unknown client installation");
            IntPtr manager = IntPtr.Zero, service = IntPtr.Zero;
            try
            {
                manager = Native.OpenSCManagerW(null, null, 1);
                if (manager == IntPtr.Zero) return new ClientView("service_unavailable");
                service = Native.OpenServiceW(manager, name, 4);
                if (service == IntPtr.Zero)
                    return new ClientView(Marshal.GetLastWin32Error() == 1060 ? "service_missing" : "service_unavailable");
                Native.Status status;
                uint required;
                if (!Native.QueryServiceStatusEx(service, 0, out status, (uint)Marshal.SizeOf(typeof(Native.Status)), out required))
                    return new ClientView("service_unavailable");
                if (status.State != 4 || status.Process == 0) return new ClientView("service_stopped");
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name, "status.json");
                if (!File.Exists(path)) return new ClientView("status_missing");
                if (!TrustedFile(path)) return new ClientView("status_untrusted");
                using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (file.Length == 0 || file.Length > 32768) return new ClientView("status_invalid");
                    using (var reader = new StreamReader(file, new UTF8Encoding(false, true), false))
                    {
                        var view = Evaluate(reader.ReadToEnd(), status.Process, DateTime.UtcNow);
                        view.Faults = ReadFaults(Path.Combine(Path.GetDirectoryName(path), "faults.log"));
                        return view;
                    }
                }
            }
            catch (UnauthorizedAccessException) { return new ClientView("status_untrusted"); }
            catch (IOException) { return new ClientView("status_unavailable"); }
            catch (ArgumentException) { return new ClientView("status_invalid"); }
            finally
            {
                if (service != IntPtr.Zero) Native.CloseServiceHandle(service);
                if (manager != IntPtr.Zero) Native.CloseServiceHandle(manager);
            }
        }

        internal static bool ValidNetwork(string text) {
            if (text == "") return true;
            if (text == null) return false;
            var parts = text.Split('/'); int prefix; System.Net.IPAddress ip;
            if (parts.Length != 2 || !Int32.TryParse(parts[1], out prefix) || prefix < 1 || prefix > 32 || prefix.ToString(CultureInfo.InvariantCulture) != parts[1] ||
                !System.Net.IPAddress.TryParse(parts[0], out ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork || ip.ToString() != parts[0]) return false;
            var bytes = ip.GetAddressBytes(); uint address = ((uint)bytes[0] << 24) | ((uint)bytes[1] << 16) | ((uint)bytes[2] << 8) | bytes[3];
            return (address & (UInt32.MaxValue << (32 - prefix))) == address;
        }

        internal static ClientView Evaluate(string json, uint servicePid, DateTime now)
        {
            try
            {
                var serializer = new JavaScriptSerializer { MaxJsonLength = 32768, RecursionLimit = 4 };
                var data = serializer.DeserializeObject(json) as Dictionary<string, object>;
                if (data == null || !data.ContainsKey("Version") || !(data["Version"] is int)) return new ClientView("status_invalid");
                int version = (int)data["Version"];
                if (version < 1 || version > 6 || data.Count != (version == 1 ? 6 : version == 2 ? 7 : version == 3 ? 14 : version == 4 ? 18 : version == 5 ? 20 : 21) || !data.ContainsKey("State") ||
                    !data.ContainsKey("GuardInstalled") || !data.ContainsKey("Protected") ||
                    !data.ContainsKey("UpdatedAtUtc") || !data.ContainsKey("ProcessId") ||
                    !(data["ProcessId"] is int) ||
                    !(data["State"] is string) || !(data["GuardInstalled"] is bool) || !(data["Protected"] is bool) ||
                    !(data["UpdatedAtUtc"] is string)) return new ClientView("status_invalid");
                string connectionError = "none";
                if (version >= 2)
                {
                    if (!data.ContainsKey("ConnectionError") || !(data["ConnectionError"] is string) ||
                        !Regex.IsMatch((string)data["ConnectionError"], @"\A(?:none|route_or_identity|interface_missing|route_mismatch|route_loopback|route_interface|route_source|route_prefix|route_fields_[0-9]{1,3}|projection_missing|native_[0-9]{1,5}|path_unavailable|path_connection_failed|path_stalled|path_response_invalid|path_different_policy|device_access_revoked|device_no_services|service_fault|(?:policy|services|release)_[a-z_]{1,40}|enrollment_[a-z_]{1,40})\z")) return new ClientView("status_invalid");
                    connectionError = (string)data["ConnectionError"];
                }
                if (servicePid == 0 || (int)data["ProcessId"] <= 0 || (int)data["ProcessId"] != servicePid)
                    return new ClientView("status_process_mismatch");
                DateTime updated;
                if (!DateTime.TryParseExact((string)data["UpdatedAtUtc"], "o", CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out updated) || updated.Kind != DateTimeKind.Utc)
                    return new ClientView("status_invalid");
                if (now.Kind != DateTimeKind.Utc || now - updated > TimeSpan.FromSeconds(15) || updated - now > TimeSpan.FromSeconds(2))
                    return new ClientView("status_stale");
                string state = (string)data["State"];
                bool guard = (bool)data["GuardInstalled"];
                // "Protected" and the state must say the same thing, and a
                // protected status carries no error: anything else is not ours.
                if ((bool)data["Protected"] != (state == "protected") || (state == "protected" && connectionError != "none") ||
                    (state != "blocked" && state != "enrollment_required" && state != "error" && state != "access_closed" &&
                    state != "registration_pending" && state != "registration_error" && state != "connecting" &&
                    state != "tunnel_connected" && state != "connection_error" && state != "protected") ||
                    ((state == "blocked" || state == "connecting" || state == "tunnel_connected" || state == "connection_error" || state == "protected") && !guard) || (state == "enrollment_required" && guard))
                    return new ClientView("status_invalid");
                // Older statuses never carried protection; they cannot claim it.
                if (version < 3) return new ClientView(state == "protected" ? "status_invalid" : state, guard, connectionError);
                object[] listed = data.ContainsKey("Services") ? data["Services"] as object[] : null;
                object[] offered = data.ContainsKey("Available") ? data["Available"] as object[] : null;
                object[] warned = data.ContainsKey("Warnings") ? data["Warnings"] as object[] : null;
                if (warned == null || warned.Length > 8 || warned.Any(item => !(item is string) || !Regex.IsMatch((string)item, @"\A(?:proxy|vpn|open|full|idle)\z")) ||
                    !(data.ContainsKey("Release") && data["Release"] is string) ||
                    !Regex.IsMatch((string)data["Release"], @"\A(?:[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4})?\z") ||
                    listed == null || listed.Length > 64 || offered == null || offered.Length > 64 ||
                    offered.Any(item => !(item is string) || !Regex.IsMatch((string)item, @"\A[a-z0-9][a-z0-9_-]{0,47}\z")) || !(data.ContainsKey("Domains") && data["Domains"] is int) ||
                    !(data.ContainsKey("Revision") && data["Revision"] is int) || !(data.ContainsKey("Wanted") && data["Wanted"] is bool) ||
                    (int)data["Domains"] < 0 || (int)data["Revision"] < 0 ||
                    listed.Any(item => !(item is string) || !Regex.IsMatch((string)item, @"\A[a-z0-9][a-z0-9_-]{0,47}\z")) ||
                    ((state == "protected" || state == "tunnel_connected") && !(bool)data["Wanted"]))
                    return new ClientView("status_invalid");
                string server = "", ipText = "", servicesSubnet = "", tunnelSubnet = "";
                if (version >= 4) {
                    foreach (string key in new[] { "ServerName", "ServerIP", "ServicesSubnet", "TunnelSubnet" })
                        if (!data.ContainsKey(key) || !(data[key] is string)) return new ClientView("status_invalid");
                    server = (string)data["ServerName"]; ipText = (string)data["ServerIP"];
                    servicesSubnet = (string)data["ServicesSubnet"]; tunnelSubnet = (string)data["TunnelSubnet"];
                    System.Net.IPAddress ip;
                    if ((server != "" && (server.Length > 253 || !Regex.IsMatch(server, @"\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z"))) ||
                        (ipText != "" && (!System.Net.IPAddress.TryParse(ipText, out ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork || ip.ToString() != ipText)) ||
                        !ValidNetwork(servicesSubnet) || !ValidNetwork(tunnelSubnet)) return new ClientView("status_invalid");
                }
                var entries = new List<ServiceChoice>();
                bool choicePending = false;
                if (version >= 5)
                {
                    object[] items = data.ContainsKey("Entries") ? data["Entries"] as object[] : null;
                    if (items == null || items.Length > 64 || !data.ContainsKey("ChoicePending") || !(data["ChoicePending"] is bool))
                        return new ClientView("status_invalid");
                    choicePending = (bool)data["ChoicePending"];
                    var seen = new HashSet<string>(StringComparer.Ordinal);
                    foreach (object item in items)
                    {
                        var entry = item as Dictionary<string, object>;
                        if (entry == null || entry.Count != 6) return new ClientView("status_invalid");
                        object id, label, required, on, closed, choose;
                        if (!entry.TryGetValue("Id", out id) || !(id is string) || !Regex.IsMatch((string)id, @"\A[a-z0-9][a-z0-9_-]{0,47}\z") || !seen.Add((string)id) ||
                            !entry.TryGetValue("Label", out label) || !(label is string) || ((string)label).Length < 1 || ((string)label).Length > 64 ||
                            ((string)label).Any(c => Char.IsControl(c) || c == '<' || c == '>') ||
                            !entry.TryGetValue("Required", out required) || !(required is bool) || !entry.TryGetValue("On", out on) || !(on is bool) ||
                            !entry.TryGetValue("Closed", out closed) || !(closed is bool) || !entry.TryGetValue("ChooseClosed", out choose) || !(choose is bool) ||
                            ((bool)required && !(bool)on))
                            return new ClientView("status_invalid");
                        entries.Add(new ServiceChoice { Id = (string)id, Label = (string)label, Required = (bool)required, On = (bool)on,
                            Closed = (bool)closed, ChooseClosed = (bool)choose });
                    }
                }
                OwnStatus own = null;
                // Version 6 carries the person's own addresses, null where not allowed.
                if (version == 6 && !data.ContainsKey("Own")) return new ClientView("status_invalid");
                if (version == 6 && data["Own"] != null)
                {
                    own = ReadOwn(data["Own"] as Dictionary<string, object>);
                    if (own == null) return new ClientView("status_invalid");
                }
                return new ClientView(state, guard, connectionError, listed.Cast<string>().ToArray(), (int)data["Domains"], (int)data["Revision"], (bool)data["Wanted"], offered.Cast<string>().ToArray())
                    { Release = (string)data["Release"], Warnings = warned.Cast<string>().ToArray(), ServerName = server, ServerIP = ipText, ServicesSubnet = servicesSubnet, TunnelSubnet = tunnelSubnet,
                      Entries = entries.ToArray(), ChoicePending = choicePending, Own = own };
            }
            catch (ArgumentException) { return new ClientView("status_invalid"); }
            catch (InvalidOperationException) { return new ClientView("status_invalid"); }
        }

        // The own list in the exact shape the service writes it, or null.
        private static OwnStatus ReadOwn(Dictionary<string, object> data)
        {
            if (data == null || data.Count != 6) return null;
            object limit, ports, domains, networks, pending, answer;
            if (!data.TryGetValue("Limit", out limit) || !(limit is int) || (int)limit < 1 || (int)limit > 32 ||
                !data.TryGetValue("Ports", out ports) || !(ports is object[]) || ((object[])ports).Length < 1 || ((object[])ports).Length > 16 ||
                ((object[])ports).Any(port => !(port is int) || (int)port < 1 || (int)port > 65535) ||
                !data.TryGetValue("Domains", out domains) || !(domains is object[]) || !data.TryGetValue("Networks", out networks) || !(networks is object[]) ||
                ((object[])domains).Length + ((object[])networks).Length > 32 ||
                ((object[])domains).Concat((object[])networks).Any(item => !(item is string) || OwnAddresses.Input((string)item) == null) ||
                !data.TryGetValue("Pending", out pending) || !(pending is bool) ||
                !data.TryGetValue("Answer", out answer) || !(answer is string) || !Regex.IsMatch((string)answer, @"\A(?:|refused|not_allowed|too_often)\z"))
                return null;
            return new OwnStatus { Limit = (int)limit, Ports = ((object[])ports).Cast<int>().ToArray(), Domains = ((object[])domains).Cast<string>().ToArray(),
                Networks = ((object[])networks).Cast<string>().ToArray(), Pending = (bool)pending, Answer = (string)answer };
        }

        // Lines the service wrote, taken only in the shape it writes them.
        private static string[] ReadFaults(string path)
        {
            try
            {
                if (!File.Exists(path) || !TrustedFile(path) || new FileInfo(path).Length > 16384) return new string[0];
                return File.ReadAllLines(path, new UTF8Encoding(false, true))
                    .Where(line => Regex.IsMatch(line, @"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z [a-z]{1,16} [A-Za-z0-9]{1,64} [A-Za-z0-9 ._-]{0,100}\z"))
                    .Reverse().Take(40).Reverse().ToArray();
            }
            catch (IOException) { return new string[0]; }
            catch (UnauthorizedAccessException) { return new string[0]; }
            catch (ArgumentException) { return new string[0]; }
        }

        private static bool TrustedFile(string path)
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return false;
            var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            var users = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
            var security = new FileInfo(path).GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access);
            var owner = (SecurityIdentifier)security.GetOwner(typeof(SecurityIdentifier));
            if ((!owner.Equals(administrators) && !owner.Equals(system)) || !security.AreAccessRulesProtected) return false;
            var granted = new HashSet<string>();
            foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType != AccessControlType.Allow || rule.IsInherited) return false;
                if (rule.IdentityReference.Equals(administrators) || rule.IdentityReference.Equals(system))
                {
                    if (rule.FileSystemRights != FileSystemRights.FullControl) return false;
                }
                else if (!rule.IdentityReference.Equals(users) ||
                    (rule.FileSystemRights & ~(FileSystemRights.Read | FileSystemRights.Synchronize)) != 0 ||
                    (rule.FileSystemRights & FileSystemRights.Read) != FileSystemRights.Read) return false;
                granted.Add(rule.IdentityReference.Value);
            }
            return granted.Count == 3;
        }

        private static class Native
        {
            [StructLayout(LayoutKind.Sequential)] internal struct Status
            {
                internal uint Type, State, Accepted, Win32ExitCode, ServiceExitCode, CheckPoint, WaitHint, Process, Flags;
            }
            [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
            internal static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
            [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
            internal static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
            [DllImport("advapi32.dll", SetLastError = true)]
            internal static extern bool QueryServiceStatusEx(IntPtr service, uint level, out Status status, uint bytes, out uint required);
            [DllImport("advapi32.dll")] internal static extern bool CloseServiceHandle(IntPtr handle);
        }
    }
}
