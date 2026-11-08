using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Threading;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

// The service as it fails in the field and comes back by itself: filters
// deleted from outside, the filtering engine restarted, a guard that cannot be
// put back, damaged journals and permissions at start, a stalled step, a
// service that does not stop for a reset, a reset with a damaged plan. Each
// runs an installation of its own, installed with the service control manager
// and its recovery actions, against the loopback address the WFP tests deny.
internal static class RecoveryTests
{
    private static Func<bool> tcp;
    private static IPAddress target;

    internal static void Run(Func<bool> probe, IPAddress denied)
    {
        tcp = probe; target = denied;
        FiltersDeletedFromOutside();
        EngineRestarted();
        GuardThatCannotComeBack();
        DamageAtStart();
        StalledStep();
        ResetOfAServiceThatDoesNotStop();
        ResetWithADamagedPlan();
        Console.WriteLine("Service recovery tests passed");
    }

    // С1. The filters go; the service puts them back within a step, and the
    // window between the deletion and the repair is no longer than a step.
    private static void FiltersDeletedFromOutside()
    {
        using (var installation = new Installation())
        {
            installation.Start();
            Require(!tcp(), "C1: the service denies before the filters are touched");
            int pid = installation.ProcessId();
            WfpGuard.RemoveRecorded(installation.Plan);
            var watch = Stopwatch.StartNew();
            long lastOpen = -1;
            bool back = false;
            while (watch.ElapsedMilliseconds < 12000)
            {
                bool open = tcp();
                if (open) lastOpen = watch.ElapsedMilliseconds;
                var view = installation.View();
                if (!open && view.State == "blocked" && view.GuardInstalled && WfpGuard.InstallationPresent(installation.Name, false)) { back = true; break; }
                Thread.Sleep(200);
            }
            Require(back, "C1: filters deleted from outside come back without a person");
            Require(lastOpen < 2600, "C1: the service was reachable outside the tunnel at most one step (" + lastOpen + " ms)");
            for (int probe = 0; probe < 10; probe++) { Require(!tcp(), "C1: denial holds after the repair"); Thread.Sleep(200); }
            Require(installation.ProcessId() == pid, "C1: the repair needs no restart of the service");
            Require(installation.Faults().Any(line => line.Contains(" guard ")), "C1: the failure is in the journal of faults");
            Require(installation.Queue.Pending().Count == 0, "C1: a repair that worked is not reported");
        }
    }

    // С2. The Base Filtering Engine restarts: every handle of the service dies.
    private static void EngineRestarted()
    {
        using (var installation = new Installation())
        {
            installation.Start();
            int pid = installation.ProcessId();
            string[] running;
            using (var engine = new ServiceController("BFE"))
                running = engine.DependentServices.Where(s => s.Status == ServiceControllerStatus.Running).Select(s => s.ServiceName).Reverse().ToArray();
            // Windows 10 and 11 refuse to stop the filtering engine even to an
            // administrator; where it does not stop, the scenario cannot be
            // made here and says so instead of passing.
            try { PowerShell("Restart-Service BFE -Force"); }
            catch (Exception)
            {
                Console.WriteLine("SKIP C2: the Base Filtering Engine does not stop on this Windows; a lost engine is not reproduced here");
                return;
            }
            foreach (string dependent in running)
                try { using (var service = new ServiceController(dependent)) { service.Refresh(); if (service.Status == ServiceControllerStatus.Stopped) service.Start(); } }
                catch (InvalidOperationException) { }
            bool back = Until(20000, () => {
                var view = installation.View();
                return view.State == "blocked" && view.GuardInstalled && !tcp();
            });
            Require(back, "C2: after BFE restarts the service opens the engine again and holds the denial");
            Require(installation.ProcessId() == pid, "C2: without a restart of the service");
            Require(installation.Faults().Any(line => line.Contains(" guard ")), "C2: the lost engine is in the journal of faults");
        }
    }

    // A guard that cannot be put back - its sublayer taken by a filter of
    // another program - is tried five times, then the process ends and the
    // service control manager starts it again; the new process asks for a reset.
    private static void GuardThatCannotComeBack()
    {
        using (var installation = new Installation())
        {
            installation.Start();
            int pid = installation.ProcessId();
            Guid foreign = Guid.NewGuid();
            Foreign.Occupy(installation.Plan, foreign);
            try
            {
                bool restarted = Until(120000, () => { int now = installation.ProcessId(); return now != 0 && now != pid; });
                Require(restarted, "a guard that does not come back in 5 attempts ends the process and the SCM starts it again");
                Require(Until(20000, () => installation.View().State == "needs_reset"), "the restarted service asks for a reset instead of failing to start");
                Require(installation.View().ConnectionError == "damaged_guard", "and says the filters cannot be put back");
                Require(installation.Queue.Pending().Any(e => (string)e["code"] == "guard_changed" && (string)e["phase"] == "tick"),
                    "the five failed repairs wait in the failure queue as guard_changed");
            }
            finally { Foreign.Release(installation.Plan.Owner, foreign); }
        }
    }

