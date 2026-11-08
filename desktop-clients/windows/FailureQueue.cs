using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace IkeV2Manager.Client
{
    // Failures of the program itself, waiting to be reported (shared rules:
    // desktop-clients/fixtures/status-codes.json, "auto_report"). Kept in the
    // registry rather than in the service's own folder: a reset deletes that
    // folder, and a failure that led to the reset must still be told. Written
    // by the service and by the reset, which runs as an administrator; read by
    // every user, since nothing in an entry names a person, a computer, an
    // address or a service. Nothing here is sent: until the person answers the
    // question about reports, entries only wait.
    internal sealed class FailureQueue
    {
        internal const int Entries = 20;
        internal static readonly TimeSpan Kept = TimeSpan.FromDays(7);
        private const string Product = @"SOFTWARE\Waypoint\Reports";
        internal readonly string Key;

        internal FailureQueue(string installation)
        {
            Key = installation == "IKEv2ManagerClient" || String.IsNullOrEmpty(installation) ? Product : @"SOFTWARE\Waypoint\Test\" + installation;
        }

        // One entry per failure and version; a repeat is counted in it.
        // Never throws: a report must not become a failure of its own.
        internal void Record(string code, string phase, string detail, string[] faults, DateTime? at = null)
        {
            try
            {
                using (Exclusive())
                {
                    DateTime now = at ?? DateTime.UtcNow;
                    var entries = Load(now);
                    string version = Version();
                    var same = entries.FirstOrDefault(e => (string)e["code"] == code && (string)e["phase"] == phase && (string)e["version"] == version);
                    if (same == null)
                    {
                        same = new Dictionary<string, object> { { "code", code }, { "phase", phase }, { "version", version },
                            { "first", Stamp(now) }, { "count", 0 } };
                        entries.Add(same);
                    }
                    same["count"] = Convert.ToInt32(same["count"]) + 1;
                    same["last"] = Stamp(now);
                    same["detail"] = Plain(detail, 400);
                    same["faults"] = (faults ?? new string[0]).Reverse().Take(10).Reverse().Select(f => Plain(f, 160)).ToArray();
                    while (entries.Count > Entries) entries.RemoveAt(0);
                    Save(entries);
                }
            }
            catch (Exception) { }
        }

        internal List<Dictionary<string, object>> Pending(DateTime? now = null)
        {
            using (Exclusive()) return Load(now ?? DateTime.UtcNow);
        }

        internal void Clear()
        {
            using (Exclusive())
            using (var key = Registry.LocalMachine.OpenSubKey(Key, true))
                if (key != null) key.DeleteValue("Queue", false);
        }

        // Taken away once sent, or when the person said not to send.
        internal void Remove(Func<Dictionary<string, object>, bool> which)
        {
            using (Exclusive())
            {
                var entries = Load(DateTime.UtcNow);
                entries.RemoveAll(e => which(e));
                Save(entries);
            }
        }

        // Whether the person answered the question about reports: null while
        // not, true for "send", false for "do not send". One answer per device.
        internal bool? Consent
        {
            get
            {
                using (var key = Registry.LocalMachine.OpenSubKey(Key))
                {
                    object value = key == null ? null : key.GetValue("Consent");
                    return value is int ? (int)value != 0 : (bool?)null;
                }
            }
            set
            {
                using (Exclusive())
                using (var key = Registry.LocalMachine.CreateSubKey(Key))
                {
                    if (value == null) key.DeleteValue("Consent", false);
                    else key.SetValue("Consent", value.Value ? 1 : 0, RegistryValueKind.DWord);
                }
            }
        }

        internal void Forget()
        {
            if (Key == Product) return;
            Registry.LocalMachine.DeleteSubKeyTree(Key, false);
        }

        private List<Dictionary<string, object>> Load(DateTime now)
        {
            var found = new List<Dictionary<string, object>>();
            try
            {
                using (var key = Registry.LocalMachine.OpenSubKey(Key))
                {
                    string text = key == null ? null : key.GetValue("Queue") as string;
                    if (String.IsNullOrEmpty(text) || text.Length > 65536) return found;
                    var items = new JavaScriptSerializer().DeserializeObject(text) as object[];
                    foreach (object item in items ?? new object[0])
                    {
                        var entry = item as Dictionary<string, object>;
                        DateTime last;
                        if (entry == null || !(entry.ContainsKey("code") && entry["code"] is string) || !(entry.ContainsKey("phase") && entry["phase"] is string) ||
                            !(entry.ContainsKey("version") && entry["version"] is string) || !entry.ContainsKey("count") ||
                            !(entry.ContainsKey("last") && entry["last"] is string) ||
                            !DateTime.TryParse((string)entry["last"], System.Globalization.CultureInfo.InvariantCulture,
                                System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out last)) continue;
                        if (now - last > Kept) continue;
                        found.Add(entry);
                    }
                }
            }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            return found;
        }

        private void Save(List<Dictionary<string, object>> entries)
        {
            using (var key = Registry.LocalMachine.CreateSubKey(Key))
            {
                if (entries.Count == 0) key.DeleteValue("Queue", false);
                else key.SetValue("Queue", new JavaScriptSerializer().Serialize(entries), RegistryValueKind.String);
            }
        }

        internal static string Version()
        {
            var version = typeof(FailureQueue).Assembly.GetName().Version;
            return version == null ? "0.0.0" : version.Major + "." + version.Minor + "." + Math.Max(version.Build, 0);
        }

        internal static string Stamp(DateTime at) { return at.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", System.Globalization.CultureInfo.InvariantCulture); }

        // Only what this program writes itself: letters, digits and a few signs.
        internal static string Plain(string text, int limit)
        {
            string kept = System.Text.RegularExpressions.Regex.Replace(text ?? "", @"[^A-Za-z0-9 ._:=,/-]", "");
            return kept.Length > limit ? kept.Substring(0, limit) : kept;
        }

        private static IDisposable Exclusive() { return new Held(); }

        private sealed class Held : IDisposable
        {
            private readonly Mutex mutex;
            private readonly bool owned;
            // A window of a user who may not open the service's lock reads
            // without it: an entry is written whole, by a single value.
            internal Held()
            {
                try { mutex = new Mutex(false, @"Global\Waypoint.FailureQueue"); }
                catch (UnauthorizedAccessException) { return; }
                try { owned = mutex.WaitOne(5000); }
                catch (AbandonedMutexException) { owned = true; }
            }
            public void Dispose() { if (mutex == null) return; if (owned) mutex.ReleaseMutex(); mutex.Dispose(); }
        }
    }
}
