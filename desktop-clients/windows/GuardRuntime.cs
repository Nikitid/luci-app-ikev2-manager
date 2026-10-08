using System;
using System.Diagnostics;
using System.Threading;
using System.Linq;
using System.Net;

namespace IkeV2Manager.Client
{
    public sealed class ClientStatus
    {
        public int Version { get { return 3; } }
        public string State { get; internal set; }
        public bool GuardInstalled { get; internal set; }
        // True only while every gate holds at once: persistent denials, the
        // owned tunnel, the selected routes through it, and the router's fresh
        // word that its required path is in effect for this tunnel address.
        public bool Protected { get; internal set; }
        public string UpdatedAtUtc { get; internal set; }
        public int ProcessId { get; internal set; }
        public string ConnectionError { get; internal set; }
        // What the device was assigned: service names and counts, no addresses.
        public string[] Services { get; internal set; }
        public int Domains { get; internal set; }
        public int Revision { get; internal set; }
        public bool Wanted { get; internal set; }
        public string[] Available { get; internal set; }
        // The router's release, or empty while unknown.
        public string Release { get; internal set; }
        // Conditions on this computer under which a selected service can be
        // reached around the tunnel by a program that does not use the
        // system's own routes and names. Named, not acted on.
        public string[] Warnings { get; internal set; }
    }

    public sealed class GuardRuntime : IDisposable
    {
        private readonly object gate = new object();
        private GuardStore store;
        private WfpGuard guard;
        private Timer heartbeat;
        private bool disposed;
        private bool healthy;
        private bool synchronizationFailed;
        // The router knows the device and does not let it in: not enabled yet
        // by the administrator, or revoked. Told apart from a fault.
        private bool accessClosed;
        private readonly bool systemIntegration;
        private volatile bool registrationComplete, connectionWanted;
        private int connectionRequest, appliedConnectionRequest;
        private OwnedRasConnection connection;
        private OwnedTunnelRoutes routes;
        private DateTime retryConnectionAt;
        private DateTime routeDeadline;
        private string connectionState = "blocked";
        private string connectionError = "none";
        private ulong permittedInterface;
        private DateTime readyUntil;
        private DeviceServices assigned;
        private bool namesApplied = true;
        private DateTime nextReadinessAt;
        private bool appliedFull;
        private ServerPath serverPath;
        private bool dialPlain, dialedThroughPath, dialSucceeded;
        private int pathMisses;
        // The server held to its real address in this program's hosts block.
        private HostEntry serverHeld;
        private string lookedFor;
        private DateTime lookAgainAt;
        private bool noServices;
        private string release = "";
        private string[] warnings = new string[0];
        // Why the last registration step did not go through. It used to be
        // published once and overwritten two seconds later, so a registration
        // that could not reach the router looked like one that was waiting.
        private string registrationError = "none";
        private string publishedState = "starting";
        private readonly DateTime startedAt = DateTime.UtcNow;

