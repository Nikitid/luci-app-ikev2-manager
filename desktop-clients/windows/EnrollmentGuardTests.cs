using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

internal static class EnrollmentGuardTests
{
    public static void Run(string fixtures)
    {
        var serializer = new JavaScriptSerializer();
        var values = (object[])serializer.DeserializeObject(File.ReadAllText(Path.Combine(fixtures, "policies.json")));
        var policy = ClientPolicy.Parse(serializer.Serialize(((Dictionary<string, object>)values[0])["policy"]));
        foreach (var resource in policy.Resources)
        {
            var address = IPAddress.Parse(resource.Address);
            if (RouteObservation.Read(address).PrefixLength != 0 || IPGlobalProperties.GetIPGlobalProperties()
                .GetActiveTcpConnections().Any(c => c.RemoteEndPoint.Address.Equals(address)))
                throw new InvalidOperationException("Enrollment test destination already in use or specifically routed");
        }
        string name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name);
        GuardReceipt plan = null;
        try
        {
            using (var store = new GuardStore(name))
            {
                EnrollmentRegistration.Begin(store, new Uri("https://vpn.example.com/client/v1/enroll"), new string('a', 64));
                EnrollmentRegistration.Accept(store, new EnrollmentResult(policy.Id, policy, new string('b', 64)));
            }
            // Simulate a process stop after credentials commit, before WFP staging.
            using (var runtime = new GuardRuntime(name))
            {
                var status = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(directory, "status.json")));
                if ((string)status["State"] != "blocked" || (bool)status["Protected"])
                    throw new Exception("Enrollment recovery did not stage denials or claimed protection");
            }
            using (var store = new GuardStore(name))
            {
                plan = store.LoadPlan();
                if (plan == null || store.LoadPolicyHistory().Current.Canonical != policy.Canonical)
                    throw new Exception("Enrollment policy was not committed under protection");
            }
            using (var guard = WfpGuard.Recover(plan)) guard.VerifyProtection();
            using (var runtime = new GuardRuntime(name)) { }
            using (var guard = WfpGuard.Recover(plan)) guard.VerifyProtection();
            // Corrupt credentials: restart must refuse and retain the denials.
            File.WriteAllText(Path.Combine(directory, "enrollment.json"), "corrupted");
            bool refused = false;
            try { using (var runtime = new GuardRuntime(name)) { } }
            catch (InvalidOperationException) { refused = true; }
            if (!refused) throw new Exception("Corrupt enrollment accepted by runtime");
            using (var guard = WfpGuard.Recover(plan)) guard.VerifyProtection();
            Console.WriteLine("PASS enrollment restart stages persistent WFP denials and corruption retains them");
        }
        finally
        {
            // Only the uniquely owned test plan is removed; no routes or hosts change.
            if (plan == null && Directory.Exists(directory))
                using (var store = new GuardStore(name)) plan = store.LoadPlan();
            if (plan != null) using (var guard = WfpGuard.Recover(plan)) guard.Remove();
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }
}
