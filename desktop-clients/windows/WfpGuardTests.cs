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
            Contention(port);
            Migration(port);
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

    // Another program's permissions for the guarded address, each in a
    // dynamic session of its own that takes them away when it closes. Where
    // WFP leaves the order open - an equal sublayer, or a stranger inside the
    // guard's own - the outcome is printed, not required.
    private static void Contention(int port)
    {
        using (var guard = new WfpGuard(Guid.NewGuid(), new[] { Target }))
        {
            GuardReceipt receipt = guard.Receipt();
            try
            {
                guard.InstallBlocking();
                Require(SublayerWeight(receipt.Owner) == 0xFFFF, "guard sublayer is the heaviest");
                using (new Stranger(0xFFFE, true, Guid.Empty))
                    Require(!Probe(port), "hard permission in a lighter sublayer stays denied");
                using (new Stranger(0xFFFF, false, Guid.Empty))
                    Require(!Probe(port), "soft permission in an equal sublayer stays denied");
                using (new Stranger(0xFFFF, true, Guid.Empty))
                    Console.WriteLine("Hard permission in an equal sublayer passes: " + Probe(port));
                using (new Stranger(0, false, receipt.Owner))
                    Console.WriteLine("Permission inside the guard sublayer passes: " + Probe(port));
                guard.AllowInterface(LoopbackLuid());
                Require(Probe(port), "own tunnel permission passes");
                guard.Block();
                Require(!Probe(port), "contention scenario ends denied");
            }
            finally { guard.Remove(); }
        }
        Require(Probe(port), "contention scenario restores baseline");
    }

    // A guard installed before 2.2.6: its sublayer at 0x7000 and its denials
    // without a hard action. It is recovered as it is and moved up when it is
    // next installed, without a moment that denies nothing.
    private static void Migration(int port)
    {
        GuardReceipt receipt;
        using (var planned = new WfpGuard(Guid.NewGuid(), new[] { Target })) receipt = planned.Receipt();
        bool installed = false;
        try
        {
            using (var legacy = new Stranger(receipt))
            {
                installed = true;
                Require(!Probe(port), "legacy guard denies");
                using (var recovered = WfpGuard.Recover(receipt)) recovered.VerifyProtection();
                Require(SublayerWeight(receipt.Owner) == 0x7000, "legacy guard recovered unchanged");
                var watching = new Thread(() => { while (!stopping && Volatile.Read(ref watch)) if (Probe(port)) Interlocked.Increment(ref passed); });
                Volatile.Write(ref watch, true); passed = 0;
                watching.Start();
                using (var moved = WfpGuard.Resume(receipt)) moved.VerifyProtection();
                Volatile.Write(ref watch, false);
                watching.Join();
                Require(Volatile.Read(ref passed) == 0, "nothing passes while the guard moves");
                Require(SublayerWeight(receipt.Owner) == 0xFFFF && !Probe(port), "legacy guard moved to the heaviest sublayer");
                using (var again = WfpGuard.Resume(receipt)) again.VerifyProtection();
            }
        }
        finally { if (installed) using (var guard = WfpGuard.Recover(receipt)) guard.Remove(); }
        Require(Probe(port), "migration scenario restores baseline");
    }

    private static bool watch;
    private static int passed;

    private static ushort SublayerWeight(Guid key)
    {
        IntPtr engine = IntPtr.Zero, pointer = IntPtr.Zero;
        var session = new WfpGuard.Native.Session { Key = Guid.NewGuid(), Flags = 1, Timeout = 5000 };
        Check(WfpGuard.Native.FwpmEngineOpen0(null, 10, IntPtr.Zero, ref session, out engine));
        try
        {
            Check(WfpGuard.Native.FwpmSubLayerGetByKey0(engine, ref key, out pointer));
            return ((WfpGuard.Native.Sublayer)System.Runtime.InteropServices.Marshal.PtrToStructure(pointer, typeof(WfpGuard.Native.Sublayer))).Weight;
        }
        finally
        {
            if (pointer != IntPtr.Zero) WfpGuard.Native.FwpmFreeMemory0(ref pointer);
            WfpGuard.Native.FwpmEngineClose0(engine);
        }
    }

    private static void Check(uint error)
    {
        if (error != 0) throw new System.ComponentModel.Win32Exception(unchecked((int)error), "WFP test operation failed: 0x" + error.ToString("X8"));
    }

    private sealed class Stranger : IDisposable
    {
        private IntPtr engine;
        private readonly System.Collections.Generic.List<IntPtr> memory = new System.Collections.Generic.List<IntPtr>();

        // Permissions of another program in a sublayer of the given weight,
        // or inside an existing one.
        public Stranger(ushort weight, bool hard, Guid inside)
        {
            Open(true);
            Guid layer = inside;
            if (layer == Guid.Empty)
            {
                layer = Guid.NewGuid();
                var sublayer = new WfpGuard.Native.Sublayer { Key = layer, Weight = weight,
                    Display = new WfpGuard.Native.Display { Name = Text("Stranger sublayer") } };
                Check(WfpGuard.Native.FwpmSubLayerAdd0(engine, ref sublayer, IntPtr.Zero));
            }
            foreach (Guid level in new[] { WfpGuard.Native.ConnectV4, WfpGuard.Native.PacketV4, WfpGuard.Native.ReceivePacketV4 })
                Add(Guid.NewGuid(), level, layer, hard ? 8u : 0u, 0x1002, 15, "Stranger permit");
        }

        // The guard as versions before 2.2.6 installed it, persistent.
        public Stranger(GuardReceipt receipt)
        {
            Open(false);
            var sublayer = new WfpGuard.Native.Sublayer { Key = receipt.Owner, Flags = 1, Weight = 0x7000,
                Display = new WfpGuard.Native.Display { Name = Text("IKEv2 Manager client guard") } };
            Check(WfpGuard.Native.FwpmSubLayerAdd0(engine, ref sublayer, IntPtr.Zero));
            int index = 0;
            Add(receipt.Filters[index++], WfpGuard.Native.ConnectV4, receipt.Owner, 1, 0x1001, 1, "IKEv2 Manager deny bypass");
            Add(receipt.Filters[index++], WfpGuard.Native.PacketV4, receipt.Owner, 1, 0x1001, 1, "IKEv2 Manager deny bypass");
            Add(receipt.Filters[index++], WfpGuard.Native.PacketV4, receipt.Owner, 2, 0x1001, 1, "IKEv2 Manager deny bypass");
            Add(receipt.Filters[index++], WfpGuard.Native.ReceivePacketV4, receipt.Owner, 1, 0x1001, 1, "IKEv2 Manager deny bypass");
            Add(receipt.Filters[index++], WfpGuard.Native.ReceivePacketV4, receipt.Owner, 2, 0x1001, 1, "IKEv2 Manager deny bypass");
        }

        private void Open(bool dynamic)
        {
            var session = new WfpGuard.Native.Session { Key = Guid.NewGuid(), Flags = dynamic ? 1u : 0u, Timeout = 5000 };
            Check(WfpGuard.Native.FwpmEngineOpen0(null, 10, IntPtr.Zero, ref session, out engine));
        }

        private void Add(Guid key, Guid level, Guid layer, uint flags, uint action, ulong weight, string name)
        {
            var condition = new WfpGuard.Native.Condition { Key = WfpGuard.Native.RemoteAddress, Value = new WfpGuard.Native.Value {
                Type = 256, Pointer = Block(new WfpGuard.Native.AddressMask { Address = 0x7F000002, Mask = UInt32.MaxValue }) } };
            var filter = new WfpGuard.Native.Filter { Key = key, Flags = flags, Layer = level, Sublayer = layer,
                Display = new WfpGuard.Native.Display { Name = Text(name) },
                Weight = new WfpGuard.Native.Value { Type = 1, Number = weight },
                ConditionCount = 1, Conditions = Block(condition), Action = new WfpGuard.Native.Action { Type = action } };
            ulong id;
            Check(WfpGuard.Native.FwpmFilterAdd0(engine, ref filter, IntPtr.Zero, out id));
        }

        private IntPtr Text(string value)
        {
            IntPtr pointer = System.Runtime.InteropServices.Marshal.StringToHGlobalUni(value);
            memory.Add(pointer);
            return pointer;
        }

        private IntPtr Block<T>(T value) where T : struct
        {
            IntPtr pointer = System.Runtime.InteropServices.Marshal.AllocHGlobal(System.Runtime.InteropServices.Marshal.SizeOf(typeof(T)));
            memory.Add(pointer);
            System.Runtime.InteropServices.Marshal.StructureToPtr(value, pointer, false);
            return pointer;
        }

        public void Dispose()
        {
            if (engine != IntPtr.Zero) { WfpGuard.Native.FwpmEngineClose0(engine); engine = IntPtr.Zero; }
            foreach (IntPtr pointer in memory) System.Runtime.InteropServices.Marshal.FreeHGlobal(pointer);
            memory.Clear();
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
