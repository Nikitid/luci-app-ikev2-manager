using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;

namespace IkeV2Manager.Client
{
    public sealed class GuardReceipt
    {
        public GuardReceipt() { Version = 1; }
        public int Version { get; set; }
        public Guid Owner { get; set; }
        public string[] Addresses { get; set; }
        public Guid[] Filters { get; set; }
    }

    // Persistent denials are deliberately not removed by Dispose. Only the
    // interface-specific permissions belong to a dynamic WFP session.
    public sealed class WfpGuard : IDisposable
    {
        private readonly Guid sublayer;
        private readonly List<Guid> filters = new List<Guid>();
        private readonly List<uint> addresses;
        private IntPtr engine;
        private IntPtr permissionEngine;
        private bool installed;

        public WfpGuard(Guid owner, IEnumerable<IPAddress> destinations)
        {
            if (IntPtr.Size != 8) throw new PlatformNotSupportedException("64-bit Windows required");
            sublayer = owner;
            if (owner == Guid.Empty) throw new ArgumentException("Guard owner required");
            if (destinations == null) throw new ArgumentNullException("destinations");
            addresses = new List<uint>();
            foreach (IPAddress destination in destinations)
            {
                if (destination == null) throw new ArgumentException("Destination required");
                byte[] bytes = destination.GetAddressBytes();
                if (bytes.Length != 4) throw new ArgumentException("IPv4 destination required");
                uint address = ((uint)bytes[0] << 24) | ((uint)bytes[1] << 16) | ((uint)bytes[2] << 8) | bytes[3];
                if (address == 0 || address == UInt32.MaxValue || addresses.Contains(address))
                    throw new ArgumentException("Invalid or duplicate destination");
                addresses.Add(address);
            }
            if (addresses.Count == 0 || addresses.Count > 4096) throw new ArgumentException("Destinations required");
            for (int i = 0; i < addresses.Count * 5; i++) filters.Add(Guid.NewGuid());
            engine = Open(false);
        }

        public void InstallBlocking()
        {
            if (installed) throw new InvalidOperationException("Guard already installed");
            Check(Native.FwpmTransactionBegin0(engine, 0));
            try
            {
                using (var memory = new NativeMemory())
                {
                    var layer = new Native.Sublayer {
                        Key = sublayer, Display = new Native.Display { Name = memory.String("IKEv2 Manager client guard") },
                        Flags = 1, Weight = 0x7000
                    };
                    uint error = Native.FwpmSubLayerAdd0(engine, ref layer, IntPtr.Zero);
                    if (error != 0x80320009) Check(error); // FWP_E_ALREADY_EXISTS: verify, never replace.
                }
                VerifySublayer();
                int index = 0;
                foreach (uint address in addresses)
                {
                    AddFilter(engine, address, Native.ConnectV4, false, 1, 0, filters[index++]);
                    AddFilter(engine, address, Native.PacketV4, false, 1, 0, filters[index++]);
                    AddFilter(engine, address, Native.PacketV4, false, 2, 0, filters[index++]);
                    AddFilter(engine, address, Native.ReceivePacketV4, false, 1, 0, filters[index++]);
                    AddFilter(engine, address, Native.ReceivePacketV4, false, 2, 0, filters[index++]);
                }
                VerifyInstalled();
                Check(Native.FwpmTransactionCommit0(engine));
                installed = true;
            }
            catch { Native.FwpmTransactionAbort0(engine); throw; }
        }

        public void AllowInterface(ulong interfaceLuid)
        {
            if (!installed || interfaceLuid == 0) throw new InvalidOperationException("Installed guard and verified interface required");
            Block(); // Replacing an interface can only introduce a denial gap.
            VerifyInstalled();
            IntPtr next = Open(true);
            try
            {
                Check(Native.FwpmTransactionBegin0(next, 0));
                foreach (uint address in addresses)
                {
                    AddFilter(next, address, Native.ConnectV4, true, 0, interfaceLuid);
                    AddFilter(next, address, Native.PacketV4, true, 0, interfaceLuid);
                    AddFilter(next, address, Native.ReceivePacketV4, true, 0, interfaceLuid);
                }
                Check(Native.FwpmTransactionCommit0(next));
                permissionEngine = next;
            }
            catch { Native.FwpmTransactionAbort0(next); Native.FwpmEngineClose0(next); throw; }
        }

        public void Block()
        {
            if (permissionEngine == IntPtr.Zero) return;
            Check(Native.FwpmEngineClose0(permissionEngine));
            permissionEngine = IntPtr.Zero;
        }

