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
            Name = "IKEv2 Manager " + owner.ToString("N");
            Phonebook = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                @"Microsoft\Network\Connections\Pbk\rasphone.pbk");
        }

        public static ManagedVpnProfile Ensure(ClientPolicy policy, Guid owner, Guid pinnedEntry)
        {
            if (policy == null || owner == Guid.Empty || policy.ServerAddress != policy.RemoteId)
                throw new ArgumentException("Windows profile requires an identical server hostname and remote identity");
            // Never interpolate policy metadata into PowerShell source or argv.
            string request = new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                { "operation", "ensure" },
                { "owner", owner.ToString("N") }, { "entry_id", pinnedEntry == Guid.Empty ? null : pinnedEntry.ToString("D") },
                { "server", policy.ServerAddress }, { "addresses", policy.Resources.Select(r => r.Address).ToArray() }
            });
            return new ManagedVpnProfile(owner, Invoke(request, pinnedEntry));
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
                Guid entry;
                if (output.Result.Length != 36 || !Guid.TryParseExact(output.Result, "D", out entry) || entry == Guid.Empty ||
                    (pinnedEntry != Guid.Empty && pinnedEntry != entry)) throw new InvalidOperationException("Managed profile identity changed");
                return entry;
            }
        }
    }
}
