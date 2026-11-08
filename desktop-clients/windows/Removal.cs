using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.ServiceProcess;
using System.Web.Script.Serialization;

namespace IkeV2Manager.Client
{
    // Everything the service set up on this computer, taken away while the
    // service is stopped: by reset and by uninstallation, never by a stop or a
    // crash. Every step is tried whatever became of the others, and what the
    // plan cannot say - a journal that does not read, a guard half installed -
    // is found by its signs: the WFP sublayers named for this installation,
    // the connections and name rules named "Waypoint <owner>", the marked block
    // of the hosts file. The folder goes only when nothing is left, so a next
    // reset finds what this one could not take.
    internal static class Removal
    {
        internal const string Product = "IKEv2ManagerClient";

        internal static RemovalResult Run(string name)
        {
            var result = new RemovalResult();
            bool product = name == Product;
            using (var service = new ServiceController(name))
            {
                try { if (service.Status != ServiceControllerStatus.Stopped) { result.Fail("service_running"); return result; } }
                catch (InvalidOperationException) { }
            }
            string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name);
            GuardReceipt plan = null, networks = null;
            Guid entry = Guid.Empty;
            Action<string, Action> step = (what, action) => { try { action(); } catch (Exception error) { result.Fail(what, error); } };
            if (Directory.Exists(directory))
            {
                GuardStore store = null;
                step("folder", () => { bool resecured; store = GuardStore.OpenRepairing(name, out resecured); });
                if (store != null)
                    using (store)
                    {
                        // Each journal on its own: a damaged one leaves the others readable.
                        try { plan = store.LoadPlan(); } catch (Exception) { }
                        try { networks = store.LoadNetworksPlan(); } catch (Exception) { }
                        try { entry = store.LoadVpnEntry(); } catch (Exception) { }
                        try { result.Registration = File.Exists(Path.Combine(directory, "enrollment.json")) || File.Exists(Path.Combine(directory, "enrollment.pending")); } catch (Exception) { }
                        step("hosts", () => {
                            int lines = SystemHosts.Managed();
                            if (lines > 0) { SystemHosts.Remove(store); result.Hosts = lines; }
                        });
                    }
            }
            else if (product)
            {
                // Nothing left of the folder; a block in hosts may still be.
                step("hosts", () => { if (SystemHosts.Managed() > 0) result.Fail("hosts"); });
            }
            if (plan != null)
            {
                step("connection", () => {
                    if (entry == Guid.Empty) return;
                    var profile = ManagedVpnProfile.FromJournal(plan.Owner, entry);
                    try { RasTunnel.Release(profile.EntryId, profile.Phonebook); } catch (Exception) { }
                    ManagedVpnProfile.Remove(plan.Owner, entry);
                    result.Connections++;
                });
                step("names", () => ManagedVpnProfile.RemoveNames(plan.Owner));
            }
            // Only the product's own installation has its connections found by
            // name: a test installation never makes one.
            if (product)
                step("connection", () => {
                    int[] purged = ManagedVpnProfile.Purge();
                    result.Connections += purged[0]; result.NameRules += purged[1];
                });
            step("filters", () => result.Filters += WfpGuard.RemoveRecorded(plan));
            step("filters", () => result.Filters += WfpGuard.RemoveRecorded(networks));
            step("filters", () => result.Filters += Math.Max(0, WfpGuard.RemoveInstallation(name, product)));
            step("filters", () => { if (WfpGuard.InstallationPresent(name, product)) throw new InvalidOperationException(); });
            if (result.Complete && Directory.Exists(directory))
            {
                step("folder", () => { Directory.Delete(directory, true); result.Folder = true; });
            }
            return result;
        }
    }
}
