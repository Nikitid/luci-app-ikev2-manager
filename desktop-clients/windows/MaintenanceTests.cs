using System;
using IkeV2Manager.Client;
using Microsoft.Win32;

// The browser settings the window may ask for: set where nobody else set
// them, taken back only where this program set them. Needs an administrator
// and changes the machine's browser policies for the time it runs, so it runs
// with the WFP tests only and never where the product is installed.
internal static class MaintenanceTests
{
    private const string Chrome = @"SOFTWARE\Policies\Google\Chrome", Edge = @"SOFTWARE\Policies\Microsoft\Edge";

    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception("FAIL " + name);
        Console.WriteLine("PASS " + name);
    }

    private static object Value(string key, string name)
    {
        using (var opened = Registry.LocalMachine.OpenSubKey(key)) return opened == null ? null : opened.GetValue(name);
    }

    private static int Main()
    {
        using (var installed = Registry.LocalMachine.OpenSubKey(@"Software\IKEv2ManagerClient"))
            if (installed != null) { Console.WriteLine("Browser settings checks skipped: the product is installed here"); return 0; }
        object chrome = Value(Chrome, "DnsOverHttpsMode"), edge = Value(Edge, "DnsOverHttpsMode");
        try
        {
            using (var key = Registry.LocalMachine.CreateSubKey(Edge)) key.SetValue("DnsOverHttpsMode", "automatic", RegistryValueKind.String);
            using (var key = Registry.LocalMachine.CreateSubKey(Chrome)) key.DeleteValue("DnsOverHttpsMode", false);
            Require(Maintenance.Run("IKEv2ManagerClient", "--unknown") == 2, "an unknown request is refused");
            Require(Maintenance.Run("IKEv2ManagerClient", "--browsers-on") == 0 && (Value(Chrome, "DnsOverHttpsMode") as string) == "off",
                "browsers are told to ask the system");
            Require((Value(Edge, "DnsOverHttpsMode") as string) == "automatic", "a setting somebody else made stays theirs");
            Require(Maintenance.Run("IKEv2ManagerClient", "--browsers-off") == 0 && Value(Chrome, "DnsOverHttpsMode") == null &&
                (Value(Edge, "DnsOverHttpsMode") as string) == "automatic", "only what this program set is taken back");
            return 0;
        }
        finally
        {
            Registry.LocalMachine.DeleteSubKeyTree(@"Software\IKEv2ManagerClient", false);
            foreach (var saved in new[] { new object[] { Chrome, chrome }, new object[] { Edge, edge } })
                using (var key = Registry.LocalMachine.CreateSubKey((string)saved[0]))
                {
                    if (saved[1] == null) key.DeleteValue("DnsOverHttpsMode", false);
                    else key.SetValue("DnsOverHttpsMode", saved[1], RegistryValueKind.String);
                }
        }
    }
}
