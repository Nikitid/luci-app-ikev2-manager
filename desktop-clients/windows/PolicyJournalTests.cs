using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Threading;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

internal static class PolicyJournalTests
{
    private static void Reject(Action action, string name)
    {
        try { action(); }
        catch (ArgumentException) { return; }
        catch (InvalidOperationException) { return; }
        catch (Win32Exception) { return; }
        throw new Exception("Journal unexpectedly accepted: " + name);
    }

    public static void Run(string fixtures)
    {
        var serializer = new JavaScriptSerializer();
        var values = (object[])serializer.DeserializeObject(File.ReadAllText(Path.Combine(fixtures, "policy-histories.json")));
        var document = (Dictionary<string, object>)((Dictionary<string, object>)values[0])["history"];
        var history = PolicyHistory.Restore(serializer.Serialize(document));
        var addresses = history.ProtectedAddresses().Select(IPAddress.Parse).ToArray();
        // Only reserved test addresses with a default route are eligible. Refuse
        // to test across an existing specific route or active TCP connection.
        foreach (var address in addresses)
            if (RouteObservation.Read(address).PrefixLength != 0 || IPGlobalProperties.GetIPGlobalProperties()
                .GetActiveTcpConnections().Any(c => c.RemoteEndPoint.Address.Equals(address)))
                throw new InvalidOperationException("Policy journal test addresses are already in use or specifically routed");
        string name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name);
        GuardReceipt plan = null;
        try
        {
            using (var newClient = new GuardRuntime(name)) newClient.StagePolicy(history.Current);
            using (var staged = new GuardStore(name))
            {
                var first = staged.LoadPolicyHistory();
                if (first == null || first.Current.Revision != 3 || first.ProtectedAddresses().Count != 1)
                    throw new Exception("Initial runtime policy staging failed");
                plan = staged.LoadPlan();
            }
            using (var firstGuard = WfpGuard.Recover(plan)) firstGuard.Remove();
            Directory.Delete(directory, true);
            plan = null;
            using (var store = new GuardStore(name))
            using (var initial = new WfpGuard(Guid.NewGuid(), new[] { addresses[0] }))
            {
                Reject(() => store.SavePolicyHistory(history), "missing guard plan");
                plan = initial.Receipt();
                store.SavePlan(plan);
                initial.InstallBlocking();
                Reject(() => store.SavePolicyHistory(history), "incomplete destination coverage");
                plan = WfpGuard.ExtendPlan(plan, addresses);
                store.ExtendPlan(plan);
                Reject(() => store.SavePolicyHistory(history), "planned but uninstalled destination");
                if (File.Exists(Path.Combine(directory, "policy.json"))) throw new Exception("Failed publication wrote policy history");
                using (var complete = WfpGuard.Resume(plan))
                {
                    store.SavePolicyHistory(history);
                    if (store.LoadPolicyHistory().Export() != history.Export()) throw new Exception("Journal round trip differs");
                    var current = (Dictionary<string, object>)document["current"];
                    current["revision"] = 4;
                    var resource = (Dictionary<string, object>)((object[])current["resources"])[0];
                    resource["id"] = "api"; resource["domain"] = "api.example.com"; resource["address"] = "172.31.254.1";
                    var next = history.Propose(ClientPolicy.Parse(serializer.Serialize(current)));
                    store.SavePolicyHistory(next);
                    string committed = File.ReadAllText(Path.Combine(directory, "policy.json"));
                    Reject(() => store.SavePolicyHistory(history), "revision rollback");
                    Reject(() => store.SavePolicyHistory(PolicyHistory.Begin(next.Current)), "discarded retired allocations");
                    if (File.ReadAllText(Path.Combine(directory, "policy.json")) != committed)
                        throw new Exception("Rejected update changed committed journal");
                }
            }
            using (var restarted = new GuardRuntime(name))
            {
                var current = (Dictionary<string, object>)document["current"];
                current["revision"] = 5;
                restarted.StagePolicy(ClientPolicy.Parse(serializer.Serialize(current)));
                Reject(() => restarted.StagePolicy(history.Current), "runtime rollback");
            }
            using (var reopened = new GuardStore(name))
            {
                var restored = reopened.LoadPolicyHistory();
                if (restored.Current.Revision != 5 || restored.ProtectedAddresses().Count != 2)
                    throw new Exception("Restart lost revision or retired protection");
            }
            RestrictedAccessTests.Run(directory, "guard.json", "policy.json");
            using (var running = new GuardRuntime(name))
            {
                File.WriteAllText(Path.Combine(directory, "policy.json"), "{");
                var deadline = Stopwatch.StartNew();
                bool refused = false;
                while (deadline.ElapsedMilliseconds < 9000)
                {
                    var status = (Dictionary<string, object>)serializer.DeserializeObject(File.ReadAllText(Path.Combine(directory, "status.json")));
                    if ((string)status["State"] == "error" && !(bool)status["Protected"]) { refused = true; break; }
                    Thread.Sleep(50);
                }
                if (!refused) throw new Exception("Running service ignored a corrupt policy journal");
            }

            Reject(() => { using (var broken = new GuardRuntime(name)) { } }, "corrupt journal on service startup");
            using (var retained = WfpGuard.Recover(plan)) retained.VerifyProtection();
            Console.WriteLine("Policy journal checks passed: verified guard first, monotonic updates, restart and corruption retain denial");
        }
        finally
        {
            if (plan == null && Directory.Exists(directory))
                using (var pending = new GuardStore(name)) plan = pending.LoadPlan();
            if (plan != null) using (var cleanup = WfpGuard.Resume(plan)) cleanup.Remove();
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }
}
