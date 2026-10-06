using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Net;

namespace IkeV2Manager.Client
{
    public sealed class RouteConfigurationException : InvalidOperationException
    {
        public readonly uint Fields;
        internal RouteConfigurationException(uint fields) : base("Selected route readback changed") { Fields = fields; }
    }
    // Active-store routes belong to one authenticated RAS interface. The caller
    // must retain persistent destination denials throughout installation/removal.
    public sealed class OwnedTunnelRoutes : IDisposable
    {
        private readonly List<RouteObservation.Native.Route> rows = new List<RouteObservation.Native.Route>();
        private readonly string[] destinations;
        private readonly ulong luid;
        private readonly Guid connection;
        private bool disposed;

        public OwnedTunnelRoutes(TunnelObservation tunnel, IEnumerable<IPAddress> addresses)
        {
            if (tunnel == null || tunnel.InterfaceLuid == 0 || tunnel.Connection == Guid.Empty || addresses == null)
                throw new ArgumentException("Verified tunnel and selected destinations required");
            var values = addresses.ToArray();
            if (values.Length == 0 || values.Length > 4096 || values.Distinct().Count() != values.Length)
                throw new ArgumentException("Invalid selected routes");
            foreach (var address in values)
            {
                if (address == null) throw new ArgumentException("Invalid selected route");
                var bytes = address.GetAddressBytes();
                if (bytes.Length != 4 || !(bytes[0] == 10 || bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 || bytes[0] == 192 && bytes[1] == 168))
                    throw new ArgumentException("Selected routes must be private IPv4 destinations");
            }
            luid = tunnel.InterfaceLuid; connection = tunnel.Connection;
            destinations = values.Select(v => v.ToString()).OrderBy(v => v, StringComparer.Ordinal).ToArray();
            try
            {
                foreach (var address in values)
                {
                    RouteObservation.Native.Route row;
                    RouteObservation.Native.InitializeIpForwardEntry(out row);
                    row.Luid = luid;
                    row.Destination = new RouteObservation.Native.Prefix { Address = RouteObservation.Native.Address.From(address), Length = 32 };
                    row.NextHop = RouteObservation.Native.Address.From(IPAddress.Any);
                    row.Metric = 1; row.Protocol = 3; // MIB_IPPROTO_NETMGMT.
                    row.Autoconfigure = 0; row.Immortal = 1; row.Publish = 0; row.Loopback = 0;
                    uint error = RouteObservation.Native.CreateIpForwardEntry2(ref row);
                    // Never adopt an existing row owned by another component.
                    if (error != 0) throw new Win32Exception((int)error, "Selected route creation failed");
                    rows.Add(row);
                    // Windows can normalize lifetime flags on insertion. Pin
                    // the actual installed row after checking its route identity.
                    var installed = row;
                    error = RouteObservation.Native.GetIpForwardEntry2(ref installed);
                    if (error != 0) throw new Win32Exception((int)error, "Selected route readback failed");
                    uint changed = 0;
                    if (installed.Luid != luid) changed |= 1;
                    if (installed.Destination.Length != 32 || installed.Destination.Address.Family != 2 || installed.Destination.Address.IPv4 != row.Destination.Address.IPv4) changed |= 2;
                    if (installed.NextHop.Family != 2 || installed.NextHop.IPv4 != 0) changed |= 4;
                    if (installed.Metric != 1) changed |= 8;
                    if (installed.Protocol != 3) changed |= 16;
                    if (installed.Loopback != 0) changed |= 32;
                    if (installed.Publish != 0) changed |= 64;
                    rows[rows.Count - 1] = installed;
                    if (changed != 0) throw new RouteConfigurationException(changed);
                }
                Verify(tunnel);
            }
            catch { Dispose(); throw; }
        }

        public bool Matches(TunnelObservation tunnel, IEnumerable<IPAddress> addresses)
        {
            return !disposed && tunnel != null && tunnel.InterfaceLuid == luid && tunnel.Connection == connection &&
                destinations.SequenceEqual(addresses.Select(a => a.ToString()).OrderBy(a => a, StringComparer.Ordinal));
        }

        public void Verify(TunnelObservation tunnel)
        {
            if (disposed || tunnel == null || tunnel.InterfaceLuid != luid || tunnel.Connection != connection)
                throw new InvalidOperationException("Owned route connection changed");
            foreach (var expected in rows)
            {
                var actual = expected;
                uint error = RouteObservation.Native.GetIpForwardEntry2(ref actual);
                if (error != 0) throw new Win32Exception((int)error, "Owned route unavailable");
                if (!Same(expected, actual)) throw new InvalidOperationException("Owned route changed");
            }
        }

        private static bool Same(RouteObservation.Native.Route expected, RouteObservation.Native.Route actual)
        {
            return actual.Luid == expected.Luid && actual.Destination.Length == expected.Destination.Length && actual.Destination.Address.Family == expected.Destination.Address.Family &&
                actual.Destination.Address.IPv4 == expected.Destination.Address.IPv4 && actual.NextHop.Family == expected.NextHop.Family && actual.NextHop.IPv4 == expected.NextHop.IPv4 &&
                actual.Metric == expected.Metric && actual.Protocol == expected.Protocol && actual.Loopback == expected.Loopback && actual.Publish == expected.Publish &&
                actual.Immortal == expected.Immortal && actual.Autoconfigure == expected.Autoconfigure;
        }

        public void Dispose()
        {
            disposed = true;
            for (int i = rows.Count - 1; i >= 0; i--)
            {
                var expected = rows[i]; var actual = expected;
                uint error = RouteObservation.Native.GetIpForwardEntry2(ref actual);
                if (error == 1168 || error == 2) { rows.RemoveAt(i); continue; }
                if (error != 0) throw new Win32Exception((int)error, "Owned route cleanup unavailable");
                // An administrator's replacement is no longer our route.
                if (!Same(expected, actual)) throw new InvalidOperationException("Changed route cannot be removed as owned");
                error = RouteObservation.Native.DeleteIpForwardEntry2(ref actual);
                if (error != 0 && error != 1168 && error != 2) throw new Win32Exception((int)error, "Owned route cleanup failed");
                rows.RemoveAt(i);
            }
        }
    }
}
