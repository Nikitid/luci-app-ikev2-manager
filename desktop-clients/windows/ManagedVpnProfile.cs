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
    // The program's own VPN connection is not what the service made: its
    // server, sign-in or ciphers were changed, it was deleted, or another
    // connection took its name. The service makes it again.
    public sealed class ProfileChangedException : InvalidOperationException
    {
        public ProfileChangedException() : base("Managed VPN profile changed") { }
    }

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
            return new ManagedVpnProfile(owner, Invoke(EnsureRequest(policy, owner, pinnedEntry, full, false), pinnedEntry));
        }

        // Made anew under the same owner: whatever carries the owner's name goes
        // first. Used only after Ensure found the connection changed.
        public static ManagedVpnProfile Recreate(ClientPolicy policy, Guid owner, bool full = false)
        {
            return new ManagedVpnProfile(owner, Invoke(EnsureRequest(policy, owner, Guid.Empty, full, false, true), Guid.Empty));
        }

        // Whether the profile already is what Ensure would make it. Changes nothing.
        public static bool InPlace(ClientPolicy policy, Guid owner, Guid pinnedEntry, bool full)
        {
            if (pinnedEntry == Guid.Empty) return false;
            return Run(EnsureRequest(policy, owner, pinnedEntry, full, true), null) == pinnedEntry.ToString("D");
        }

        private static string EnsureRequest(ClientPolicy policy, Guid owner, Guid pinnedEntry, bool full, bool check, bool recreate = false)
        {
            if (policy == null || owner == Guid.Empty || policy.ServerAddress != policy.RemoteId)
                throw new ArgumentException("Windows profile requires an identical server hostname and remote identity");
            // Never interpolate policy metadata into PowerShell source or argv.
            return new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                { "operation", "ensure" }, { "check", check }, { "recreate", recreate },
                { "owner", owner.ToString("N") }, { "entry_id", pinnedEntry == Guid.Empty ? null : pinnedEntry.ToString("D") },
                { "server", policy.ServerAddress }, { "full", full }, { "addresses", policy.Resources.Select(r => r.Address)
                    .Concat(new[] { PolicyHistory.NamesResolver(policy.VirtualSubnet), PolicyHistory.NamesRange(policy.VirtualSubnet) }).ToArray() }
            });
        }

        // Name resolution policy: every name under a selected domain is asked
        // at the router's resolver address, which exists only inside the tunnel.
        // Without the tunnel such a name has no answer rather than a public one.
        // `httpsServer` is the server's name when the router answers names over
        // HTTPS at the resolver address, or null.
        public static void ApplyNames(Guid owner, string resolver, IEnumerable<string> domains, string httpsServer = null)
        {
            Run(NamesRequest(owner, resolver, domains, httpsServer, false), "names-applied");
        }

        // Whether the name rules already are what ApplyNames would make them. Changes nothing.
        public static bool NamesInPlace(Guid owner, string resolver, IEnumerable<string> domains, string httpsServer)
        {
            return Run(NamesRequest(owner, resolver, domains, httpsServer, true), null) == "names-applied";
        }

        // Whether no name rule of this owner is left. Changes nothing.
        public static bool NamesAbsent(Guid owner)
        {
            if (owner == Guid.Empty) throw new ArgumentException("Owned name policy required");
            return Run(new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                { "operation", "names" }, { "check", true }, { "owner", owner.ToString("N") }, { "resolver", null }, { "domains", new string[0] } }), null) == "names-applied";
        }

        private static string NamesRequest(Guid owner, string resolver, IEnumerable<string> domains, string httpsServer, bool check)
        {
            if (owner == Guid.Empty || resolver == null || domains == null) throw new ArgumentException("Owned name policy required");
            return new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                { "operation", "names" }, { "check", check }, { "owner", owner.ToString("N") }, { "resolver", resolver }, { "https", httpsServer },
                { "domains", domains.Distinct().OrderBy(d => d, StringComparer.Ordinal).ToArray() } });
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

        // Every connection and name rule of this program, by name. Returns how
        // many connections and how many name rules went.
        public static int[] Purge()
        {
            string[] counts = Run("{\"operation\":\"purge\"}", null).Split(' ');
            int connections, rules;
            if (counts.Length != 2 || !Int32.TryParse(counts[0], out connections) || !Int32.TryParse(counts[1], out rules))
                throw new InvalidOperationException("Managed VPN profile unavailable");
            return new[] { connections, rules };
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
            // The script is longer than a command line may be (32767
            // characters, encoded): the command line carries a loader that
            // reads the script and then the request from standard input. The
            // script never touches the disk, where somebody else could change it.
            const string loader = "$all = [Console]::In.ReadToEnd(); $cut = $all.IndexOf(\"`n\"); " +
                "$WaypointRequest = $all.Substring($cut + 1); " +
                ". ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($all.Substring(0, $cut)))))";
            var start = new ProcessStartInfo(Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe"),
                "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(loader))) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            using (var process = Process.Start(start))
            {
                var output = process.StandardOutput.ReadToEndAsync();
                var errors = process.StandardError.ReadToEndAsync();
                process.StandardInput.Write(Convert.ToBase64String(new UTF8Encoding(false).GetBytes(script)) + "\n" + request);
                process.StandardInput.Close();
                if (!process.WaitForExit(30000))
                {
                    process.Kill(); process.WaitForExit(5000);
                    throw new InvalidOperationException("Managed profile operation timed out");
                }
                if (process.ExitCode == 3) throw new ProfileChangedException();
                if (!output.Wait(5000) || !errors.Wait(5000) || process.ExitCode != 0)
                    throw new InvalidOperationException("Managed VPN profile unavailable");
                if (expected != null && output.Result != expected) throw new InvalidOperationException("Managed VPN profile unavailable");
                return output.Result;
            }
        }
    }
}