    // С3. A start on damaged permissions or a damaged plan does not fail.
    private static void DamageAtStart()
    {
        using (var installation = new Installation())
        {
            installation.Start();
            installation.Stop();
            var security = new DirectoryInfo(installation.Directory).GetAccessControl();
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                FileSystemRights.Modify, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            new DirectoryInfo(installation.Directory).SetAccessControl(security);
            installation.Start();
            var view = installation.View();
            Require(view.State == "needs_reset" && view.ConnectionError == "damaged_acl",
                "C3: changed permissions of the store: the service runs and asks for a reset (" + view.State + "/" + view.ConnectionError + ")");
            Require(!tcp(), "C3: the denials of the plan are in place all the same");
            Require(installation.Queue.Pending().Any(e => (string)e["code"] == "start_failed_acl"), "C3: and the failure waits in the queue");
            installation.Stop();
            File.WriteAllText(Path.Combine(installation.Directory, "guard.json"), "{");
            installation.Start();
            view = installation.View();
            Require(view.State == "needs_reset" && view.ConnectionError == "damaged_plan",
                "C3: a damaged plan: the service runs and asks for a reset (" + view.State + "/" + view.ConnectionError + ")");
        }
    }

    // С9. A step that never ends is ended by the watchdog; the service comes back.
    private static void StalledStep()
    {
        using (var installation = new Installation())
        {
            installation.Start();
            int pid = installation.ProcessId();
            File.WriteAllText(Path.Combine(installation.Directory, "test-stall-tick"), "");
            bool restarted = Until(60000, () => { int now = installation.ProcessId(); return now != 0 && now != pid; });
            File.Delete(Path.Combine(installation.Directory, "test-stall-tick"));
            Require(restarted, "C9: a stalled step ends the process and the SCM starts it again");
            Require(Until(60000, () => installation.View().State == "blocked"), "C9: the restarted service works");
            Require(installation.Queue.Pending().Any(e => (string)e["code"] == "tick_stalled"), "C9: the stall waits in the failure queue");
            Require(!tcp(), "C9: denial held throughout");
        }
    }

    // С6. The service does not stop: the reset ends it, takes everything away,
    // starts it again and says what went; a second reset finds nothing.
    private static void ResetOfAServiceThatDoesNotStop()
    {
        using (var installation = new Installation())
        {
            installation.Start();
            File.WriteAllText(Path.Combine(installation.Directory, "test-stall-stop"), "");
            var watch = Stopwatch.StartNew();
            var result = Maintenance.Reset(installation.Name, TimeSpan.FromSeconds(10));
            Require(result.Complete && watch.Elapsed < TimeSpan.FromMinutes(3),
                "C6: a reset of a service that does not stop comes to an end (" + String.Join("; ", result.Reasons) + " " + String.Join(",", result.Failed) + ", " + (int)watch.Elapsed.TotalSeconds + " s)");
            Require(result.Filters == 5, "C6: the reset says how many filters it took away (" + result.Filters + ")");
            Require(!WfpGuard.InstallationPresent(installation.Name, false), "C6: nothing of the guard is left in WFP");
            Require(tcp(), "C6: the service is reachable again");
            Require(Until(20000, () => installation.View().State == "enrollment_required"), "C6: the service runs again, ready to register");
            Require(!File.Exists(Path.Combine(installation.Directory, "guard.json")), "C6: the plan is gone with the store");
            var recorded = RemovalResult.Parse(installation.LastReset());
            Require(recorded != null && recorded.Complete && recorded.Filters == 5, "C6: the account of the reset is there for the window");
            var again = Maintenance.Reset(installation.Name, TimeSpan.FromSeconds(10));
            Require(again.Complete && again.Nothing, "C6: a second reset takes nothing away");
        }
    }

