using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using IkeV2Manager.Client;

// Updates against the signed test release in fixtures/update: a list signed
// with a test key, and an installer it names. Downloads are copies of those
// files, changed where a test needs a forged one; nothing is installed.
internal static class UpdaterTests
{
    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception("FAIL " + name);
        Console.WriteLine("PASS " + name);
    }

    private static int Main(string[] args)
    {
        string fixtures = args[0];
        string key = File.ReadAllText(Path.Combine(fixtures, "test-key.pem"));
        string name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
        var queue = new FailureQueue(name);
        string folder = Path.Combine(Path.GetTempPath(), name);
        var own = new Version(2, 3, 0, 0);
        var now = new DateTime(2026, 11, 8, 12, 0, 0, DateTimeKind.Utc);
        try
        {
            var installed = new List<string>();
            var asked = new List<string>();
            Func<Func<string, byte[], byte[]>, Func<Uri, long, string, bool>> from = change => (url, limit, path) => {
                asked.Add(url.AbsoluteUri);
                string file = Path.GetFileName(url.AbsolutePath);
                string source = Path.Combine(fixtures, file.EndsWith(".msi", StringComparison.Ordinal) ? "installer.msi" : file);
                File.WriteAllBytes(path, change(file, File.ReadAllBytes(source)));
                return true;
            };
            Func<string, byte[], byte[]> same = (file, data) => data;

            var updater = new Updater(folder, key, queue, from(same), installed.Add);
            updater.Consider("2.3.0", own, now);
            Require(updater.State == "" && asked.Count == 0, "the release this program is: nothing to fetch");
            updater.Consider("9.9.9", own, now);
            string arch = Updater.Architecture();
            Require(asked.All(url => url.StartsWith(Updater.Releases + "v9.9.9/", StringComparison.Ordinal)) &&
                asked.Any(url => url.EndsWith("/Waypoint-9.9.9-" + arch + ".msi", StringComparison.Ordinal)),
                "only the project's release page, only the installer of this processor");
            Require(updater.State == "ready" && updater.Version == "9.9.9", "an installer that matches the signed list is ready");
            int fetched = asked.Count;
            updater.Consider("9.9.9", own, now.AddHours(1));
            Require(asked.Count == fetched, "the release is looked at again only after six hours");

            DateTime day = new DateTime(2026, 11, 8, 14, 0, 0), night = new DateTime(2026, 11, 9, 3, 0, 0);
            Require(!updater.Due(false, true, true, false, day) && !updater.Due(false, true, true, true, day) && !updater.Due(false, true, true, false, night),
                "never by itself while the tunnel is wanted");
            Require(updater.Due(false, true, false, false, night) && updater.Due(false, true, false, true, day), "by itself at night or as the window exits, with the tunnel not wanted");
            Require(!updater.Due(false, false, false, true, night), "not by itself when the person turned that off");
            Require(updater.Due(true, false, true, false, day), "at once when the person asks");
            updater.InstallNow();
            Require(installed.Count == 1 && Path.GetFileName(installed[0]) == "Waypoint-9.9.9-" + arch + ".msi" && updater.State == "installing", "the checked installer is installed");

            foreach (var forged in new[] {
                new KeyValuePair<string, Func<string, byte[], byte[]>>("a changed installer", (file, data) => file.EndsWith(".msi", StringComparison.Ordinal) ? data.Concat(new byte[] { 1 }).ToArray() : data),
                new KeyValuePair<string, Func<string, byte[], byte[]>>("a changed list", (file, data) => file == ReleaseList.ListName ? data.Concat(System.Text.Encoding.ASCII.GetBytes("0000000000000000000000000000000000000000000000000000000000000000  x.msi\n")).ToArray() : data),
                new KeyValuePair<string, Func<string, byte[], byte[]>>("a changed signature", (file, data) => { if (file != ReleaseList.SignatureName) return data; var copy = (byte[])data.Clone(); copy[copy.Length - 1] ^= 1; return copy; }) })
            {
                installed.Clear(); queue.Clear();
                var refused = new Updater(folder, key, queue, from(forged.Value), installed.Add);
                refused.Consider("9.9.9", own, now);
                refused.InstallNow();
                Require(refused.State == "failed" && installed.Count == 0 && !Directory.GetFiles(folder).Any(f => f.EndsWith(".msi", StringComparison.Ordinal)),
                    forged.Key + ": nothing is installed, nothing is kept");
                Require(queue.Pending().Any(e => (string)e["code"] == "update_signature" && (string)e["phase"] == "update"), forged.Key + ": a failure report waits");
            }

            asked.Clear();
            var unkeyed = new Updater(folder, null, queue, from(same), installed.Add);
            unkeyed.Consider("9.9.9", own, now);
            Require(unkeyed.State == "available" && asked.Count == 0 && !unkeyed.Due(true, true, false, true, night),
                "a build without the key only offers the update");
            Console.WriteLine("Update checks passed");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
        finally
        {
            try { queue.Forget(); } catch (Exception) { }
            if (Directory.Exists(folder)) Directory.Delete(folder, true);
        }
    }
}
