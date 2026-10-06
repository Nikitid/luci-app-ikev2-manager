using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace IkeV2Manager.Client
{
    public sealed class TunnelObservation
    {
        public Guid Connection { get; internal set; }
        public ulong InterfaceLuid { get; internal set; }
        public IPAddress LocalAddress { get; internal set; }
        public DateTime ObservedAtUtc { get; internal set; }
    }

    // Read-only RAS observation. This does not authenticate the enrolled server,
    // check routes, or authorize WFP permissions. Those are separate gates.
    public static class RasTunnel
    {
        public static bool Exists(Guid entryId, string phonebook)
        {
            if (entryId == Guid.Empty || String.IsNullOrWhiteSpace(phonebook) || !Path.IsPathRooted(phonebook))
                throw new ArgumentException("Managed entry identity and absolute phonebook path required");
            string expected = Path.GetFullPath(phonebook);
            return Enumerate().Any(c => c.EntryId == entryId && String.Equals(Path.GetFullPath(c.Phonebook), expected, StringComparison.OrdinalIgnoreCase));
        }

        public static TunnelObservation Observe(Guid entryId, string phonebook)
        {
            if (entryId == Guid.Empty || String.IsNullOrWhiteSpace(phonebook) || !Path.IsPathRooted(phonebook))
                throw new ArgumentException("Managed entry identity and absolute phonebook path required");
            string expectedPath = Path.GetFullPath(phonebook);
            Native.Connection[] matches = Enumerate().Where(c => c.EntryId == entryId &&
                String.Equals(Path.GetFullPath(c.Phonebook), expectedPath, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (matches.Length == 0) return null;
            if (matches.Length != 1) throw new InvalidOperationException("Ambiguous RAS connection");
            Native.Connection connection = matches[0];
            if (!Connected(connection.Handle)) return null;
            IPAddress address = Ikev2Address(connection.Handle);
            if (address == null) return null;
            NetworkInterface[] adapters = NetworkInterface.GetAllNetworkInterfaces().Where(n =>
                n.NetworkInterfaceType == NetworkInterfaceType.Ppp && n.OperationalStatus == OperationalStatus.Up &&
                n.GetIPProperties().UnicastAddresses.Any(a => a.Address.Equals(address))).ToArray();
            if (adapters.Length != 1) throw new InvalidOperationException("IKEv2 interface cannot be identified uniquely");
            uint index = checked((uint)adapters[0].GetIPProperties().GetIPv4Properties().Index);
            ulong luid = WfpGuard.InterfaceLuid(index);
            // Do not return a snapshot from an already-ended or reconnecting SA.
            if (!Connected(connection.Handle)) return null;
            return new TunnelObservation { Connection = connection.CorrelationId, InterfaceLuid = luid,
                LocalAddress = address, ObservedAtUtc = DateTime.UtcNow };
        }

        private static Native.Connection[] Enumerate()
        {
            int itemSize = Marshal.SizeOf(typeof(Native.Connection));
            uint bytes = (uint)itemSize;
            for (int attempt = 0; attempt < 3; attempt++)
            {
                if (bytes < itemSize || bytes > itemSize * 256) throw new InvalidOperationException("RAS snapshot exceeds limit");
                uint capacity = bytes;
                IntPtr buffer = Marshal.AllocHGlobal((int)capacity);
                try
                {
                    Marshal.WriteInt32(buffer, itemSize);
                    uint count;
                    uint error = Native.RasEnumConnectionsW(buffer, ref bytes, out count);
                    if (error == 603) continue; // ERROR_BUFFER_TOO_SMALL; retry the complete snapshot.
                    Check(error);
                    if (count > capacity / itemSize) throw new InvalidOperationException("Invalid RAS snapshot size");
                    var result = new Native.Connection[count];
                    for (int i = 0; i < result.Length; i++)
                        result[i] = (Native.Connection)Marshal.PtrToStructure(IntPtr.Add(buffer, i * itemSize), typeof(Native.Connection));
                    return result;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            throw new InvalidOperationException("RAS snapshot changed repeatedly");
        }

        private static bool Connected(IntPtr handle)
        {
            var status = new Native.Status { Size = (uint)Marshal.SizeOf(typeof(Native.Status)) };
            Check(Native.RasGetConnectStatusW(handle, ref status));
            return status.State == 0x2000 && status.Error == 0 && (status.Substate == 0 || status.Substate == 0x2000);
        }

        private static IPAddress Ikev2Address(IntPtr handle)
        {
            // Start with the Win7 SDK structure, including its larger PPP union.
            // The version must be available to the native API on the first call.
            uint bytes = 108;
            for (int attempt = 0; attempt < 2; attempt++)
            {
                if (bytes < 16 || bytes > 65536) throw new InvalidOperationException("Invalid RAS projection size");
                uint capacity = bytes;
                IntPtr buffer = Marshal.AllocHGlobal((int)capacity);
                try
                {
                    Marshal.Copy(new byte[capacity], 0, buffer, (int)capacity);
                    Marshal.WriteInt32(buffer, 4); // RASAPIVERSION_601.
                    uint error = Native.RasGetProjectionInfoEx(handle, buffer, ref bytes);
                    if (error == 603) continue;
                    Check(error);
                    if (bytes < 16 || bytes > capacity) throw new InvalidOperationException("RAS projection size changed");
                    if (Marshal.ReadInt32(buffer, 4) != 2 || Marshal.ReadInt32(buffer, 8) != 0) return null;
                    var address = new byte[4];
                    Marshal.Copy(IntPtr.Add(buffer, 12), address, 0, 4);
                    var result = new IPAddress(address);
                    if (result.Equals(IPAddress.Any) || result.Equals(IPAddress.Broadcast)) return null;
                    return result;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            throw new InvalidOperationException("RAS projection size changed repeatedly");
        }

        private static void Check(uint error)
        {
            if (error != 0) throw new Win32Exception(unchecked((int)error), "RAS observation failed: " + error);
        }

        private static class Native
        {
            [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
            internal struct Connection
            {
                internal uint Size;
                internal IntPtr Handle;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] internal string Name;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] internal string DeviceType;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] internal string DeviceName;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] internal string Phonebook;
                internal uint Subentry;
                internal Guid EntryId;
                internal uint Flags, LogonLow, LogonHigh;
                internal Guid CorrelationId;
            }

            [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
            internal struct Status
            {
                internal uint Size, State, Error;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] internal string DeviceType;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] internal string DeviceName;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] internal string PhoneNumber;
                internal Endpoint Local, Remote;
                internal uint Substate;
            }
            [StructLayout(LayoutKind.Sequential, Pack = 4)]
            internal struct Endpoint { internal uint Type, Address0, Address1, Address2, Address3; }
            [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
            internal static extern uint RasEnumConnectionsW(IntPtr connections, ref uint bytes, out uint count);
            [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
            internal static extern uint RasGetConnectStatusW(IntPtr connection, ref Status status);
            [DllImport("rasapi32.dll")]
            internal static extern uint RasGetProjectionInfoEx(IntPtr connection, IntPtr projection, ref uint bytes);
        }
    }
}