        public void VerifyProtection()
        {
            if (!installed) throw new InvalidOperationException("Guard is not installed");
            VerifyInstalled();
        }

        // Called only by explicit uninstall/rollback, never by a crashed or
        // disconnected client. Owner state must be persisted by the service.
        public void Remove()
        {
            Block();
            if (!installed) return;
            Check(Native.FwpmTransactionBegin0(engine, 0));
            try
            {
                foreach (Guid key in filters) { Guid copy = key; Check(Native.FwpmFilterDeleteByKey0(engine, ref copy)); }
                Guid layer = sublayer;
                Check(Native.FwpmSubLayerDeleteByKey0(engine, ref layer));
                Check(Native.FwpmTransactionCommit0(engine));
                installed = false;
            }
            catch { Native.FwpmTransactionAbort0(engine); throw; }
        }

        public static ulong InterfaceLuid(uint index)
        {
            ulong value;
            Check(Native.ConvertInterfaceIndexToLuid(index, out value));
            return value;
        }

        public GuardReceipt Receipt()
        {
            // The caller persists this plan before InstallBlocking touches WFP.
            return new GuardReceipt { Owner = sublayer, Filters = filters.ToArray(),
                Addresses = addresses.ConvertAll(a => String.Format(System.Globalization.CultureInfo.InvariantCulture,
                    "{0}.{1}.{2}.{3}", a >> 24, (a >> 16) & 255, (a >> 8) & 255, a & 255)).ToArray() };
        }

        public static WfpGuard Recover(GuardReceipt receipt)
        {
            var guard = FromReceipt(receipt);
            try
            {
                guard.VerifyInstalled();
                guard.installed = true;
                return guard;
            }
            catch { guard.Dispose(); throw; }
        }

        public static WfpGuard Resume(GuardReceipt receipt)
        {
            var guard = FromReceipt(receipt);
            try { guard.InstallBlocking(); return guard; }
            catch { guard.Dispose(); throw; }
        }

        public static GuardReceipt ExtendPlan(GuardReceipt existing, IEnumerable<IPAddress> additions)
        {
            if (additions == null) throw new ArgumentNullException("additions");
            using (var current = FromReceipt(existing))
            {
                var combined = new List<IPAddress>();
                foreach (string value in existing.Addresses) combined.Add(IPAddress.Parse(value));
                foreach (IPAddress address in additions)
                    if (!combined.Contains(address)) combined.Add(address);
                using (var extended = new WfpGuard(existing.Owner, combined))
                {
                    var result = extended.Receipt();
                    Array.Copy(existing.Filters, result.Filters, existing.Filters.Length);
                    return result;
                }
            }
        }

        private static WfpGuard FromReceipt(GuardReceipt receipt)
        {
            if (receipt == null || receipt.Version != 1 || receipt.Addresses == null || receipt.Filters == null ||
                receipt.Addresses.Length == 0 || receipt.Addresses.Length > 4096 ||
                receipt.Filters.Length != receipt.Addresses.Length * 5)
                throw new ArgumentException("Invalid guard receipt");
            var unique = new HashSet<Guid>();
            foreach (Guid key in receipt.Filters)
                if (key == Guid.Empty || !unique.Add(key)) throw new ArgumentException("Invalid guard filter identity");
            var destinations = new List<IPAddress>();
            foreach (string value in receipt.Addresses)
            {
                IPAddress address;
                if (!IPAddress.TryParse(value, out address) || address.ToString() != value)
                    throw new ArgumentException("Canonical guard address required");
                destinations.Add(address);
            }
            var guard = new WfpGuard(receipt.Owner, destinations);
            guard.filters.Clear();
            guard.filters.AddRange(receipt.Filters);
            return guard;
        }

        private void VerifySublayer()
        {
            IntPtr pointer = IntPtr.Zero;
            try
            {
                Guid key = sublayer;
                Check(Native.FwpmSubLayerGetByKey0(engine, ref key, out pointer));
                var value = (Native.Sublayer)Marshal.PtrToStructure(pointer, typeof(Native.Sublayer));
                if (value.Key != sublayer || value.Flags != 1 || value.Weight != 0x7000 || value.Provider != IntPtr.Zero)
                    throw new InvalidOperationException("Guard sublayer changed");
            }
            finally { if (pointer != IntPtr.Zero) Native.FwpmFreeMemory0(ref pointer); }
        }

