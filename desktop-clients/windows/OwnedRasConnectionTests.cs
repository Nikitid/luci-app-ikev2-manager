using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using IkeV2Manager.Client;

internal static class OwnedRasConnectionTests
{
    private static int Main(string[] args)
    {
        Guid owner = Guid.NewGuid(); ManagedVpnProfile profile = null; OwnedRasConnection connection = null;
        string step = "profile";
        try
        {
            var serializer = new JavaScriptSerializer();
            var fixtures = (object[])serializer.DeserializeObject(File.ReadAllText(args[0]));
            var document = (Dictionary<string,object>)((Dictionary<string,object>)fixtures[0])["policy"];
            string host = "ikev2-" + owner.ToString("N") + ".invalid";
            document["server"] = new Dictionary<string,object> { {"address",host},{"remote_id",host} };
            profile = ManagedVpnProfile.Ensure(ClientPolicy.Parse(serializer.Serialize(document)), owner, Guid.Empty);
            step = "native async dial";
            connection = OwnedRasConnection.Begin(profile, "synthetic-user", new string('a',64));
            var elapsed = Stopwatch.StartNew();
            bool cancelled = false;
            while (elapsed.ElapsedMilliseconds < 1000)
            {
                try { if (connection.Observe() != null) throw new Exception("Unexpected synthetic connection"); }
                catch (InvalidOperationException) { cancelled = true; break; }
                Thread.Sleep(50);
            }
            step = "owned cancellation";
            connection.Dispose();
            if (RasTunnel.Exists(profile.EntryId, profile.Phonebook)) throw new Exception("Native connection survived cleanup");
            if (elapsed.ElapsedMilliseconds > 6500) throw new Exception("Cancellation exceeded bound");
            Console.WriteLine("Native asynchronous IKEv2 dial accepted; failure/cancellation closes only owned handle" + (cancelled ? " (failed before cancel)" : ""));
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine("Native connection test failed at " + step + " (" + error.GetType().Name + ")"); return 1; }
        finally
        {
            if (connection != null) connection.Dispose();
            if (profile != null) ManagedVpnProfile.Remove(owner, profile.EntryId);
        }
    }
}