    // С7. The plan does not read: the reset finds the guard by its signs.
    private static void ResetWithADamagedPlan()
    {
        using (var installation = new Installation())
        {
            installation.Start();
            File.WriteAllText(Path.Combine(installation.Directory, "guard.json"), "{");
            var result = Maintenance.Reset(installation.Name, TimeSpan.FromSeconds(60));
            Require(result.Complete && result.Filters == 5, "C7: a reset with a damaged plan takes the guard away by its signs (" + String.Join("; ", result.Reasons) + " " + String.Join(",", result.Failed) + ", " + result.Filters + ")");
            Require(!WfpGuard.InstallationPresent(installation.Name, false) && tcp(), "C7: nothing of the guard is left");
        }
    }

    // ---- An installation of the service for one scenario ------------------

    private sealed class Installation : IDisposable
    {
        internal readonly string Name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
        internal readonly string Directory, Binaries;
        internal readonly GuardReceipt Plan;
        internal readonly FailureQueue Queue;

        internal Installation()
        {
            string data = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            Directory = Path.Combine(data, Name);
            Binaries = Path.Combine(data, Name + "-bin");
            Queue = new FailureQueue(Name);
            using (var store = new GuardStore(Name))
            using (var guard = new WfpGuard(Guid.NewGuid(), new[] { target }))
            {
                Plan = guard.Receipt();
                store.SavePlan(Plan);
            }
            // The binary lives apart from the store: a reset deletes the store.
            // Its folder is made with the same protected permissions.
            using (new GuardStore(Name + "-bin")) { }
            File.Copy(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ClientService.exe"), Path.Combine(Binaries, "ClientService.exe"));
            string binary = "\"" + Path.Combine(Binaries, "ClientService.exe") + "\" --test " + Name;
            Sc("create " + Name + " binPath= \"" + binary.Replace("\"", "\\\"") + "\" start= demand");
            Sc("failure " + Name + " reset= 60 actions= restart/2000/restart/2000/restart/2000");
        }

        internal void Start()
        {
            using (var service = new ServiceController(Name))
            {
                service.Refresh();
                if (service.Status != ServiceControllerStatus.Running) service.Start();
                service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
            }
            Require(Until(15000, () => { var state = View().State; return state != "status_missing" && state != "status_process_mismatch" && state != "service_stopped"; }),
                Name.Substring(18, 6) + ": the service publishes its status");
        }

        internal void Stop()
        {
            using (var service = new ServiceController(Name))
            {
                service.Refresh();
                if (service.Status == ServiceControllerStatus.Stopped) return;
                service.Stop();
                service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(60));
            }
        }

        internal ClientView View() { return ClientStatusReader.Read(Name); }

