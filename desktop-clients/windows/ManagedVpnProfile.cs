using System;
using System.IO;
using System.Linq;
using System.Diagnostics;
using System.Text;
using System.Reflection;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace IkeV2Manager.Client
{
    public sealed class ManagedVpnProfile
    {
        public readonly Guid Owner, EntryId;
        public readonly string Name, Phonebook;
        private ManagedVpnProfile(Guid owner, Guid entry)
        {
            Owner = owner; EntryId = entry;
            Name = "Waypoint " + owner.ToString("N");
            Phonebook = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                @"Microsoft\Network\Connections\Pbk\rasphone.pbk");
        }

        // `full`: the system sends everything into the tunnel; otherwise only
        // the routes of the selected services.
        public static ManagedVpnProfile Ensure(ClientPolicy policy, Guid owner, Guid pinnedEntry, bool full = false)
        {
            if (policy == null || owner == Guid.Empty || policy.ServerAddress != policy.RemoteId)
                throw new ArgumentException("Windows profile requires an identical server hostname and remote identity");
            // Never interpolate policy metadata into PowerShell source or argv.
            string request = new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                { "operation", "ensure" },
                { "owner", owner.ToString("N") }, { "entry_id", pinnedEntry == Guid.Empty ? null : pinnedEntry.ToString("D") },
                { "server", policy.ServerAddress }, { "full", full }, { "addresses", policy.Resources.Select(r => r.Address)
                    .Concat(new[] { PolicyHistory.NamesResolver(policy.VirtualSubnet), PolicyHistory.NamesRange(policy.VirtualSubnet) }).ToArray() }
            });
            return new ManagedVpnProfile(owner, Invoke(request, pinnedEntry));
        }

        // Name resolution policy: every name under a selected domain is asked
        // at the router's resolver address, which exists only inside the tunnel.
        // Without the tunnel such a name has no answer rather than a public one.
        public static void ApplyNames(Guid owner, string resolver, IEnumerable<string> domains)
        {
            if (owner == Guid.Empty || resolver == null || domains == null) throw new ArgumentException("Owned name policy required");
            Run(new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                { "operation", "names" }, { "owner", owner.ToString("N") }, { "resolver", resolver },
                { "domains", domains.Distinct().OrderBy(d => d, StringComparer.Ordinal).ToArray() } }), "names-applied");
        }

        public static void RemoveNames(Guid owner)
        {
            if (owner == Guid.Empty) throw new ArgumentException("Owned name policy required");
            Run(new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                { "operation", "names" }, { "owner", owner.ToString("N") }, { "resolver", null }, { "domains", new string[0] } }), "names-applied");
        }

        public static void Remove(Guid owner, Guid entry)
        {
            if (owner == Guid.Empty || entry == Guid.Empty) throw new ArgumentException("Owned profile identity required");
            Invoke(new JavaScriptSerializer().Serialize(new Dictionary<string,object> {
                {"operation", "remove"}, {"owner", owner.ToString("N")}, {"entry_id", entry.ToString("D")}
            }), entry);
        }

        public static ManagedVpnProfile FromJournal(Guid owner, Guid entry)
        {
            if (owner == Guid.Empty || entry == Guid.Empty) throw new ArgumentException("Owned profile identity required");
            return new ManagedVpnProfile(owner, entry);
        }

        private static Guid Invoke(string request, Guid pinnedEntry)
        {
            string text = Run(request, null);
            Guid entry;
            if (text.Length != 36 || !Guid.TryParseExact(text, "D", out entry) || entry == Guid.Empty ||
                (pinnedEntry != Guid.Empty && pinnedEntry != entry)) throw new InvalidOperationException("Managed profile identity changed");
            return entry;
        }

        private static string Run(string request, string expected)
        {
            string script;
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("ManagedVpnProfile.ps1"))
            {
                if (stream == null) throw new InvalidOperationException("Managed profile resource missing");
                using (var reader = new StreamReader(stream, new UTF8Encoding(false, true))) script = reader.ReadToEnd();
            }
            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            var start = new ProcessStartInfo(Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe"),
                "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script))) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            using (var process = Process.Start(start))
            {
                var output = process.StandardOutput.ReadToEndAsync();
                var errors = process.StandardError.ReadToEndAsync();
                process.StandardInput.Write(request); process.StandardInput.Close();
                if (!process.WaitForExit(30000))
                {
                    process.Kill(); process.WaitForExit(5000);
                    throw new InvalidOperationException("Managed profile operation timed out");
                }
                if (!output.Wait(5000) || !errors.Wait(5000) || process.ExitCode != 0)
                    throw new InvalidOperationException("Managed VPN profile unavailable");
                if (expected != null && output.Result != expected) throw new InvalidOperationException("Managed VPN profile unavailable");
                return output.Result;
            }
        }
    }
}