        private void VerifyInstalled()
        {
            VerifySublayer();
            if (filters.Count != addresses.Count * 5) throw new InvalidOperationException("Incomplete guard receipt");
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (Guid key in filters)
            {
                IntPtr pointer = IntPtr.Zero;
                try
                {
                    Guid copy = key;
                    Check(Native.FwpmFilterGetByKey0(engine, ref copy, out pointer));
                    var filter = (Native.Filter)Marshal.PtrToStructure(pointer, typeof(Native.Filter));
                    if (filter.Sublayer != sublayer || filter.Action.Type != 0x1001 ||
                        filter.ConditionCount != 1 || filter.Conditions == IntPtr.Zero ||
                        !((filter.Layer == Native.ConnectV4 && filter.Flags == 1) ||
                          ((filter.Layer == Native.PacketV4 || filter.Layer == Native.ReceivePacketV4) &&
                           (filter.Flags == 1 || filter.Flags == 2))))
                        throw new InvalidOperationException("Guard filter changed");
                    var condition = (Native.Condition)Marshal.PtrToStructure(filter.Conditions, typeof(Native.Condition));
                    if (condition.Key != Native.RemoteAddress || condition.Match != 0 || condition.Value.Type != 256 ||
                        condition.Value.Pointer == IntPtr.Zero) throw new InvalidOperationException("Guard condition changed");
                    var mask = (Native.AddressMask)Marshal.PtrToStructure(condition.Value.Pointer, typeof(Native.AddressMask));
                    if (mask.Mask != UInt32.MaxValue || !addresses.Contains(mask.Address) ||
                        !seen.Add(mask.Address + ":" + filter.Layer + ":" + filter.Flags))
                        throw new InvalidOperationException("Guard destination changed");
                }
                finally { if (pointer != IntPtr.Zero) Native.FwpmFreeMemory0(ref pointer); }
            }
        }

        private Guid AddFilter(IntPtr handle, uint address, Guid layer, bool permit, uint flags, ulong luid, Guid? plannedKey = null)
        {
            using (var memory = new NativeMemory())
            {
                var conditions = new List<Native.Condition>();
                conditions.Add(new Native.Condition { Key = Native.RemoteAddress, Value = new Native.Value {
                    Type = 256, Pointer = memory.Struct(new Native.AddressMask { Address = address, Mask = UInt32.MaxValue }) } });
                if (permit) conditions.Add(new Native.Condition { Key = Native.LocalInterface, Value = new Native.Value {
                    Type = 4, Pointer = memory.Struct(luid) } });
                Guid key = plannedKey ?? Guid.NewGuid();
                var filter = new Native.Filter {
                    Key = key, Display = new Native.Display { Name = memory.String(permit ? "IKEv2 Manager verified interface" : "IKEv2 Manager deny bypass") },
                    Flags = flags, Layer = layer, Sublayer = sublayer,
                    Weight = new Native.Value { Type = 1, Number = permit ? 15u : 1u },
                    ConditionCount = (uint)conditions.Count, Conditions = memory.Array(conditions.ToArray()),
                    Action = new Native.Action { Type = permit ? 0x1002u : 0x1001u }
                };
                ulong id;
                uint error = Native.FwpmFilterAdd0(handle, ref filter, IntPtr.Zero, out id);
                if (!plannedKey.HasValue || error != 0x80320009) Check(error);
                return key;
            }
        }

        private static IntPtr Open(bool dynamic)
        {
            var session = new Native.Session { Key = Guid.NewGuid(), Flags = dynamic ? 1u : 0u, Timeout = 5000 };
            IntPtr handle;
            Check(Native.FwpmEngineOpen0(null, 10, IntPtr.Zero, ref session, out handle));
            return handle;
        }

        private static void Check(uint error)
        {
            if (error != 0) throw new Win32Exception(unchecked((int)error), "WFP operation failed: 0x" + error.ToString("X8"));
        }

        public void Dispose()
        {
            Block();
            if (engine != IntPtr.Zero) { Check(Native.FwpmEngineClose0(engine)); engine = IntPtr.Zero; }
        }

        private sealed class NativeMemory : IDisposable
        {
            private readonly List<IntPtr> values = new List<IntPtr>();
            public IntPtr String(string value) { IntPtr p = Marshal.StringToHGlobalUni(value); values.Add(p); return p; }
            public IntPtr Struct<T>(T value) where T : struct { return Array(new[] { value }); }
            public IntPtr Array<T>(T[] items) where T : struct
            {
                int size = Marshal.SizeOf(typeof(T));
                IntPtr p = Marshal.AllocHGlobal(size * items.Length);
                values.Add(p);
                for (int i = 0; i < items.Length; i++) Marshal.StructureToPtr(items[i], IntPtr.Add(p, size * i), false);
                return p;
            }
            public void Dispose() { foreach (IntPtr p in values) Marshal.FreeHGlobal(p); }
        }