        internal int ProcessId()
        {
            try
            {
                var status = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(Directory, "status.json")));
                using (var service = new ServiceController(Name))
                    return service.Status == ServiceControllerStatus.Running ? (int)status["ProcessId"] : 0;
            }
            catch (Exception) { return 0; }
        }

        internal string[] Faults()
        {
            try { return File.ReadAllLines(Path.Combine(Directory, "faults.log")); }
            catch (Exception) { return new string[0]; }
        }

        internal string LastReset()
        {
            using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(Maintenance.RecordKey(Name)))
                return key == null ? null : key.GetValue("LastReset") as string;
        }

        public void Dispose()
        {
            try { File.Delete(Path.Combine(Directory, "test-stall-tick")); File.Delete(Path.Combine(Directory, "test-stall-stop")); } catch (Exception) { }
            try
            {
                ServiceControl.SetStartType(Name, ServiceControl.Disabled);
                using (var service = new ServiceController(Name))
                {
                    service.Refresh();
                    if (service.Status != ServiceControllerStatus.Stopped)
                    {
                        try { service.Stop(); service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(20)); }
                        catch (Exception) { ServiceControl.Kill(Name); }
                    }
                }
            }
            catch (Exception) { }
            try { Sc("delete " + Name); } catch (Exception) { }
            try { WfpGuard.RemoveRecorded(Plan); } catch (Exception) { }
            try { WfpGuard.RemoveInstallation(Name, false); } catch (Exception) { }
            foreach (string folder in new[] { Directory, Binaries })
                for (int attempt = 0; attempt < 10 && System.IO.Directory.Exists(folder); attempt++)
                    try { System.IO.Directory.Delete(folder, true); } catch (Exception) { Thread.Sleep(500); }
            try { Queue.Forget(); } catch (Exception) { }
            try { Microsoft.Win32.Registry.LocalMachine.DeleteSubKeyTree(Maintenance.RecordKey(Name), false); } catch (Exception) { }
        }
    }

    // A sublayer under the guard's key with another weight and a filter of
    // its own inside: what another program could leave, and what the service
    // can neither verify nor delete.
    private static class Foreign
    {
        // In one transaction, so the service never sees the guard gone and
        // puts it back before the other program's sublayer is in.
        internal static void Occupy(GuardReceipt plan, Guid filter)
        {
            Guid key = plan.Owner;
            IntPtr engine = Open();
            var memory = new List<IntPtr>();
            Check(WfpGuard.Native.FwpmTransactionBegin0(engine, 0));
            try
            {
                foreach (Guid planned in plan.Filters) { Guid copy = planned; WfpGuard.Native.FwpmFilterDeleteByKey0(engine, ref copy); }
                Guid old = key;
                Check(WfpGuard.Native.FwpmSubLayerDeleteByKey0(engine, ref old));
                Func<object, IntPtr> put = value => { IntPtr p = Marshal.AllocHGlobal(Marshal.SizeOf(value)); Marshal.StructureToPtr(value, p, false); memory.Add(p); return p; };
                IntPtr name = Marshal.StringToHGlobalUni("Another program"); memory.Add(name);
                var layer = new WfpGuard.Native.Sublayer { Key = key, Display = new WfpGuard.Native.Display { Name = name }, Weight = 0x100 };
                Check(WfpGuard.Native.FwpmSubLayerAdd0(engine, ref layer, IntPtr.Zero));
                var condition = new WfpGuard.Native.Condition { Key = WfpGuard.Native.RemoteAddress, Value = new WfpGuard.Native.Value {
                    Type = 256, Pointer = put(new WfpGuard.Native.AddressMask { Address = 0x7F000009, Mask = UInt32.MaxValue }) } };
                var added = new WfpGuard.Native.Filter { Key = filter, Display = new WfpGuard.Native.Display { Name = name },
                    Layer = WfpGuard.Native.ConnectV4, Sublayer = key, Weight = new WfpGuard.Native.Value { Type = 1, Number = 1 },
                    ConditionCount = 1, Conditions = put(condition), Action = new WfpGuard.Native.Action { Type = 0x1001 } };
                ulong id;
                Check(WfpGuard.Native.FwpmFilterAdd0(engine, ref added, IntPtr.Zero, out id));
                Check(WfpGuard.Native.FwpmTransactionCommit0(engine));
            }
            catch { WfpGuard.Native.FwpmTransactionAbort0(engine); throw; }
            finally { foreach (IntPtr p in memory) Marshal.FreeHGlobal(p); WfpGuard.Native.FwpmEngineClose0(engine); }
        }

        internal static void Release(Guid key, Guid filter)
        {
            IntPtr engine = Open();
            try
            {
                WfpGuard.Native.FwpmFilterDeleteByKey0(engine, ref filter);
                WfpGuard.Native.FwpmSubLayerDeleteByKey0(engine, ref key);
            }
            finally { WfpGuard.Native.FwpmEngineClose0(engine); }
        }

        private static IntPtr Open()
        {
            var session = new WfpGuard.Native.Session { Key = Guid.NewGuid() };
            IntPtr handle;
            Check(WfpGuard.Native.FwpmEngineOpen0(null, 10, IntPtr.Zero, ref session, out handle));
            return handle;
        }

        private static void Check(uint error) { if (error != 0) throw new Exception("WFP test setup failed: 0x" + error.ToString("X8")); }
    }

    private static bool Until(int milliseconds, Func<bool> condition)
    {
        var watch = Stopwatch.StartNew();
        while (watch.ElapsedMilliseconds < milliseconds)
        {
            try { if (condition()) return true; } catch (IOException) { }
            Thread.Sleep(250);
        }
        return false;
    }

    private static void PowerShell(string command)
    {
        using (var process = Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
            "-NoProfile -NonInteractive -Command \"" + command + "\"") { UseShellExecute = false, CreateNoWindow = true }))
        {
            if (!process.WaitForExit(120000)) { process.Kill(); throw new Exception("PowerShell timed out: " + command); }
            if (process.ExitCode != 0) throw new Exception("PowerShell failed: " + command);
        }
    }

    private static void Sc(string arguments)
    {
        using (var process = Process.Start(new ProcessStartInfo {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "sc.exe"),
            Arguments = arguments, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }))
        {
            if (!process.WaitForExit(10000)) { process.Kill(); throw new Exception("SCM command timed out"); }
            if (process.ExitCode != 0) throw new Exception("SCM command failed: " + process.ExitCode + " (" + arguments.Split(' ')[0] + ")");
        }
    }

    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception("Recovery failed: " + name);
        Console.WriteLine("PASS " + name);
    }
}
