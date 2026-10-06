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
                    if (next.Canonical != previous.Current.Canonical) StagePolicy(next);
                    else EnsureProfile(next);
                    synchronizationFailed = false;
                    AdvanceConnection();
                    Publish(connectionState);
                }
                catch
                {
                    synchronizationFailed = true;
                    try { permittedInterface = 0; if (guard != null) guard.Block(); }
                    catch { Environment.FailFast("Client guard could not close after synchronization failure"); }
                    try { Publish("error"); } catch { }
                    CloseConnection();
                    throw;
                }
            }
        }

        public bool ContinueEnrollment()
        {
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("GuardRuntime");
                try
                {
                    var registration = EnrollmentRegistration.Resume(store);
                    if (registration.Policy == null) { Publish("registration_pending"); return false; }
                    RestoreEnrollmentProtection();
                    return true;
                }
                catch
                {
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
            ClosePermission(); guard.VerifyProtection();
            SystemHosts.Apply(store, store.LoadPolicyHistory());
            var profile = ManagedVpnProfile.Ensure(policy, store.LoadPlan().Owner, store.LoadVpnEntry());
            store.SaveVpnEntry(profile.EntryId);
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
            if (connection != null) { connection.Dispose(); connection = null; }
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
                    connection = OwnedRasConnection.Begin(profile, registration.Id, registration.Password);
                    routeDeadline = DateTime.MinValue;
                }
                var observed = connection.Observe();
                if (observed == null) { ClosePermission(); connectionState = "connecting"; return; }
                var selectedAddresses = store.LoadPolicyHistory().Current.Resources.Select(r => IPAddress.Parse(r.Address)).ToArray();
                if (routes != null && !routes.Matches(observed, selectedAddresses)) { ClosePermission(); routes.Dispose(); routes = null; }
                if (routes == null) routes = new OwnedTunnelRoutes(observed, selectedAddresses);
                routes.Verify(observed);
                if (routeDeadline == DateTime.MinValue) routeDeadline = DateTime.UtcNow.AddSeconds(10);
                foreach (var resource in store.LoadPolicyHistory().Current.Resources)
                {
                    var destination = IPAddress.Parse(resource.Address);
                    var route = RouteObservation.Read(destination);
                    if (!route.Matches(observed, destination))
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
                readyUntil = DateTime.UtcNow.AddSeconds(10);
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
                    error.Message == "Native IKEv2 connection lost" ? "projection_missing" : "route_or_identity";
                ClosePermission();
                CloseConnection();
                connectionState = "connection_error";
                retryConnectionAt = DateTime.UtcNow.AddSeconds(30);
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
                var addresses = next.ProtectedAddresses().Select(IPAddress.Parse).ToArray();
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
                    Publish(synchronizationFailed ? "error" : guard == null ? (registration == null ? "enrollment_required" : "registration_pending") : connectionState);
                }
                catch
                {
                    healthy = false;
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
            store.PublishStatus(new ClientStatus { State = state, GuardInstalled = healthy,
                Services = assigned == null ? new string[0] : assigned.Selected.Take(64).ToArray(),
                Available = assigned == null ? new string[0] : assigned.Available.Take(64).ToArray(),
                Domains = domains, Revision = revision, Wanted = connectionWanted,
                Protected = healthy && state == "protected" && permittedInterface != 0,
                ConnectionError = connectionError,
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
                    CloseConnection();
                    if (guard != null) guard.Dispose();
                    if (store != null) Publish("stopped");
                }
                finally { if (store != null) store.Dispose(); }
            }
        }
    }
}
