using System;
using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;

namespace IkeV2Manager.Client
{
    public sealed class RouteObservation
    {
        public ulong InterfaceLuid { get; private set; }
        public IPAddress Source { get; private set; }
        public IPAddress Prefix { get; private set; }
        public byte PrefixLength { get; private set; }
        public bool IsLoopback { get; private set; }

        public bool Matches(TunnelObservation tunnel, IPAddress destination)
        { return Matches(tunnel, destination, 32); }

        // The route Windows chose is exactly the owned one: same interface,
        // same source, same network. A wider or narrower route is another's.
        public bool Matches(TunnelObservation tunnel, IPAddress network, byte length)
        {
            return tunnel != null && !IsLoopback && InterfaceLuid != 0 && InterfaceLuid == tunnel.InterfaceLuid &&
                Source.Equals(tunnel.LocalAddress) && PrefixLength == length && Prefix.Equals(network);
        }

        public static RouteObservation Read(IPAddress destination)
        {
            if (destination == null || destination.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
                throw new ArgumentException("An IPv4 destination is required");
            var address = Native.Address.From(destination);
            Native.Route route;
            Native.Address source;
            // Deliberately unconstrained: observe what Windows actually chooses,
            // including competition from a personal VPN, rather than asking for
            // the best route within our desired interface.
            uint error = Native.GetBestRoute2(IntPtr.Zero, 0, IntPtr.Zero, ref address, 0, out route, out source);
            if (error != 0) throw new Win32Exception(unchecked((int)error), "Route observation failed: " + error);
            if (source.Family != 2 || route.Destination.Address.Family != 2)
                throw new InvalidOperationException("Unexpected route address family");
            return new RouteObservation { InterfaceLuid = route.Luid, Source = source.ToIP(),
                Prefix = route.Destination.Address.ToIP(), PrefixLength = route.Destination.Length, IsLoopback = route.Loopback != 0 };
        }

        internal static class Native
        {
            [StructLayout(LayoutKind.Explicit, Size = 28)]
            internal struct Address
            {
                [FieldOffset(0)] internal ushort Family;
                [FieldOffset(4)] internal uint IPv4;
                internal static Address From(IPAddress value) { return new Address { Family = 2, IPv4 = BitConverter.ToUInt32(value.GetAddressBytes(), 0) }; }
                internal IPAddress ToIP() { return new IPAddress(BitConverter.GetBytes(IPv4)); }
            }
            [StructLayout(LayoutKind.Sequential)] internal struct Prefix { internal Address Address; internal byte Length; }
            [StructLayout(LayoutKind.Sequential)] internal struct Route
            {
                internal ulong Luid;
                internal uint Index;
                internal Prefix Destination;
                internal Address NextHop;
                internal byte SitePrefixLength;
                internal uint ValidLifetime, PreferredLifetime, Metric, Protocol;
                internal byte Loopback, Autoconfigure, Publish, Immortal;
                internal uint Age, Origin;
            }
            [DllImport("iphlpapi.dll")]
            internal static extern uint GetBestRoute2(IntPtr luid, uint index, IntPtr source, ref Address destination,
                uint options, out Route route, out Address bestSource);
            [DllImport("iphlpapi.dll")] internal static extern void InitializeIpForwardEntry(out Route route);
            [DllImport("iphlpapi.dll")] internal static extern uint CreateIpForwardEntry2(ref Route route);
            [DllImport("iphlpapi.dll")] internal static extern uint GetIpForwardEntry2(ref Route route);
            [DllImport("iphlpapi.dll")] internal static extern uint DeleteIpForwardEntry2(ref Route route);
        }
    }
}
