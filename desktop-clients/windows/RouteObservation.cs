using System;
using System.ComponentModel;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;

namespace IkeV2Manager.Client
{
    // The way to this client's own server while another VPN carries everything
    // else. Windows gives a VPN connection a route to its server through
    // whatever carries the Internet at the moment of dialing; when that is
    // another VPN's adapter, the tunnel would be built inside that VPN, which
    // often does not carry it at all. So for the length of dialing the server
    // gets a route through the physical network - the one route every VPN
    // client keeps for its own server. Windows adds none of its own beside it,
    // so it has to stay for as long as the connection does: its lifetime is
    // short and is renewed while the service lives, and without the service
    // the route goes by itself.
    public sealed class ServerPath : IDisposable
    {
        private readonly System.Collections.Generic.List<RouteObservation.Native.Route> rows = new System.Collections.Generic.List<RouteObservation.Native.Route>();

        // A wired, wireless or mobile adapter that is not another VPN's virtual one.
        public static bool Physical(System.Net.NetworkInformation.NetworkInterface adapter)
        {
            switch (adapter.NetworkInterfaceType)
            {
                case System.Net.NetworkInformation.NetworkInterfaceType.Ethernet:
                case System.Net.NetworkInformation.NetworkInterfaceType.Ethernet3Megabit:
                case System.Net.NetworkInformation.NetworkInterfaceType.FastEthernetT:
                case System.Net.NetworkInformation.NetworkInterfaceType.FastEthernetFx:
                case System.Net.NetworkInformation.NetworkInterfaceType.GigabitEthernet:
                case System.Net.NetworkInformation.NetworkInterfaceType.Wireless80211:
                case System.Net.NetworkInformation.NetworkInterfaceType.Wwanpp:
                case System.Net.NetworkInformation.NetworkInterfaceType.Wwanpp2:
                    return !System.Text.RegularExpressions.Regex.IsMatch(adapter.Description ?? "",
                        @"Wintun|WireGuard|TAP-Windows|TAP Adapter|TUN|OpenVPN|sing-|AdGuard|VPN|Tailscale|ZeroTier", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                default: return false;
            }
        }

        public static bool Public(IPAddress address)
        {
            byte[] b = address.GetAddressBytes();
            // Not private, shared, loopback, link-local, the ranges some VPN
            // clients answer names from, multicast or reserved.
            return b.Length == 4 && !(b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 || (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
                (b[0] == 169 && b[1] == 254) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 198 && (b[1] == 18 || b[1] == 19)));
        }

        // Null when nothing stands between this computer and the server, or
        // when there is no physical network to go through: dialing then goes
        // the way it always did.
        public static ServerPath Pin(string server, uint seconds = 120)
        {
            var made = new ServerPath();
            try
            {
                var addresses = Dns.GetHostAddresses(server).Where(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && Public(a)).Take(4).ToArray();
                if (addresses.Length == 0) return null;
                var adapters = System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                    .Where(a => a.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up).ToArray();
                var chosen = RouteObservation.Read(addresses[0]);
                var carrier = adapters.FirstOrDefault(a => a.GetIPProperties().UnicastAddresses.Any(u => u.Address.Equals(chosen.Source)));
                if (chosen.IsLoopback || carrier == null || Physical(carrier)) return null;
                // The physical adapter with a gateway whose route to the server costs least.
                bool found = false; var best = new RouteObservation.Native.Route();
                foreach (var adapter in adapters.Where(Physical))
                {
                    var properties = adapter.GetIPProperties();
                    if (!properties.GatewayAddresses.Any(g => g.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any))) continue;
                    var destination = RouteObservation.Native.Address.From(addresses[0]);
                    RouteObservation.Native.Route route; RouteObservation.Native.Address source;
                    if (RouteObservation.Native.GetBestRoute2(IntPtr.Zero, (uint)properties.GetIPv4Properties().Index, IntPtr.Zero, ref destination, 0, out route, out source) != 0) continue;
                    if (route.NextHop.Family != 2 || route.NextHop.IPv4 == 0 || route.Loopback != 0) continue;
                    if (!found || route.Metric < best.Metric) { best = route; found = true; }
                }
                if (!found) return null;
                foreach (var address in addresses)
                {
                    RouteObservation.Native.Route row;
                    RouteObservation.Native.InitializeIpForwardEntry(out row);
                    row.Luid = best.Luid; row.Index = best.Index;
                    row.Destination = new RouteObservation.Native.Prefix { Address = RouteObservation.Native.Address.From(address), Length = 32 };
                    row.NextHop = best.NextHop;
                    row.Metric = 0; row.Protocol = 3; // MIB_IPPROTO_NETMGMT.
                    row.ValidLifetime = row.PreferredLifetime = seconds;
                    row.Autoconfigure = 0; row.Immortal = 0; row.Publish = 0; row.Loopback = 0;
                    // A route somebody already keeps for this address stays theirs.
                    if (RouteObservation.Native.CreateIpForwardEntry2(ref row) == 0) made.rows.Add(row);
                }
                if (made.rows.Count == 0) return null;
                var result = made; made = null; return result;
            }
            catch (System.Net.Sockets.SocketException) { return null; }
            catch (Win32Exception) { return null; }
            catch (InvalidOperationException) { return null; }
            catch (ArgumentException) { return null; }
            finally { if (made != null) made.Dispose(); }
        }

        // Gives the routes their full lifetime again. False when one is gone
        // or can no longer be kept: the connection that relies on it is then
        // on its own, and its loss is handled like any other.
        public bool Renew(uint seconds = 120)
        {
            bool kept = rows.Count != 0;
            for (int item = 0; item < rows.Count; item++)
            {
                var row = rows[item];
                row.ValidLifetime = row.PreferredLifetime = seconds;
                if (RouteObservation.Native.SetIpForwardEntry2(ref row) != 0) kept = false;
            }
            return kept;
        }

        public void Dispose()
        {
            foreach (var row in rows) { var copy = row; RouteObservation.Native.DeleteIpForwardEntry2(ref copy); }
            rows.Clear();
        }
    }

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
            [DllImport("iphlpapi.dll")] internal static extern uint SetIpForwardEntry2(ref Route route);
        }
    }
}
