using System;
using System.Diagnostics;
using System.Threading;
using System.Linq;
using System.Net;

namespace IkeV2Manager.Client
{
    public sealed class ClientStatus
    {
        public int Version { get { return 2; } }
        public string State { get; internal set; }
        public bool GuardInstalled { get; internal set; }
        // No protected status until enrollment, routing and data-plane gates exist.
        public bool Protected { get { return false; } }
        public string UpdatedAtUtc { get; internal set; }
        public int ProcessId { get; internal set; }
        public string ConnectionError { get; internal set; }
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
                Publish(guard == null ? (EnrollmentRegistration.Load(store) == null ? "enrollment_required" : "registration_pending") : "blocked");
                heartbeat = new Timer(Tick, null, 5000, 5000);
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
                    var next = PolicyTransportClient.Fetch(endpoint, registration.DeviceToken, previous);
                    if (next.Canonical != previous.Current.Canonical) StagePolicy(next);
                    else EnsureProfile(next);
                    synchronizationFailed = false;
                    AdvanceConnection();
                    Publish(connectionState);
                }
                catch
                {
                    synchronizationFailed = true;
                    try { if (guard != null) guard.Block(); }
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
                    try { if (guard != null) guard.Block(); }
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
            guard.Block(); guard.VerifyProtection();
            SystemHosts.Apply(store, store.LoadPolicyHistory());
            var profile = ManagedVpnProfile.Ensure(policy, store.LoadPlan().Owner, store.LoadVpnEntry());
            store.SaveVpnEntry(profile.EntryId);
        }

        public void RequestConnection(bool wanted)
        {
            if (!systemIntegration || (wanted && !registrationComplete)) throw new InvalidOperationException("Registered system integration required");
            connectionWanted = wanted;
            Interlocked.Increment(ref connectionRequest);
        }

        private void CloseConnection()
        {
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
                if (guard != null) guard.Block();
                CloseConnection(); connectionState = "blocked"; connectionError = "none"; return;
            }
            try
            {
                if (guard == null || !healthy) throw new InvalidOperationException("Persistent protection required");
                if (connection == null)
                {
                    if (DateTime.UtcNow < retryConnectionAt) return;
                    guard.Block(); guard.VerifyProtection();
                    var registration = EnrollmentRegistration.Load(store);
                    var profile = ManagedVpnProfile.FromJournal(store.LoadPlan().Owner, store.LoadVpnEntry());
                    connection = OwnedRasConnection.Begin(profile, registration.Id, registration.Password);
                    routeDeadline = DateTime.MinValue;
                }
                var observed = connection.Observe();
                if (observed == null) { connectionState = "connecting"; return; }
                var selectedAddresses = store.LoadPolicyHistory().Current.Resources.Select(r => IPAddress.Parse(r.Address)).ToArray();
                if (routes != null && !routes.Matches(observed, selectedAddresses)) { guard.Block(); routes.Dispose(); routes = null; }
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
                        if (DateTime.UtcNow < routeDeadline) { connectionState = "connecting"; return; }
                        throw new InvalidOperationException("Selected route does not use the owned tunnel");
                    }
                }
                // DNS and router readiness have not granted permission yet.
                connectionError = "none";
                connectionState = "tunnel_connected";
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
                if (guard != null) guard.Block();
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
                    if (guard != null) guard.Block();
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
                    try { if (guard != null) guard.Block(); }
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
                    try { if (guard != null) guard.Block(); }
                    catch { Environment.FailFast("Client guard could not close its permission session"); }
                    try { Publish("error"); } catch { }
                }
            }
        }

        private void Publish(string state)
        {
            store.PublishStatus(new ClientStatus { State = state, GuardInstalled = healthy,
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
                    if (guard != null) guard.Block();
                    CloseConnection();
                    if (guard != null) guard.Dispose();
                    if (store != null) Publish("stopped");
                }
                finally { if (store != null) store.Dispose(); }
            }
        }
    }
}
