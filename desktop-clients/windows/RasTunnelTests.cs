using System;
using System.IO;
using System.Net;
using IkeV2Manager.Client;

internal static class RasTunnelTests
{
    private static int Main()
    {
        try
        {
            bool rejected = false;
            try { RasTunnel.Observe(Guid.Empty, "relative.pbk"); }
            catch (ArgumentException) { rejected = true; }
            if (!rejected) throw new Exception("Unowned RAS lookup was accepted");
            string absentPhonebook = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".pbk");
            if (RasTunnel.Observe(Guid.NewGuid(), absentPhonebook) != null)
                throw new Exception("Unrelated RAS connection was selected");
            var route = RouteObservation.Read(IPAddress.Loopback);
            if (route.InterfaceLuid == 0 || !route.Source.Equals(IPAddress.Loopback) ||
                !route.Prefix.Equals(IPAddress.Loopback) || route.PrefixLength != 32)
                throw new Exception("Native loopback route observation failed");
            if (route.Matches(null, IPAddress.Loopback)) throw new Exception("A route without an observed tunnel was accepted");
            if (route.Matches(new TunnelObservation { InterfaceLuid = UInt64.MaxValue, LocalAddress = IPAddress.Loopback }, IPAddress.Loopback))
                throw new Exception("An unrelated route was accepted");
            Console.WriteLine("RAS observation checks passed: invalid identity and absent managed profile");
            Console.WriteLine("Native route observation and rejection checks passed");
            Console.WriteLine("Connected IKEv2 observation requires the end-to-end scenario");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