        // A configured proxy carries a program's requests by name to the proxy,
        // which then reaches the service from wherever the proxy is: neither
        // the tunnel's routes nor its names apply. The same goes for a per-user
        // proxy script. This is told to the user; it cannot be closed here.
        internal static string[] Observe()
        {
            var found = new System.Collections.Generic.List<string>();
            try
            {
                using (var machine = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections"))
                {
                    var settings = machine == null ? null : machine.GetValue("WinHttpSettings") as byte[];
                    if (settings != null && settings.Length > 8 && (settings[8] & 2) != 0) found.Add("proxy");
                }
                foreach (string user in Microsoft.Win32.Registry.Users.GetSubKeyNames())
                {
                    if (!user.StartsWith("S-1-5-21-", StringComparison.Ordinal) || user.EndsWith("_Classes", StringComparison.Ordinal)) continue;
                    using (var key = Microsoft.Win32.Registry.Users.OpenSubKey(user + @"\Software\Microsoft\Windows\CurrentVersion\Internet Settings"))
                    {
                        if (key == null) continue;
                        object enabled = key.GetValue("ProxyEnable"), script = key.GetValue("AutoConfigURL");
                        if ((enabled is int && (int)enabled != 0) || (script is string && ((string)script).Length != 0))
                            if (!found.Contains("proxy")) found.Add("proxy");
                    }
                }
            }
            catch (System.Security.SecurityException) { }
            catch (UnauthorizedAccessException) { }
            catch (System.IO.IOException) { }
            if (AnotherTunnelCarriesTheInternet()) found.Add("vpn");
            return found.ToArray();
        }

        // Windows 11 and later ask a name server over HTTPS when told to.
        private static bool EncryptedNames()
        {
            try
            {
                using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    int build;
                    return key != null && Int32.TryParse(key.GetValue("CurrentBuild") as string, out build) && build >= 22000;
                }
            }
            catch (System.Security.SecurityException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }

        // Another VPN that took the route to the Internet also takes the
        // names: this client's services then fail to open rather than go
        // around, and the user is told why. Seen as Windows sees it - the
        // adapter the system would send an ordinary address through is
        // neither a wired, wireless or mobile one nor this client's own.
        internal static bool AnotherTunnelCarriesTheInternet()
        {
            try
            {
                var chosen = RouteObservation.Read(IPAddress.Parse("1.1.1.1"));
                if (chosen.IsLoopback || chosen.Source == null) return false;
                foreach (var adapter in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (!adapter.GetIPProperties().UnicastAddresses.Any(address => address.Address.Equals(chosen.Source))) continue;
                    if (adapter.Name.StartsWith("Waypoint", StringComparison.Ordinal)) return false;
                    return !ServerPath.Physical(adapter);
                }
            }
            catch (System.ComponentModel.Win32Exception) { }
            catch (InvalidOperationException) { }
            return false;
        }

        public GuardRuntime(string storeName, bool enableSystemIntegration = false)
        {
            systemIntegration = enableSystemIntegration;
            try
            {
                store = new GuardStore(storeName);
                GuardReceipt plan = store.LoadPlan();
                if (plan != null) { guard = WfpGuard.Resume(plan); healthy = true; }
                store.LoadPolicyHistory();
                RestoreEnrollmentProtection();
                connectionWanted = systemIntegration && registrationComplete && store.LoadConnectionIntent();
                if (systemIntegration && guard != null && store.LoadVpnEntry() != Guid.Empty)
                {
                    // Nothing of a previous instance stays connected behind a
                    // status that is about to say "blocked".
                    var abandoned = ManagedVpnProfile.FromJournal(store.LoadPlan().Owner, store.LoadVpnEntry());
                    RasTunnel.Release(abandoned.EntryId, abandoned.Phonebook);
                }
                Publish(guard == null ? (EnrollmentRegistration.Load(store) == null ? "enrollment_required" : "registration_pending") : "blocked");
                // The router's readiness lasts five seconds; ask well inside that.
                heartbeat = new Timer(Tick, null, 2000, 2000);
            }
            catch
            {
                if (store != null) { try { Publish("error"); } catch { } }
                if (guard != null) guard.Dispose();
                if (store != null) store.Dispose();
                throw;
            }
        }

        public void BeginEnrollment(Uri endpoint, string invitation)
        {
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("GuardRuntime");
                if (store.LoadPolicyHistory() != null) throw new InvalidOperationException("Client is already configured");
                EnrollmentRegistration.Begin(store, endpoint, invitation);
                Publish("registration_pending");
            }
        }

        public bool HasPendingEnrollment()
        {
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("GuardRuntime");
                var registration = EnrollmentRegistration.Load(store);
                return registration != null && registration.Policy == null;
            }
        }

