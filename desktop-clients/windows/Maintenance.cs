using System;
using System.Security.Principal;
using System.ServiceProcess;
using Microsoft.Win32;

namespace IkeV2Manager.Client
{
    // What the window asks for with an administrator's right, and what the
    // installer runs on removal, done by the service's own binary: it owns the
    // knowledge of what it set up. Each exits 0 on success, 1 on failure, 2
    // for an unknown request and 4 without an administrator's right.
    internal static class Maintenance
    {
        internal static readonly string[] Requests = { "--reset", "--browsers-on", "--browsers-off", "--uninstall" };

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

        internal static int Run(string name, string request, Func<string, int> removeProtection)
        {
            if (Array.IndexOf(Requests, request) < 0) return 2;
            if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) return 4;
            try
            {
                switch (request)
                {
                    case "--browsers-on": ApplyBrowserPolicies(); return 0;
                    case "--browsers-off": RemoveBrowserPolicies(false); return 0;
                    case "--reset": return Reset(name, removeProtection);
                    default:
                        // Removal: the service is stopped by the installer
                        // first; what it set up goes, and so does what the
                        // browsers were told.
                        int removed = Exists(name) ? Stopped(name, () => removeProtection(name)) : removeProtection(name);
                        RemoveBrowserPolicies(true);
                        return removed == 0 ? 0 : 1;
                }
            }
            catch (Exception) { return 1; }
        }

        // Everything the program set up on this computer goes - the VPN
        // connection, the blocking, the names, the registration - and the
        // program stays, ready to register again. The service starts again
        // whatever became of the removal.
        private static int Reset(string name, Func<string, int> removeProtection)
        {
            if (!Exists(name)) return 1;
            int removed = Stopped(name, () => removeProtection(name));
            using (var service = new ServiceController(name))
            {
                service.Start();
                service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
            }
            return removed == 0 ? 0 : 1;
        }

        private static int Stopped(string name, Func<int> step)
        {
            using (var service = new ServiceController(name))
            {
                if (service.Status != ServiceControllerStatus.Stopped)
                {
                    if (service.Status != ServiceControllerStatus.StopPending) service.Stop();
                    service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(60));
                }
            }
            return step();
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
        private static void RemoveBrowserPolicies(bool everything)
        {
            using (var record = Registry.LocalMachine.OpenSubKey(OwnedKey))
            {
                var owned = record == null ? null : record.GetValue("BrowserPolicies") as string[];
                foreach (string identity in owned ?? new string[0])
                {
                    string[] parts = identity.Split('|');
                    if (parts.Length != 2) continue;
                    using (var key = Registry.LocalMachine.OpenSubKey(parts[0], true))
                        if (key != null) key.DeleteValue(parts[1], false);
                }
            }
            if (everything) Registry.LocalMachine.DeleteSubKeyTree(OwnedKey, false);
            else using (var record = Registry.LocalMachine.OpenSubKey(OwnedKey, true)) if (record != null) record.DeleteValue("BrowserPolicies", false);
        }
    }
}
