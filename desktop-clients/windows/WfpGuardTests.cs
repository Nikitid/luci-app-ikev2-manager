using System;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading;
using System.Diagnostics;
using System.IO;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

internal static class WfpGuardTests
{
    // Packet probes use loopback. The separate policy journal scenario briefly
    // denies two unused private destinations after checking their routes.
    // No test changes routes, hosts or another firewall.
    private static readonly IPAddress Target = IPAddress.Parse("127.0.0.2");
    private static volatile bool stopping;

    private static int Main(string[] args)
    {
        if (args.Length == 3 && args[0] == "--journal")
        {
            using (var store = new GuardStore(args[1]))
            using (var planned = new WfpGuard(Guid.NewGuid(), new[] { Target }))
            {
                store.SavePlan(planned.Receipt());
                if (args[2] == "installed") planned.InstallBlocking();
                Console.WriteLine("READY");
                Thread.Sleep(Timeout.Infinite);
            }
            return 0;
        }
        if (args.Length == 2 && args[0] == "--hold")
        {
            var receipt = new JavaScriptSerializer().Deserialize<GuardReceipt>(File.ReadAllText(args[1]));
            using (var owner = WfpGuard.Recover(receipt))
            {
                owner.AllowInterface(LoopbackLuid());
                Console.WriteLine("READY");
                Thread.Sleep(Timeout.Infinite);
            }
            return 0;
        }
        var listener = new TcpListener(Target, 0);
        WfpGuard guard = null;
        Process child = null;
        string receiptPath = Path.GetTempFileName();
        try
        {
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var worker = new Thread(() => Echo(listener)) { IsBackground = true };
            worker.Start();
            Require(Probe(port), "baseline echo");
            Require(InboundDatagram(), "baseline incoming UDP");
            JournalCrash(port, "planned");
            JournalCrash(port, "installed");
            ServiceIntegrationTests.Run(() => Probe(port), InboundDatagram, Target);
            if (args.Length != 1) throw new ArgumentException("Policy fixtures directory required");
            PolicyJournalTests.Run(args[0]);
            EnrollmentGuardTests.Run(args[0]);
            ulong luid = LoopbackLuid();
            guard = new WfpGuard(Guid.NewGuid(), new[] { Target });
            guard.InstallBlocking();
            Require(!Probe(port), "persistent deny");
            Require(!InboundDatagram(), "incoming UDP denied");
            guard.AllowInterface(UInt64.MaxValue);
            Require(!Probe(port), "unrelated interface remains denied");
            guard.AllowInterface(luid);
            Require(Probe(port), "verified interface permission");
            Require(InboundDatagram(), "incoming UDP permitted on verified interface");
            using (var established = new TcpClient())
            {
                established.Connect(Target, port);
                established.ReceiveTimeout = established.SendTimeout = 1500;
                Require(Exchange(established), "established connection before revocation");
                guard.Block();
                Require(!Exchange(established), "established connection stops after revocation");
            }
            Require(!Probe(port), "closing dynamic permission restores deny");
            Require(!InboundDatagram(), "incoming UDP stops after revocation");
            GuardReceipt saved = guard.Receipt();
            RejectReceipt(new GuardReceipt { Owner = Guid.NewGuid(), Addresses = saved.Addresses, Filters = saved.Filters },
                "foreign owner rejected");
            RejectReceipt(new GuardReceipt { Owner = saved.Owner, Addresses = new[] { "127.0.0.3" }, Filters = saved.Filters },
                "changed destination rejected");
            RejectReceipt(new GuardReceipt { Owner = saved.Owner, Addresses = saved.Addresses,
                Filters = Enumerable.Repeat(saved.Filters[0], saved.Filters.Length).ToArray() }, "duplicated filters rejected");
            Require(!Probe(port), "invalid recovery preserves denial");
            File.WriteAllText(receiptPath, new JavaScriptSerializer().Serialize(saved));
            guard.Dispose();
            guard = null;
            Require(!Probe(port), "persistent deny survives engine close");
            guard = WfpGuard.Recover(saved);
            child = Process.Start(new ProcessStartInfo {
                FileName = Process.GetCurrentProcess().MainModule.FileName,
                Arguments = "--hold \"" + receiptPath + "\"", UseShellExecute = false,
                RedirectStandardOutput = true, CreateNoWindow = true
            });
            var ready = child.StandardOutput.ReadLineAsync();
            Require(ready.Wait(5000) && ready.Result == "READY", "permission worker starts");
            Require(Probe(port), "permission owned by worker");
            child.Kill();
            Require(child.WaitForExit(5000), "permission worker stopped");
            bool denied = false;
            for (int attempt = 0; attempt < 20 && !denied; attempt++)
            {
                denied = !Probe(port);
                if (!denied) Thread.Sleep(100);
            }
            Require(denied, "worker crash restores persistent deny");
            guard.Remove();
            Require(Probe(port), "explicit removal restores baseline");
            Require(InboundDatagram(), "explicit removal restores incoming UDP");
            Console.WriteLine("WFP native guard tests passed");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally
        {
            if (child != null) { if (!child.HasExited) { child.Kill(); child.WaitForExit(5000); } child.Dispose(); }
            if (guard != null) { try { guard.Remove(); } finally { guard.Dispose(); } }
            stopping = true;
            listener.Stop();
            File.Delete(receiptPath);
        }
    }

    private static ulong LoopbackLuid()
    {
        var loopback = NetworkInterface.GetAllNetworkInterfaces().First(n => n.NetworkInterfaceType == NetworkInterfaceType.Loopback);
        return WfpGuard.InterfaceLuid((uint)loopback.GetIPProperties().GetIPv4Properties().Index);
    }

    private static void JournalCrash(int port, string stage)
    {
        string name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name);
        WfpGuard resumed = null;
        Process process = null;
        GuardStore store = null;
        try
        {
            process = Process.Start(new ProcessStartInfo {
                FileName = Process.GetCurrentProcess().MainModule.FileName,
                Arguments = "--journal " + name + " " + stage, UseShellExecute = false,
                RedirectStandardOutput = true, CreateNoWindow = true
            });
            var ready = process.StandardOutput.ReadLineAsync();
            Require(ready.Wait(5000) && ready.Result == "READY", stage + " journal worker starts");
            bool locked = false;
            try { using (var duplicate = new GuardStore(name)) { } }
            catch (IOException) { locked = true; }
            Require(locked, "second controller is excluded");
            Require(Probe(port) == (stage == "planned"), "journal precedes filter installation");
            process.Kill();
            Require(process.WaitForExit(5000), "journal worker stopped");
            store = new GuardStore(name);
            GuardReceipt saved = store.LoadPlan();
            resumed = WfpGuard.Resume(saved);
            Require(!Probe(port) && !InboundDatagram(), stage + " crash resumes denial");
            resumed.Dispose();
            resumed = null;
            resumed = WfpGuard.Resume(store.LoadPlan());
            Require(saved.Filters.SequenceEqual(resumed.Receipt().Filters), "reconciliation retains filter identities");
            bool immutable = false;
            try { store.SavePlan(saved); }
            catch (InvalidOperationException) { immutable = true; }
            Require(immutable, "existing protection plan cannot be overwritten");
            string path = Path.Combine(directory, "guard.json");
            var permissions = File.GetAccessControl(path);
            string original = permissions.GetSecurityDescriptorSddlForm(System.Security.AccessControl.AccessControlSections.Access);
            permissions.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(
                new System.Security.Principal.SecurityIdentifier(System.Security.Principal.WellKnownSidType.BuiltinUsersSid, null),
                System.Security.AccessControl.FileSystemRights.Write, System.Security.AccessControl.AccessControlType.Allow));
            File.SetAccessControl(path, permissions);
            bool unsafeRejected = false;
            try { store.LoadPlan(); }
            catch (InvalidOperationException) { unsafeRejected = true; }
            finally
            {
                var restored = new System.Security.AccessControl.FileSecurity();
                restored.SetSecurityDescriptorSddlForm(original, System.Security.AccessControl.AccessControlSections.Access);
                File.SetAccessControl(path, restored);
            }
            Require(unsafeRejected, "unsafe journal permissions rejected");
            IPAddress added = IPAddress.Parse("127.0.0.3");
            Require(InboundDatagram(added), "new destination starts outside existing guard");
            GuardReceipt extended = WfpGuard.ExtendPlan(saved, new[] { added });
            store.ExtendPlan(extended);
            resumed.Dispose();
            resumed = null;
            resumed = WfpGuard.Resume(store.LoadPlan());
            Require(!InboundDatagram(added) && !InboundDatagram(), "policy extension protects old and new destinations");
            bool removalRejected = false;
            try { store.ExtendPlan(saved); }
            catch (InvalidOperationException) { removalRejected = true; }
            Require(removalRejected && store.LoadPlan().Filters.SequenceEqual(extended.Filters),
                "policy update cannot discard existing protection");
            resumed.Remove();
            Require(Probe(port) && InboundDatagram() && InboundDatagram(added), "journal scenario restores baseline");
        }
        finally
        {
            if (process != null) { if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); } process.Dispose(); }
            if (resumed == null && Directory.Exists(directory))
            {
                if (store == null) store = new GuardStore(name);
                GuardReceipt saved = store.LoadPlan();
                if (saved != null) resumed = WfpGuard.Resume(saved);
            }
            if (resumed != null) { try { resumed.Remove(); } finally { resumed.Dispose(); } }
            if (store != null) store.Dispose();
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }

    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception("WFP behavior failed: " + name);
        Console.WriteLine("PASS " + name);
    }

    private static void RejectReceipt(GuardReceipt receipt, string name)
    {
        bool rejected = false;
        try { using (var recovered = WfpGuard.Recover(receipt)) { } }
        catch (InvalidOperationException) { rejected = true; }
        catch (ArgumentException) { rejected = true; }
        catch (System.ComponentModel.Win32Exception) { rejected = true; }
        Require(rejected, name);
    }

    private static bool Probe(int port)
    {
        using (var client = new TcpClient())
        {
            try
            {
                var pending = client.BeginConnect(Target, port, null, null);
                using (pending.AsyncWaitHandle)
                    if (!pending.AsyncWaitHandle.WaitOne(1500)) return false;
                client.EndConnect(pending);
                client.ReceiveTimeout = client.SendTimeout = 1500;
                return Exchange(client);
            }
            catch (SocketException) { return false; }
            catch (System.IO.IOException) { return false; }
        }
    }

    private static bool Exchange(TcpClient client)
    {
        try
        {
            var stream = client.GetStream();
            stream.WriteByte(42);
            return stream.ReadByte() == 42;
        }
        catch (SocketException) { return false; }
        catch (IOException) { return false; }
    }

    private static bool InboundDatagram()
    {
        return InboundDatagram(Target);
    }

    private static bool InboundDatagram(IPAddress senderAddress)
    {
        using (var receiver = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0)))
        using (var sender = new UdpClient(new IPEndPoint(senderAddress, 0)))
        {
            receiver.Client.ReceiveTimeout = 500;
            sender.Send(new byte[] { 42 }, 1, (IPEndPoint)receiver.Client.LocalEndPoint);
            IPEndPoint source = null;
            try
            {
                byte[] data = receiver.Receive(ref source);
                return source.Address.Equals(senderAddress) && data.Length == 1 && data[0] == 42;
            }
            catch (SocketException error)
            {
                if (error.SocketErrorCode == SocketError.TimedOut) return false;
                throw;
            }
        }
    }

    private static void Echo(TcpListener listener)
    {
        while (!stopping)
        {
            try
            {
                using (var client = listener.AcceptTcpClient())
                {
                    client.ReceiveTimeout = client.SendTimeout = 1500;
                    var stream = client.GetStream();
                    int value;
                    while ((value = stream.ReadByte()) >= 0) stream.WriteByte((byte)value);
                }
            }
            catch (SocketException) { if (stopping) return; }
            catch (System.IO.IOException) { }
            catch (ObjectDisposedException) { return; }
        }
    }
}
