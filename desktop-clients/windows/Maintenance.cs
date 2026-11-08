using System;
using System.Security.Principal;
using System.ServiceProcess;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace IkeV2Manager.Client
{
    // What the window asks for with an administrator's right, and what the
    // installer runs on removal, done by the service's own binary: it owns the
    // knowledge of what it set up. Each exits 0 on success, 1 on failure, 2
    // for an unknown request and 4 without an administrator's right.
    internal static class Maintenance
    {
        internal static readonly string[] Requests = { "--reset", "--start", "--browsers-on", "--browsers-off", "--uninstall" };

        // A browser set to resolve names over its own encrypted channel reaches
        // a service around the tunnel. Each browser has a setting, meant for
        // whoever manages the computer, to ask the system instead. Setting it
        // reaches beyond this program's services, so it is never done by
        // installing: only when the person at the window asks for it, and it
        // is taken back there too, and on removal. Only values this program
        // wrote are recorded, and only those are removed.
        private const string OwnedKey = @"Software\IKEv2ManagerClient";
        private static readonly string[][] BrowserPolicies = {
            new[] { @"SOFTWARE\Policies\Google\Chrome", "DnsOverHttpsMode", "off" },
            new[] { @"SOFTWARE\Policies\Microsoft\Edge", "DnsOverHttpsMode", "off" },
            new[] { @"SOFTWARE\Policies\BraveSoftware\Brave", "DnsOverHttpsMode", "off" },
            new[] { @"SOFTWARE\Policies\YandexBrowser", "DnsOverHttpsMode", "off" },
            new[] { @"SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS", "Enabled", "0" },
            new[] { @"SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS", "Locked", "1" }
        };

        internal static readonly TimeSpan StopWait = TimeSpan.FromSeconds(60);
        // Where the reset leaves its account, for the window to read.
        internal const string Record = @"SOFTWARE\Waypoint";

        internal static int Run(string name, string request)
        {
            if (Array.IndexOf(Requests, request) < 0) return 2;
            if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) return 4;
            try
            {
                switch (request)
                {
                    case "--browsers-on": ApplyBrowserPolicies(); return 0;
                    case "--browsers-off": RemoveBrowserPolicies(false); return 0;
                    case "--start": return Start(name) ? 0 : 1;
                    case "--reset": return Reset(name, StopWait).Complete ? 0 : 1;
                    default:
                        // Removal: the service is stopped by the installer
                        // first; what it set up goes, and so does what the
                        // browsers were told.
                        var removed = Exists(name) ? Stopped(name, StopWait, () => Removal.Run(name)) : Removal.Run(name);
                        RemoveBrowserPolicies(true);
                        return removed.Complete ? 0 : 1;
                }
            }
            catch (Exception) { return 1; }
        }

        // Everything the program set up on this computer goes - the VPN
        // connection, the blocking, the names, the registration, what the
        // browsers were told - and the program stays, ready to register again.
        // The reset always comes to an end: a service that does not stop in
        // `wait` is ended by force, and the service is started again whatever
        // became of the removal. What went and what did not is recorded.
        internal static RemovalResult Reset(string name, TimeSpan wait)
        {
            var result = new RemovalResult();
            if (!Exists(name)) { result.Fail("service_missing"); return result; }
            try
            {
                result = Stopped(name, wait, () => Removal.Run(name));
                if (name == Removal.Product)
                    try { result.BrowserPolicies = RemoveBrowserPolicies(false); } catch (Exception) { result.Fail("browsers"); }
            }
            catch (Exception) { result.Fail("service_stop"); }
            if (!Start(name)) result.Fail("service_start");
            try
            {
                using (var key = Registry.LocalMachine.CreateSubKey(RecordKey(name)))
                    key.SetValue("LastReset", result.Json(DateTime.UtcNow), RegistryValueKind.String);
            }
            catch (Exception) { }
            if (!result.Complete)
                new FailureQueue(name).Record("reset_incomplete", "reset", "not removed: " + String.Join(",", result.Failed), null);
            return result;
        }

        internal static string RecordKey(string name) { return name == Removal.Product ? Record : Record + @"\Test\" + name; }

        // The service as installed, running; asked for by the window when it
        // finds the service stopped.
        internal static bool Start(string name)
        {
            try
            {
                using (var service = new ServiceController(name))
                {
                    service.Refresh();
                    if (service.Status == ServiceControllerStatus.Running) return true;
                    if (service.Status != ServiceControllerStatus.StartPending) service.Start();
                    service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
                    return true;
                }
            }
            catch (Exception) { return false; }
        }

        // The step runs with the service stopped. While it runs the service is
        // disabled: one ended by force would otherwise be started again by the
        // service control manager's recovery in the middle of the step.
        private static RemovalResult Stopped(string name, TimeSpan wait, Func<RemovalResult> step)
        {
            uint startType = ServiceControl.StartType(name);
            ServiceControl.SetStartType(name, ServiceControl.Disabled);
            try
            {
                using (var service = new ServiceController(name))
                {
                    service.Refresh();
                    if (service.Status != ServiceControllerStatus.Stopped)
                    {
                        try { if (service.Status != ServiceControllerStatus.StopPending) service.Stop(); }
                        catch (InvalidOperationException) { }
                        try { service.WaitForStatus(ServiceControllerStatus.Stopped, wait); }
                        catch (System.ServiceProcess.TimeoutException)
                        {
                            // Stuck - a connection that does not hang up, a
                            // step that never returns: its process is ended.
                            ServiceControl.Kill(name);
                            service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(30));
                        }
                    }
                }
                return step();
            }
            finally { ServiceControl.SetStartType(name, startType); }
        }

        private static bool Exists(string name)
        {
            foreach (var service in ServiceController.GetServices())
                using (service) if (String.Equals(service.ServiceName, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        private static void ApplyBrowserPolicies()
        {
            var owned = new System.Collections.Generic.List<string>();
            using (var record = Registry.LocalMachine.CreateSubKey(OwnedKey))
            {
                var previous = record.GetValue("BrowserPolicies") as string[];
                if (previous != null) owned.AddRange(previous);
                foreach (var policy in BrowserPolicies)
                {
                    string identity = policy[0] + "|" + policy[1];
                    using (var key = Registry.LocalMachine.CreateSubKey(policy[0]))
                    {
                        // Somebody else's setting stays theirs.
                        if (key.GetValue(policy[1]) != null && !owned.Contains(identity)) continue;
                        if (policy[2] == "off") key.SetValue(policy[1], policy[2], RegistryValueKind.String);
                        else key.SetValue(policy[1], Int32.Parse(policy[2]), RegistryValueKind.DWord);
                        if (!owned.Contains(identity)) owned.Add(identity);
                    }
                }
                record.SetValue("BrowserPolicies", owned.ToArray(), RegistryValueKind.MultiString);
            }
        }

        // `everything` also drops this program's whole record, at removal.
        private static int RemoveBrowserPolicies(bool everything)
        {
            int removed = 0;
            using (var record = Registry.LocalMachine.OpenSubKey(OwnedKey))
            {
                var owned = record == null ? null : record.GetValue("BrowserPolicies") as string[];
                foreach (string identity in owned ?? new string[0])
                {
                    string[] parts = identity.Split('|');
                    if (parts.Length != 2) continue;
                    using (var key = Registry.LocalMachine.OpenSubKey(parts[0], true))
                        if (key != null && key.GetValue(parts[1]) != null) { key.DeleteValue(parts[1], false); removed++; }
                }
            }
            if (everything) Registry.LocalMachine.DeleteSubKeyTree(OwnedKey, false);
            else using (var record = Registry.LocalMachine.OpenSubKey(OwnedKey, true)) if (record != null) record.DeleteValue("BrowserPolicies", false);
            return removed;
        }
    }

    // The service control manager, for what ServiceController does not do:
    // the start type and the process of a service.
    internal static class ServiceControl
    {
        internal const uint Disabled = 4;
        private const uint NoChange = 0xFFFFFFFF;

        internal static uint StartType(string name)
        {
            return With(name, 0x0001 | 0x0004, service => {
                uint needed;
                QueryServiceConfigW(service, IntPtr.Zero, 0, out needed);
                IntPtr buffer = Marshal.AllocHGlobal((int)needed);
                try
                {
                    if (!QueryServiceConfigW(service, buffer, needed, out needed)) throw new System.ComponentModel.Win32Exception();
                    return (uint)Marshal.ReadInt32(buffer, 4);
                }
                finally { Marshal.FreeHGlobal(buffer); }
            });
        }

        internal static void SetStartType(string name, uint type)
        {
            With(name, 0x0002, service => {
                if (!ChangeServiceConfigW(service, NoChange, type, NoChange, null, null, IntPtr.Zero, null, null, null, null))
                    throw new System.ComponentModel.Win32Exception();
                return 0u;
            });
        }

        internal static void Kill(string name)
        {
            uint process = With(name, 0x0004, service => {
                Status status; uint needed;
                if (!QueryServiceStatusEx(service, 0, out status, (uint)Marshal.SizeOf(typeof(Status)), out needed)) throw new System.ComponentModel.Win32Exception();
                return status.Process;
            });
            if (process == 0) return;
            try { using (var running = System.Diagnostics.Process.GetProcessById((int)process)) { running.Kill(); running.WaitForExit(15000); } }
            catch (ArgumentException) { }
        }

        private static uint With(string name, uint access, Func<IntPtr, uint> action)
        {
            IntPtr manager = OpenSCManagerW(null, null, 1), service = IntPtr.Zero;
            if (manager == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            try
            {
                service = OpenServiceW(manager, name, access);
                if (service == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
                return action(service);
            }
            finally
            {
                if (service != IntPtr.Zero) CloseServiceHandle(service);
                CloseServiceHandle(manager);
            }
        }

        [StructLayout(LayoutKind.Sequential)] private struct Status
        {
            internal uint Type, State, Accepted, Win32ExitCode, ServiceExitCode, CheckPoint, WaitHint, Process, Flags;
        }
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool QueryServiceStatusEx(IntPtr service, uint level, out Status status, uint bytes, out uint required);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern bool QueryServiceConfigW(IntPtr service, IntPtr config, uint bytes, out uint needed);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern bool ChangeServiceConfigW(IntPtr service, uint type, uint start, uint error, string binary, string group,
            IntPtr tag, string dependencies, string account, string password, string display);
        [DllImport("advapi32.dll")] private static extern bool CloseServiceHandle(IntPtr handle);
    }
}
