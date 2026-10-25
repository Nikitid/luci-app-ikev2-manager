using System;
using System.IO;

namespace Nikitid.IkeV2ProfileInstaller
{
    // The installer's own store against Windows, as an ordinary user: the
    // profile installed, seen, installed again and removed.
    internal static class StoreCheck
    {
        private static int Main(string[] args)
        {
            ProfileDocument document = ProfileDocument.Load(args[0]);
            document.SetName("Waypoint Store Check " + Guid.NewGuid().ToString("N").Substring(0, 8));
            try
            {
                Console.WriteLine("install: " + VpnProfileStore.Install(document));
                Check(VpnProfileStore.Exists(document), "the installed profile is seen");
                Console.WriteLine("again: " + VpnProfileStore.Install(document));
                Console.WriteLine("remove: " + VpnProfileStore.Remove(document));
                Check(!VpnProfileStore.Exists(document), "the removed profile is gone");
                Console.WriteLine("Installer store checks passed");
                return 0;
            }
            catch (Exception error)
            {
                Console.WriteLine("FAIL " + error.Message);
                try { VpnProfileStore.Remove(document); } catch {}
                return 1;
            }
        }

        private static void Check(bool ok, string what)
        {
            if (!ok) throw new InvalidOperationException(what);
            Console.WriteLine("PASS " + what);
        }
    }
}
