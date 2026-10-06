using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Threading;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

internal static class PolicyTransportIntegrationTests
{
    private static int Main(string[] args)
    {
        string name = null;
        try
        {
            var serializer = new JavaScriptSerializer();
            var config = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(args[0]));
            var endpoint = new Uri((string)config["endpoint"]);
            string token = (string)config["token"];
            var first = ClientPolicy.Parse(serializer.Serialize(config["policy"]));
            var history = PolicyHistory.Begin(first);
            // A valid chain for another hostname must still be refused before
            // transmitting the device key or staging any policy.
            bool mismatchRefused = false;
            try { PolicyTransportClient.Fetch(new Uri((string)config["wrong_endpoint"]), token, history); }
            catch (PolicyFetchException error)
            {
                if (error.Code != "policy_connection_failed") throw;
                mismatchRefused = true;
            }
            if (!mismatchRefused) throw new Exception("TLS hostname mismatch was accepted");
            Console.WriteLine("TLS hostname mismatch refused");
            foreach (string value in history.ProtectedAddresses())
            {
                var address = IPAddress.Parse(value);
                if (RouteObservation.Read(address).PrefixLength != 0 || IPGlobalProperties.GetIPGlobalProperties()
                    .GetActiveTcpConnections().Any(c => c.RemoteEndPoint.Address.Equals(address)))
                    throw new Exception("Test destinations are already in use or specifically routed");
            }
            name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
            using (var runtime = new GuardRuntime(name))
            {
                runtime.StagePolicy(PolicyTransportClient.Fetch(endpoint, token, history));
                Console.WriteLine("READY_POLICY_1");
                for (int i = 0; ; i++)
                {
                    var next = PolicyTransportClient.Fetch(endpoint, token, history);
                    if (next.Revision == 2)
                    {
                        runtime.StagePolicy(next);
                        history = history.Propose(next);
                        break;
                    }
                    if (i >= 30) throw new Exception("Updated server policy did not arrive");
                    Thread.Sleep(500);
                }
                Console.WriteLine("READY_POLICY_2");
                bool revoked = false;
                for (int i = 0; i < 30; i++)
                {
                    try { PolicyTransportClient.Fetch(endpoint, token, history); }
                    catch (PolicyFetchException error)
                    {
                        if (error.Code != "device_access_revoked") throw;
                        revoked = true;
                        break;
                    }
                    Thread.Sleep(500);
                }
                if (!revoked) throw new Exception("Device revocation was not received");
                Console.WriteLine("HTTPS policy update and device revocation received");
            }
            using (var store = new GuardStore(name))
            {
                if (store.LoadPolicyHistory().Current.Revision != 2) throw new Exception("Received policy was not journaled");
                using (var guard = WfpGuard.Recover(store.LoadPlan())) guard.VerifyProtection();
            }
            Console.WriteLine("Native HTTPS and policy staging integration passed");
            return 0;
        }
        catch (PolicyFetchException error) { Console.Error.WriteLine(error.Code); return 1; }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
        finally
        {
            if (name != null)
            {
                string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name);
                if (Directory.Exists(directory))
                {
                    using (var store = new GuardStore(name))
                    {
                        var plan = store.LoadPlan();
                        if (plan != null) using (var guard = WfpGuard.Resume(plan)) guard.Remove();
                    }
                    Directory.Delete(directory, true);
                }
            }
        }
    }
}