        private static class Native
        {
            internal static readonly Guid ConnectV4 = new Guid("c38d57d1-05a7-4c33-904f-7fbceee60e82");
            internal static readonly Guid PacketV4 = new Guid("1e5c9fae-8a84-4135-a331-950b54229ecd");
            internal static readonly Guid ReceivePacketV4 = new Guid("c86fd1bf-21cd-497e-a0bb-17425c885c58");
            internal static readonly Guid RemoteAddress = new Guid("b235ae9a-1d64-49b8-a44c-5ff3d9095045");
            internal static readonly Guid LocalInterface = new Guid("4cd62a49-59c3-4969-b7f3-bda5d32890a4");
            [StructLayout(LayoutKind.Sequential)] internal struct Display { internal IntPtr Name, Description; }
            [StructLayout(LayoutKind.Sequential)] internal struct Blob { internal uint Size; internal IntPtr Data; }
            [StructLayout(LayoutKind.Explicit, Size = 16)] internal struct Value {
                [FieldOffset(0)] internal uint Type;
                [FieldOffset(8)] internal IntPtr Pointer;
                [FieldOffset(8)] internal ulong Number;
            }
            [StructLayout(LayoutKind.Sequential)] internal struct Session {
                internal Guid Key; internal Display Display; internal uint Flags, Timeout, Process;
                internal IntPtr Sid, Username; internal int Kernel;
            }
            [StructLayout(LayoutKind.Sequential)] internal struct Sublayer {
                internal Guid Key; internal Display Display; internal uint Flags; internal IntPtr Provider;
                internal Blob Data; internal ushort Weight;
            }
            [StructLayout(LayoutKind.Sequential)] internal struct AddressMask { internal uint Address, Mask; }
            [StructLayout(LayoutKind.Sequential)] internal struct Condition { internal Guid Key; internal uint Match; internal Value Value; }
            [StructLayout(LayoutKind.Sequential)] internal struct Action { internal uint Type; internal Guid Key; }
            [StructLayout(LayoutKind.Explicit, Size = 16)] internal struct Context { [FieldOffset(0)] internal ulong Raw; }
            [StructLayout(LayoutKind.Sequential)] internal struct Filter {
                internal Guid Key; internal Display Display; internal uint Flags; internal IntPtr Provider;
                internal Blob Data; internal Guid Layer, Sublayer; internal Value Weight;
                internal uint ConditionCount; internal IntPtr Conditions; internal Action Action; internal Context Context;
                internal IntPtr Reserved; internal ulong Id; internal Value EffectiveWeight;
            }
            [DllImport("fwpuclnt.dll", CharSet = CharSet.Unicode)] internal static extern uint FwpmEngineOpen0(string server, uint authentication, IntPtr credentials, ref Session session, out IntPtr handle);
            [DllImport("fwpuclnt.dll")] internal static extern uint FwpmEngineClose0(IntPtr handle);
            [DllImport("fwpuclnt.dll")] internal static extern uint FwpmTransactionBegin0(IntPtr handle, uint flags);
            [DllImport("fwpuclnt.dll")] internal static extern uint FwpmTransactionCommit0(IntPtr handle);
            [DllImport("fwpuclnt.dll")] internal static extern uint FwpmTransactionAbort0(IntPtr handle);
            [DllImport("fwpuclnt.dll")] internal static extern uint FwpmSubLayerAdd0(IntPtr handle, ref Sublayer layer, IntPtr security);
            [DllImport("fwpuclnt.dll")] internal static extern uint FwpmSubLayerDeleteByKey0(IntPtr handle, ref Guid key);
            [DllImport("fwpuclnt.dll")] internal static extern uint FwpmSubLayerGetByKey0(IntPtr handle, ref Guid key, out IntPtr sublayer);
            [DllImport("fwpuclnt.dll")] internal static extern uint FwpmFilterAdd0(IntPtr handle, ref Filter filter, IntPtr security, out ulong id);
            [DllImport("fwpuclnt.dll")] internal static extern uint FwpmFilterDeleteByKey0(IntPtr handle, ref Guid key);
            [DllImport("fwpuclnt.dll")] internal static extern uint FwpmFilterGetByKey0(IntPtr handle, ref Guid key, out IntPtr filter);
            [DllImport("fwpuclnt.dll")] internal static extern void FwpmFreeMemory0(ref IntPtr memory);
            [DllImport("iphlpapi.dll")] internal static extern uint ConvertInterfaceIndexToLuid(uint index, out ulong luid);
        }
    }
}
