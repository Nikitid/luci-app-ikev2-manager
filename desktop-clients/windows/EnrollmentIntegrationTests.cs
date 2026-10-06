using System;
using System.IO;
using System.Threading;
using System.Diagnostics;
using System.ServiceProcess;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

// Real HTTPS enrollment through the installed service. The fixture owns a
// disposable router, invitation and trust anchor. Native IKE is opt-in.
internal static class EnrollmentIntegrationTests
{
    private sealed class AssertionFailure : Exception { internal AssertionFailure(string message) : base(message) {} }
    private static void Require(bool value, string message) { if (!value) throw new AssertionFailure(message); }
    private static void Sc(string arguments)
    {
        using (var process = Process.Start(new ProcessStartInfo("sc.exe", arguments) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }))
        {
            process.StandardOutput.ReadToEnd(); process.StandardError.ReadToEnd();
            if (!process.WaitForExit(15000) || process.ExitCode != 0) throw new Exception("Test service operation failed");
        }
    }
    private static void Stop(ServiceController service)
    {
        service.Refresh();
        if (service.Status != ServiceControllerStatus.Stopped) {
            service.Stop(); service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(40));
        }
    }
    private static string Diagnosis(string name)
    {
        var view = ClientStatusReader.Read(name);
        return view.State + "/" + view.ConnectionError;
    }
    private static bool Await(string name, bool open, int milliseconds)
    {
        var elapsed = Stopwatch.StartNew();
        while (ClientStatusReader.Read(name).Protected != open && elapsed.ElapsedMilliseconds < milliseconds) Thread.Sleep(250);
        return ClientStatusReader.Read(name).Protected == open;
    }
    // One line out and the same line back, or nothing.
    private static bool Echo(string host, int port)
    {
        try
        {
            using (var client = new System.Net.Sockets.TcpClient())
            {
                var pending = client.BeginConnect(host, port, null, null);
                if (!pending.AsyncWaitHandle.WaitOne(4000)) return false;
                client.EndConnect(pending);
                client.ReceiveTimeout = client.SendTimeout = 4000;
                byte[] line = System.Text.Encoding.ASCII.GetBytes("desktop-path\n"), answer = new byte[line.Length];
                var stream = client.GetStream();
                stream.Write(line, 0, line.Length);
                int total = 0, read;
                while (total < answer.Length && (read = stream.Read(answer, total, answer.Length - total)) > 0) total += read;
                return total == line.Length && System.Linq.Enumerable.SequenceEqual(line, answer);
            }
        }
        catch (System.Net.Sockets.SocketException) { return false; }
        catch (IOException) { return false; }
    }
    private static int Main(string[] args)
    {
        string name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name);
        bool created = false;
        bool ownsMappings = false;
        string step = "TLS";
        try {
            string hostsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"drivers\etc\hosts");
            Require(!File.ReadAllText(hostsPath).Contains("# BEGIN IKEv2 Manager managed hosts"), "Existing client mappings must not be replaced by a fixture");
            ownsMappings = true;
            var config = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(args[0]));
            string endpoint, invite;
            ClientCommands.ParseInvitation((string)config["invitation"], out endpoint, out invite);
            bool refused = false;
            try { EnrollmentTransportClient.Claim(new Uri((string)config["wrong_endpoint"]), invite, new string('d', 64)); }
            catch (EnrollmentException error) { Require(error.Code == "enrollment_connection_failed", "Unexpected TLS mismatch response"); refused = true; }
            Require(refused, "TLS hostname mismatch accepted");
            Console.WriteLine("Native TLS hostname mismatch refused");
            step = "service registration";
            using (var store = new GuardStore(name)) {
                File.Copy(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ClientService.exe"), Path.Combine(directory, "ClientService.exe"));
            }
            string binary = "\"" + Path.Combine(directory, "ClientService.exe") + "\" --test " + name;
            Sc("create " + name + " binPath= \"" + binary.Replace("\"", "\\\"") + "\" start= demand"); created = true;
            string deviceToken = null;
            using (var service = new ServiceController(name)) {
                service.Start(); service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(15));
                Require(ClientCommands.Send("begin", endpoint, invite, name) == "accepted", "Service refused enrollment begin");
                Require(ClientCommands.Send("continue", null, null, name) == "accepted", "Service refused enrollment continuation");
                bool pending = false;
                for (int attempt = 0; attempt < 8; attempt++) {
                    Thread.Sleep(2000); Stop(service);
                    using (var store = new GuardStore(name)) {
                        var registration = EnrollmentRegistration.Load(store);
                        Require(registration != null && registration.Policy == null, "Expected pending enrollment");
                        if (deviceToken == null) deviceToken = registration.DeviceToken;
                        Require(deviceToken == registration.DeviceToken, "Service restart replaced the device key");
                        pending = registration.Id == "native-laptop";
                    }
                    if (pending) break;
                    service.Start(); service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(15));
                }
                Require(pending, "HTTPS claim was not persisted");
                Console.WriteLine("READY_NATIVE_PENDING");
                step = "bootstrap protection";
                service.Start(); service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(15));
                var elapsed = Stopwatch.StartNew(); bool completed = false;
                while (elapsed.ElapsedMilliseconds < 60000) {
                    var status = ClientStatusReader.Read(name);
                    if (status.GuardInstalled && status.State == "blocked") { completed = true; break; }
                    Thread.Sleep(250);
                }
                Require(completed, "Service did not complete live enrollment");
                step = "bootstrap persistence";
                Stop(service);
                using (var store = new GuardStore(name)) {
                    var registration = EnrollmentRegistration.Load(store);
                    Require(registration != null && registration.Policy != null && registration.Id == "native-laptop" &&
                        registration.DeviceToken == deviceToken, "Completed registration lost its identity");
                    Require(store.LoadPolicyHistory().Current.Canonical == registration.Policy.Canonical, "Bootstrap policy was not staged");
                    Require(store.LoadVpnEntry() != Guid.Empty, "Managed IKEv2 profile was not persisted");
                    foreach (var resource in registration.Policy.Resources)
                    {
                        var addresses = System.Net.Dns.GetHostAddresses(resource.Domain);
                        Require(addresses.Length == 1 && addresses[0].ToString() == resource.Address, "System resolver exposed a public destination");
                    }
                    using (var guard = WfpGuard.Recover(store.LoadPlan())) guard.VerifyProtection();
                    Require(!store.LoadEnrollmentDocument().Contains(invite), "Completed enrollment retained the invitation");
                }
                Console.WriteLine("READY_NATIVE_ENABLE");
                Thread.Sleep(1000);
                service.Start(); service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(15));
                step = "restart protection";
                elapsed.Restart();
                while (!ClientStatusReader.Read(name).GuardInstalled && elapsed.ElapsedMilliseconds < 5000) Thread.Sleep(100);
                var recovered = ClientStatusReader.Read(name);
                Require(recovered.GuardInstalled && !recovered.Protected && recovered.State == "blocked", "Restart did not recover closed protection");
                if (config.ContainsKey("connect") && (bool)config["connect"])
                {
                    step = "native IKEv2 connection";
                    Require(ClientCommands.Send("connect", service: name) == "accepted", "Connect refused");
                    elapsed.Restart();
                    while (ClientStatusReader.Read(name).State != "tunnel_connected" && ClientStatusReader.Read(name).State != "protected" && elapsed.ElapsedMilliseconds < 45000) Thread.Sleep(250);
                    if (ClientStatusReader.Read(name).State != "tunnel_connected" && ClientStatusReader.Read(name).State != "protected") {
                        var diagnosis = ClientStatusReader.Read(name);
                        Console.WriteLine("Native connection diagnosis: " + diagnosis.State + "/" + diagnosis.ConnectionError);
                    }
                    if (config.ContainsKey("probe_host"))
                    {
                        // A router with the whole path: permission must follow
                        // its readiness, and the service must answer only then.
                        string target = (string)config["probe_host"]; int port = (int)config["probe_port"];
                        step = "router readiness";
                        Require(Await(name, true, 45000), "Router readiness did not open access: " + Diagnosis(name));
                        var named = ClientStatusReader.Read(name);
                        Require(named.Services.Length == 1 && named.Services[0] == "api" && named.Available.Length == 0, "Status did not name the assigned service");
                        Require(Echo(target, port), "Selected service did not answer through the confirmed path");
                        Require(!Echo(target, (int)config["closed_port"]), "A port outside the assignment answered");
                        Console.WriteLine("Native protected status and selected service traffic verified");
                        Console.WriteLine("READY_NATIVE_PATHDOWN");
                        step = "path loss";
                        Require(Await(name, false, 30000), "Lost router path left the protected status");
                        Require(ClientStatusReader.Read(name).State == "tunnel_connected", "Path loss changed the tunnel state: " + Diagnosis(name));
                        Require(!Echo(target, port), "Selected service answered without the router path");
                        Console.WriteLine("READY_NATIVE_PATHUP");
                        step = "path recovery";
                        Require(Await(name, true, 45000), "Restored router path did not reopen access: " + Diagnosis(name));
                        Require(Echo(target, port), "Selected service did not recover");
                        Console.WriteLine("Native path loss closed and recovery reopened access");
                        Require(ClientCommands.Send("disconnect", service: name) == "accepted", "Disconnect refused");
                        elapsed.Restart();
                        while (ClientStatusReader.Read(name).State != "blocked" && elapsed.ElapsedMilliseconds < 10000) Thread.Sleep(100);
                        Require(ClientStatusReader.Read(name).State == "blocked" && !Echo(target, port), "Disconnect left the selected service reachable");
                        Require(ClientCommands.Send("connect", service: name) == "accepted", "Reconnect refused");
                        Require(Await(name, true, 60000), "Reconnect did not reopen access: " + Diagnosis(name));
                        // The user's choice outlives the service: a restart
                        // returns to the connection without being asked.
                        step = "connection after restart";
                        Stop(service);
                        Require(!Echo(target, port), "Selected service answered while the service was stopped");
                        service.Start(); service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(15));
                        Require(Await(name, true, 60000), "Restart did not return to the wanted connection: " + Diagnosis(name));
                        var shown = ClientStatusReader.Read(name);
                        Require(shown.Domains == 1 && shown.Revision >= 1 && shown.Wanted,
                            "Status did not show the assigned service");
                        Require(Echo(target, port), "Selected service did not answer after restart");
                        Console.WriteLine("Native restart returned to the protected connection");
                    }
                    else
                    {
                        Require(ClientStatusReader.Read(name).State == "tunnel_connected", "Native tunnel and routes were not confirmed");
                        Require(!ClientStatusReader.Read(name).Protected, "Tunnel was confused with complete protection");
                    }
                    Console.WriteLine("Native enrolled IKEv2 connection and selected routes verified");
                    Require(ClientCommands.Send("disconnect", service: name) == "accepted", "Disconnect refused");
                    elapsed.Restart();
                    while (ClientStatusReader.Read(name).State != "blocked" && elapsed.ElapsedMilliseconds < 10000) Thread.Sleep(100);
                    Require(ClientStatusReader.Read(name).State == "blocked", "Disconnect did not retain denials");
                }
                Console.WriteLine("READY_NATIVE_UPDATE");
                step = "central update";
                Thread.Sleep(35000);
                Stop(service);
                using (var store = new GuardStore(name))
                {
                    Require(store.LoadPolicyHistory().Current.Revision == 2, "Service did not refresh the assigned policy");
                    using (var guard = WfpGuard.Recover(store.LoadPlan())) guard.VerifyProtection();
                }
                Console.WriteLine("READY_NATIVE_REVOKE");
                step = "revocation";
                service.Start(); service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(15));
                elapsed.Restart();
                while (ClientStatusReader.Read(name).State != "access_closed" && elapsed.ElapsedMilliseconds < 35000) Thread.Sleep(250);
                Require(ClientStatusReader.Read(name).State == "access_closed", "Revocation did not become visible");
                Thread.Sleep(6000);
                Require(ClientStatusReader.Read(name).State == "access_closed", "Heartbeat cleared a synchronization error");
                Stop(service);
            }
            Console.WriteLine("Native service HTTPS enrollment, restart, central update and revocation passed");
            return 0;
        } catch (Exception error) {
            // Credentials and arbitrary server replies cannot reach test logs.
            Console.Error.WriteLine("Native enrollment integration failed at " + step + " (" + error.GetType().Name + ")");
            if (error is AssertionFailure) Console.Error.WriteLine("Assertion: " + error.Message);
            return 1;
        } finally {
            if (created) {
                using (var service = new ServiceController(name)) Stop(service);
                Sc("delete " + name);
            }
            if (Directory.Exists(directory)) {
                using (var store = new GuardStore(name)) {
                    var plan = store.LoadPlan();
                    if (ownsMappings) SystemHosts.Remove(store);
                    var entry = store.LoadVpnEntry();
                    if (entry != Guid.Empty) ManagedVpnProfile.Remove(plan.Owner, entry);
                    if (plan != null) using (var guard = WfpGuard.Resume(plan)) guard.Remove();
                }
                Directory.Delete(directory, true);
            }
        }
    }
}