        public bool HasRegistration()
        {
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("GuardRuntime");
                return EnrollmentRegistration.Load(store) != null;
            }
        }

        public void RefreshPolicy()
        {
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("GuardRuntime");
                try
                {
                    var registration = EnrollmentRegistration.Load(store);
                    if (registration == null || registration.Policy == null)
                        throw new InvalidOperationException("Completed registration required");
                    var previous = store.LoadPolicyHistory();
                    var endpoint = new UriBuilder(registration.ClaimEndpoint) { Path = "/client/v1/policy" }.Uri;
                    ClientPolicy next;
                    try { next = PolicyTransportClient.Fetch(endpoint, registration.DeviceToken, previous); }
                    catch (PolicyFetchException unanswered)
                    {
                        // A poll that got no answer changes nothing: the
                        // committed policy stays in force, and the router's
                        // readiness remains the live gate on permission.
                        if (unanswered.Code != "policy_connection_failed") throw;
                        return;
                    }
                    try { assigned = PolicyTransportClient.FetchServices(endpoint, registration.DeviceToken, registration.Id); }
                    catch (PolicyFetchException) { }
                    try { release = PolicyTransportClient.FetchRelease(endpoint, registration.DeviceToken); }
                    catch (PolicyFetchException) { }
                    warnings = Observe();
                    // Another VPN is worth a word only where it can still get in
                    // the way: with names asked over HTTPS it does not.
                    if (assigned != null && assigned.NamesHttps && EncryptedNames()) warnings = warnings.Where(w => w != "vpn").ToArray();
                    if (assigned != null && !assigned.Block) warnings = warnings.Concat(new[] { "open" }).ToArray();
                    if (assigned != null && assigned.Full) warnings = warnings.Concat(new[] { "full" }).ToArray();
                    if (next.Canonical != previous.Current.Canonical) StagePolicy(next);
                    else EnsureProfile(next);
                    synchronizationFailed = false; accessClosed = false; noServices = false;
                    AdvanceConnection();
                    Publish(connectionState);
                }
                catch (Exception refusal)
                {
                    synchronizationFailed = true;
                    store.RecordFault("policy", refusal);
                    var named = refusal as PolicyFetchException;
                    // Without a single service there is nothing to hold names for:
                    // they are let go, and come back with the first service.
                    noServices = named != null && named.Code == "device_no_services";
                    if (noServices)
                    {
                        // Nothing is assigned any more; the router still says
                        // which release it runs, so a newer program is offered.
                        assigned = null;
                        try
                        {
                            var known = EnrollmentRegistration.Load(store);
                            if (known != null && known.Policy != null)
                                release = PolicyTransportClient.FetchRelease(new UriBuilder(known.ClaimEndpoint) { Path = "/client/v1/policy" }.Uri, known.DeviceToken);
                        }
                        catch (Exception) { }
                    }
                    accessClosed = noServices || (named != null && named.Code == "device_access_revoked");
                    warnings = noServices ? new[] { "idle" } : warnings.Where(w => w != "idle").ToArray();
                    try { permittedInterface = 0; if (guard != null) guard.Block(); }
                    catch { Environment.FailFast("Client guard could not close after synchronization failure"); }
                    try { Publish(accessClosed ? "access_closed" : "error"); } catch { }
                    CloseConnection();
                    throw;
                }
            }
        }

        // The administrator asked this computer what is going on. It answers
        // by itself: the state this service holds, its journal of failures and
        // the network adapters as the system lists them. No names of sites,
        // programs or files, and nothing the user did.
        public void AnswerReportRequest()
        {
            lock (gate)
            {
                if (disposed) return;
                try
                {
                    var registration = EnrollmentRegistration.Load(store);
                    if (registration == null || registration.Policy == null) return;
                    var endpoint = new UriBuilder(registration.ClaimEndpoint) { Path = "/client/v1/policy" }.Uri;
                    if (!PolicyTransportClient.ReportWanted(endpoint, registration.DeviceToken)) return;
                    PolicyTransportClient.SendReport(endpoint, registration.DeviceToken, BuildReport());
                }
                catch (Exception fault) { store.RecordFault("report", fault); }
            }
        }

        internal string BuildReport()
        {
            int domains = 0, revision = 0;
            try
            {
                var history = guard == null ? null : store.LoadPolicyHistory();
                if (history != null) { domains = history.Current.Resources.Select(r => r.Domain).Distinct().Count(); revision = history.Current.Revision; }
            }
            catch (InvalidOperationException) { }
            catch (ArgumentException) { }
            var about = PolicyTransportClient.Describe();
            Func<string, string> told = key => about.ContainsKey(key) ? about[key] : "";
            var report = new System.Collections.Generic.Dictionary<string, object> {
                { "version", 1 }, { "platform", "windows" }, { "client", told("X-Client-Version") }, { "system", told("X-Client-System") },
                { "host", told("X-Client-Host") }, { "created_at", DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") },
                { "service_uptime_seconds", (long)(DateTime.UtcNow - startedAt).TotalSeconds },
                { "system_uptime_seconds", (long)(Stopwatch.GetTimestamp() / Stopwatch.Frequency) },
                { "state", publishedState }, { "connection_state", connectionState }, { "connection_error", connectionError },
                { "registration_error", registrationError }, { "connection_wanted", connectionWanted },
                { "guard_installed", healthy }, { "tunnel_permitted", permittedInterface != 0 },
                { "synchronization_failed", synchronizationFailed }, { "access_closed", accessClosed }, { "no_services", noServices },
                { "mode", assigned != null && assigned.Full ? "full" : "services" }, { "block_without_tunnel", assigned == null || assigned.Block },
                { "names_applied", namesApplied }, { "names_https", assigned != null && assigned.NamesHttps }, { "warnings", warnings },
                { "services", assigned == null ? new string[0] : assigned.Selected.Take(64).ToArray() },
                { "domains", domains }, { "policy_revision", revision }, { "router_release", release },
                { "faults", store.ReadFaults() }, { "adapters", Adapters() } };
            string text = new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(report);
            if (System.Text.Encoding.UTF8.GetByteCount(text) > PolicyTransportClient.ReportLimit)
            {
                report["adapters"] = new object[0];
                text = new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(report);
            }
            return text;
        }

        // What another VPN, a virtual adapter or a changed resolver looks like
        // from here: the adapters that are up, as the system names them.
        private static object[] Adapters()
        {
            var found = new System.Collections.Generic.List<object>();
            try
            {
                foreach (var adapter in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (adapter.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback ||
                        adapter.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                    var properties = adapter.GetIPProperties();
                    Func<string, string> plain = value => { string kept = System.Text.RegularExpressions.Regex.Replace(value ?? "", @"[^\p{L}\p{N} ._()#-]", ""); return kept.Length > 80 ? kept.Substring(0, 80) : kept; };
                    found.Add(new System.Collections.Generic.Dictionary<string, object> {
                        { "name", plain(adapter.Name) }, { "description", plain(adapter.Description) },
                        { "type", adapter.NetworkInterfaceType.ToString() },
                        { "addresses", properties.UnicastAddresses.Select(a => a.Address.ToString()).Take(8).ToArray() },
                        { "default_route", properties.GatewayAddresses.Any(g => !g.Address.Equals(IPAddress.Any) && !g.Address.Equals(IPAddress.IPv6Any)) },
                        { "dns", properties.DnsAddresses.Select(a => a.ToString()).Take(6).ToArray() } });
                    if (found.Count == 24) break;
                }
            }
            catch (System.Net.NetworkInformation.NetworkInformationException) { }
            return found.ToArray();
        }

        public bool ContinueEnrollment()
        {
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("GuardRuntime");
                try
                {
                    var registration = EnrollmentRegistration.Resume(store);
                    registrationError = "none";
                    if (registration.Policy == null) { Publish("registration_pending"); return false; }
                    RestoreEnrollmentProtection();
                    return true;
                }
                catch (Exception refusal)
                {
                    var named = refusal as EnrollmentException;
                    registrationError = named != null ? named.Code : "enrollment_internal";
                    try { permittedInterface = 0; if (guard != null) guard.Block(); }
                    catch { Environment.FailFast("Client guard could not close after enrollment failure"); }
                    try { Publish("registration_error"); } catch { }
                    throw;
                }
            }
        }

        private void RestoreEnrollmentProtection()
        {
            var registration = EnrollmentRegistration.Load(store);
            if (registration == null || registration.Policy == null) return;
            registrationComplete = true;
            var history = store.LoadPolicyHistory();
            if (history == null || history.Current.Revision <= registration.Policy.Revision)
                StagePolicy(registration.Policy);
            else
            {
                // Later authenticated updates can supersede the bootstrap policy.
                PolicyHistory.Begin(registration.Policy).Propose(history.Current);
                EnsureProfile(history.Current);
            }
        }

        private void EnsureProfile(ClientPolicy policy)
        {
            if (!systemIntegration) return;
            if (guard == null) throw new InvalidOperationException("Guard required before VPN provisioning");
            guard.VerifyProtection();
            HoldServer(policy.ServerAddress);
            bool full = assigned != null && assigned.Full;
            // This runs every half-minute. While the profile, its routes and the
            // name rules are what they should be there is nothing to put right,
            // and the tunnel keeps its permission: taking it away for the
            // length of the check used to stop the services for about a second
            // every half-minute.
            if (InPlace(policy, full)) return;
            ClosePermission();
            SyncNames(policy);
            var profile = ManagedVpnProfile.Ensure(policy, store.LoadPlan().Owner, store.LoadVpnEntry(), full);
            // A changed mode takes effect on a new connection.
            if (full != appliedFull) { appliedFull = full; CloseConnection(); retryConnectionAt = DateTime.MinValue; }
            store.SaveVpnEntry(profile.EntryId);
        }

        private static bool Reaches(string address, int port)
        {
            try
            {
                using (var client = new System.Net.Sockets.TcpClient())
                {
                    var pending = client.BeginConnect(address, port, null, null);
                    return pending.AsyncWaitHandle.WaitOne(1500) && client.Connected;
                }
            }
            catch (System.Net.Sockets.SocketException) { return false; }
            catch (ObjectDisposedException) { return false; }
        }

        // Another VPN often answers every name with an address of its own
        // making. Dialing the server by such an address builds the tunnel
        // inside that VPN, or nowhere. So the server's real address is
        // remembered whenever it is seen, and while another VPN answers in its
        // place the name is held to that address in this program's own hosts
        // block - only then, and not on the attempts that go the plain way.
        private void HoldServer(string server)
        {
            HostEntry wanted = null;
            try
            {
                IPAddress[] seen;
                try { seen = Dns.GetHostAddresses(server).Where(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork).ToArray(); }
                catch (System.Net.Sockets.SocketException) { seen = new IPAddress[0]; }
                string[] known = store.LoadServerAddresses();
                bool own = serverHeld != null && seen.Length == 1 && seen[0].ToString() == serverHeld.address;
                if (!own && seen.Length != 0 && seen.All(ServerPath.Public))
                {
                    var fresh = seen.Select(a => a.ToString()).OrderBy(a => a, StringComparer.Ordinal).Take(4).ToArray();
                    if (!fresh.SequenceEqual(known)) { store.SaveServerAddresses(fresh); known = fresh; }
                }
                else if (!dialPlain && known.Length != 0 && AnotherTunnelCarriesTheInternet() && (own || !seen.Any(ServerPath.Public)))
                    wanted = new HostEntry { address = known[0], domain = server };
            }
            catch (InvalidOperationException) { wanted = null; }
            catch (ArgumentException) { wanted = null; }
            catch (System.IO.IOException) { wanted = null; }
            if ((wanted == null) == (serverHeld == null) && (wanted == null || wanted.address == serverHeld.address)) return;
            var previous = serverHeld; serverHeld = wanted;
            try
            {
                if (namesApplied) SystemHosts.Apply(store, store.LoadPolicyHistory(), serverHeld); else SystemHosts.Keep(store, serverHeld);
            }
            // A hosts file that cannot take the entry leaves things as they were.
            catch (InvalidOperationException) { serverHeld = previous; }
            catch (ArgumentException) { serverHeld = previous; }
            catch (System.IO.IOException) { serverHeld = previous; }
            catch (UnauthorizedAccessException) { serverHeld = previous; }
        }

        // Looks, changes nothing. Any doubt is "no": the caller then closes the
        // permission and puts everything right the long way.
        private bool InPlace(ClientPolicy policy, bool full)
        {
            try
            {
                bool want = WantNames();
                if (want != namesApplied || full != appliedFull) return false;
                // What was asked for is the same as when everything was last
                // found in place: the system itself is then looked at only
                // every five minutes. Looking costs two PowerShell processes,
                // which every half-minute is a steady load on a laptop.
                string asked = policy.Canonical + "|" + full + "|" + want + "|" + (assigned != null && assigned.NamesHttps) + "|" + (serverHeld == null ? "" : serverHeld.address);
                if (asked == lookedFor && DateTime.UtcNow < lookAgainAt) return true;
                lookedFor = null;
                Guid owner = store.LoadPlan().Owner, entry = store.LoadVpnEntry();
                if (entry == Guid.Empty) return false;
                string https = assigned != null && assigned.NamesHttps ? policy.ServerAddress : null;
                bool names = want
                    ? SystemHosts.InPlace(store, store.LoadPolicyHistory(), serverHeld) && ManagedVpnProfile.NamesInPlace(owner, PolicyHistory.NamesResolver(policy.VirtualSubnet),
                        store.LoadPolicyHistory().Current.Resources.Select(r => r.Domain), https)
                    : SystemHosts.InPlace(store, null, serverHeld) && ManagedVpnProfile.NamesAbsent(owner);
                if (!(names && ManagedVpnProfile.InPlace(policy, owner, entry, full))) return false;
                lookedFor = asked; lookAgainAt = DateTime.UtcNow.AddMinutes(5);
                return true;
            }
            catch (InvalidOperationException) { return false; }
            catch (ArgumentException) { return false; }
            catch (System.IO.IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }

        // Names point into the tunnel always, unless the administrator let
        // this device's services go the ordinary way while the tunnel is
        // down: then they point there only while access is confirmed.
        private bool WantNames() { return !noServices && (assigned == null || assigned.Block || connectionState == "protected"); }

        private void SyncNames(ClientPolicy policy)
        {
            bool want = WantNames();
            if (want)
            {
                SystemHosts.Apply(store, store.LoadPolicyHistory(), serverHeld);
                // Every name under a selected domain is asked through the tunnel;
                // the denials already hold the address that answers.
                ManagedVpnProfile.ApplyNames(store.LoadPlan().Owner, PolicyHistory.NamesResolver(policy.VirtualSubnet),
                    store.LoadPolicyHistory().Current.Resources.Select(r => r.Domain),
                    assigned != null && assigned.NamesHttps ? policy.ServerAddress : null);
            }
            else
            {
                SystemHosts.Keep(store, serverHeld);
                ManagedVpnProfile.RemoveNames(store.LoadPlan().Owner);
            }
            namesApplied = want;
        }

        public void RequestConnection(bool wanted)
        {
            if (!systemIntegration || (wanted && !registrationComplete)) throw new InvalidOperationException("Registered system integration required");
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("GuardRuntime");
                store.SaveConnectionIntent(wanted);
            }
            connectionWanted = wanted;
            Interlocked.Increment(ref connectionRequest);
        }

        // Every path that withdraws permission goes through here, so the status
        // can never say "protected" over a guard that is closed.
        private void ClosePermission()
        {
            permittedInterface = 0;
            if (guard != null) guard.Block();
        }

        private void CloseConnection()
        {
            permittedInterface = 0;
            if (routes != null) { routes.Dispose(); routes = null; }
            // Let go even when closing fails: the next attempt starts by
            // ending whatever is still connected on the managed entry.
            var closing = connection; connection = null;
            if (closing != null) closing.Dispose();
            if (serverPath != null) { serverPath.Dispose(); serverPath = null; }
        }

        private void AdvanceConnection()
        {
            if (!systemIntegration) return;
            if (appliedConnectionRequest != Volatile.Read(ref connectionRequest))
            {
                appliedConnectionRequest = Volatile.Read(ref connectionRequest);
                retryConnectionAt = DateTime.MinValue;
            }
            if (!connectionWanted || synchronizationFailed)
            {
                ClosePermission();
                CloseConnection(); connectionState = "blocked"; connectionError = "none"; return;
            }
            try
            {
                if (guard == null || !healthy) throw new InvalidOperationException("Persistent protection required");
                if (connection == null)
                {
                    if (DateTime.UtcNow < retryConnectionAt) return;
                    ClosePermission(); guard.VerifyProtection();
                    var registration = EnrollmentRegistration.Load(store);
                    var profile = ManagedVpnProfile.FromJournal(store.LoadPlan().Owner, store.LoadVpnEntry());
                    RasTunnel.Release(profile.EntryId, profile.Phonebook);
                    // With another VPN in the way the server is dialed through
                    // the physical network. Should that not reach it, the next
                    // attempt goes the way Windows chooses, and so on in turn.
                    if (serverPath != null) { serverPath.Dispose(); serverPath = null; }
                    HoldServer(store.LoadPolicyHistory().Current.ServerAddress);
                    if (!dialPlain) serverPath = ServerPath.Pin(store.LoadPolicyHistory().Current.ServerAddress);
                    dialedThroughPath = serverPath != null || serverHeld != null;
                    dialSucceeded = false; pathMisses = 0;
                    connection = OwnedRasConnection.Begin(profile, registration.Id, registration.Password);
                    routeDeadline = DateTime.MinValue;
                }
                // Every two seconds, well inside the route's lifetime.
                if (serverPath != null) serverPath.Renew();
                var observed = connection.Observe();
                if (observed == null) { ClosePermission(); connectionState = "connecting"; return; }
                // The fixed address of each selected domain, the address that
                // answers names, and the network names are answered from.
                var selected = store.LoadPolicyHistory().Current;
                var selectedPrefixes = selected.Resources.Select(r => r.Address)
                    .Concat(new[] { PolicyHistory.NamesResolver(selected.VirtualSubnet), PolicyHistory.NamesRange(selected.VirtualSubnet) }).ToArray();
                if (routes != null && !routes.Matches(observed, selectedPrefixes)) { ClosePermission(); routes.Dispose(); routes = null; }
                if (routes == null) routes = new OwnedTunnelRoutes(observed, selectedPrefixes);
                routes.Verify(observed);
                if (routeDeadline == DateTime.MinValue) routeDeadline = DateTime.UtcNow.AddSeconds(10);
                foreach (string prefix in selectedPrefixes)
                {
                    IPAddress destination; byte prefixLength;
                    OwnedTunnelRoutes.ParsePrefix(prefix, out destination, out prefixLength);
                    var route = RouteObservation.Read(destination);
                    if (!route.Matches(observed, destination, prefixLength))
                    {
                        connectionError = route.IsLoopback ? "route_loopback" : route.InterfaceLuid != observed.InterfaceLuid ? "route_interface" :
                            !route.Source.Equals(observed.LocalAddress) ? "route_source" : "route_prefix";
                        // RAS completion can precede route publication. Keep
                        // persistent denials while Windows finishes configuring.
                        if (DateTime.UtcNow < routeDeadline) { ClosePermission(); connectionState = "connecting"; return; }
                        throw new InvalidOperationException("Selected route does not use the owned tunnel");
                    }
                }
                // The tunnel and its routes are ours. Permission still waits for
                // the router: it answers only for an SA it authenticated and
                // admitted, with its required exit and proxy in effect.
                // While access stands confirmed, the tunnel and its routes are
                // still checked every step above, but the router is asked
                // again only every few seconds: each question costs it a
                // process, and its own admission does not wait for ours.
                if (connectionState == "protected" && permittedInterface == observed.InterfaceLuid && DateTime.UtcNow < nextReadinessAt) return;
                connectionState = "tunnel_connected";
                var current = store.LoadPolicyHistory().Current;
                var enrolled = EnrollmentRegistration.Load(store);
                DeviceReadiness ready;
                try
                {
                    ready = PolicyTransportClient.FetchReadiness(
                        new UriBuilder(enrolled.ClaimEndpoint) { Path = "/client/v1/policy" }.Uri, enrolled.DeviceToken, observed.LocalAddress);
                    if (ready.Id != enrolled.Id || ready.Address != observed.LocalAddress.ToString() || ready.Revision != current.Revision)
                        throw new PolicyFetchException("path_different_policy");
                }
                catch (PolicyFetchException refusal)
                {
                    // One unanswered question is not a lost path: the router
                    // renews its word every two seconds and keeps its own
                    // admission for fifteen, so permission outlives a missed
                    // answer by less than that. A refusal that names this
                    // device or its policy ends it at once.
                    bool transient = refusal.Code == "path_unavailable" || refusal.Code == "path_connection_failed";
                    if (transient && permittedInterface == observed.InterfaceLuid && DateTime.UtcNow < readyUntil)
                    {
                        connectionState = "protected";
                        return;
                    }
                    // The tunnel stays; only permission goes. The next tick asks again.
                    ClosePermission();
                    connectionError = refusal.Code;
                    return;
                }
                if (permittedInterface != observed.InterfaceLuid)
                {
                    guard.AllowInterface(observed.InterfaceLuid);
                    permittedInterface = observed.InterfaceLuid;
                }
                readyUntil = DateTime.UtcNow.AddSeconds(20);
                nextReadinessAt = DateTime.UtcNow.AddSeconds(6);
                // The router's word says the tunnel is admitted; it is given
                // over the Internet and does not say that the tunnel still
                // carries anything. A tunnel whose outer path is gone - built
                // through another VPN that has since been switched off - would
                // stand "protected" and dead until the router gave up on it.
                // So the resolver inside the tunnel is reached as well; three
                // misses in a row end this connection and the next one is dialed.
                if (assigned != null && assigned.NamesHttps)
                {
                    string resolver = PolicyHistory.NamesResolver(current.VirtualSubnet);
                    if (Reaches(resolver, 443) || Reaches(resolver, 53)) pathMisses = 0;
                    else if (++pathMisses >= 3) { pathMisses = 0; throw new InvalidOperationException("Tunnel carries nothing"); }
                }
                dialSucceeded = true;
                connectionError = "none";
                connectionState = "protected";
            }
            catch (Exception error)
            {
                var native = error as NativeConnectionException;
                var system = error as System.ComponentModel.Win32Exception;
                var configuration = error as RouteConfigurationException;
                connectionError = native != null && native.Code <= 65535 ? "native_" + native.Code :
                    configuration != null ? "route_fields_" + configuration.Fields :
                    system != null && system.NativeErrorCode >= 0 && system.NativeErrorCode <= 65535 ? "native_" + system.NativeErrorCode :
                    error.Message == "IKEv2 interface cannot be identified uniquely" ? "interface_missing" :
                    error.Message == "Selected route does not use the owned tunnel" ? connectionError :
                    error.Message == "Native IKEv2 connection lost" ? "projection_missing" :
                    error.Message == "Tunnel carries nothing" ? "path_stalled" : "route_or_identity";
                store.RecordFault("connection", error);
                connectionState = "connection_error";
                retryConnectionAt = DateTime.UtcNow.AddSeconds(30);
                // A dial that never got through goes the other way next time; a
                // connection that worked and was lost later is dialed the same way.
                dialPlain = !dialSucceeded && dialedThroughPath;
                ClosePermission();
                CloseConnection();
            }
        }

        // Called only after the service authenticates a policy's enrolled source.
        // Staging installs denials before reconciling system mappings and
        // selected routes. It never grants traffic permission.
        public void StagePolicy(ClientPolicy policy)
        {
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("GuardRuntime");
                PolicyHistory previous = store.LoadPolicyHistory();
                PolicyHistory next = previous == null ? PolicyHistory.Begin(policy) : previous.Propose(policy);
                GuardReceipt plan = store.LoadPlan();
                // Denied outside the tunnel for good: every fixed address ever
                // assigned, the address that answers names and the whole
                // network names are answered from.
                var addresses = next.ProtectedAddresses()
                    .Concat(new[] { PolicyHistory.NamesResolver(policy.VirtualSubnet), PolicyHistory.NamesRange(policy.VirtualSubnet) }).ToArray();
                bool initial = plan == null;
                if (initial)
                    using (var planned = new WfpGuard(Guid.NewGuid(), addresses)) plan = planned.Receipt();
                else plan = WfpGuard.ExtendPlan(plan, addresses);
                healthy = false;
                try
                {
                    ClosePermission();
                    if (initial) store.SavePlan(plan); else store.ExtendPlan(plan);
                    if (guard != null) { guard.Dispose(); guard = null; }
                    guard = WfpGuard.Resume(plan);
                    store.SavePolicyHistory(next);
                    EnsureProfile(policy);
                    healthy = true;
                    Publish("blocked");
                }
                catch
                {
                    try { permittedInterface = 0; if (guard != null) guard.Block(); }
                    catch { Environment.FailFast("Client guard could not close after a failed policy update"); }
                    try { Publish("error"); } catch { }
                    throw;
                }
            }
        }

        private void Tick(object ignored)
        {
            lock (gate)
            {
                if (disposed) return;
                try
                {
                    if (guard != null) guard.VerifyProtection();
                    store.LoadPolicyHistory();
                    var registration = EnrollmentRegistration.Load(store);
                    healthy = guard != null;
                    AdvanceConnection();
                    if (systemIntegration && guard != null && registrationComplete && WantNames() != namesApplied)
                        SyncNames(store.LoadPolicyHistory().Current);
                    Publish(synchronizationFailed ? (accessClosed ? "access_closed" : "error") : guard == null ? (registration == null ? "enrollment_required" : "registration_pending") : connectionState);
                }
                catch (Exception fault)
                {
                    healthy = false;
                    store.RecordFault("tick", fault);
                    // A future permission owner must also close before publishing
                    // an error; failure to close cannot leave a live process.
                    try { permittedInterface = 0; if (guard != null) guard.Block(); }
                    catch { Environment.FailFast("Client guard could not close its permission session"); }
                    try { Publish("error"); } catch { }
                }
            }
        }

        private void Publish(string state)
        {
            int domains = 0, revision = 0;
            try
            {
                var history = guard == null ? null : store.LoadPolicyHistory();
                if (history != null)
                {
                    domains = history.Current.Resources.Select(r => r.Domain).Distinct().Count();
                    revision = history.Current.Revision;
                }
            }
            catch (InvalidOperationException) { }
            // A journal that cannot be read must not keep the status from being
            // written: stopping the service used to fail on it.
            catch (ArgumentException) { }
            publishedState = state;
            store.PublishStatus(new ClientStatus { State = state, GuardInstalled = healthy,
                Services = assigned == null ? new string[0] : assigned.Selected.Take(64).ToArray(),
                Available = assigned == null ? new string[0] : assigned.Available.Take(64).ToArray(),
                Domains = domains, Revision = revision, Wanted = connectionWanted, Release = release, Warnings = warnings,
                Protected = healthy && state == "protected" && permittedInterface != 0,
                ConnectionError = state == "registration_pending" || state == "registration_error" ? registrationError : connectionError,
                UpdatedAtUtc = DateTime.UtcNow.ToString("o", System.Globalization.CultureInfo.InvariantCulture),
                ProcessId = Process.GetCurrentProcess().Id });
        }

        public void Dispose()
        {
            lock (gate)
            {
                if (disposed) return;
                disposed = true;
                if (heartbeat != null) heartbeat.Dispose();
                try
                {
                    ClosePermission();
                    // A connection that will not close must not keep the
                    // service from stopping: permission is already withdrawn,
                    // and the next start ends whatever the entry still holds.
                    try { CloseConnection(); }
                    catch (Exception fault) { if (store != null) store.RecordFault("stop", fault); }
                    if (guard != null) guard.Dispose();
                    if (store != null) Publish("stopped");
                }
                finally { if (store != null) store.Dispose(); }
            }
        }
    }
}
