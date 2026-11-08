using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace IkeV2Manager.Client
{
    // The signed list of a release of the clients (docs/DEVELOPMENT.md):
    // `Waypoint-SHA256SUMS`, one "<sha256>  <file>" per installer, and
    // `Waypoint-SHA256SUMS.sig`, an ECDSA P-256 signature over its exact
    // bytes in DER, checked with the project's key for the clients.
    internal static class ReleaseList
    {
        internal const string ListName = "Waypoint-SHA256SUMS", SignatureName = "Waypoint-SHA256SUMS.sig";

        internal static bool Verify(byte[] list, byte[] signature, string publicKeyPem)
        {
            if (list == null || signature == null || String.IsNullOrEmpty(publicKeyPem) || signature.Length > 128) return false;
#if NET
            try
            {
                using (var key = ECDsa.Create())
                {
                    key.ImportFromPem(publicKeyPem);
                    if (key.KeySize != 256) return false;
                    return key.VerifyData(list, signature, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
                }
            }
            catch (CryptographicException) { return false; }
            catch (ArgumentException) { return false; }
#else
            return false;
#endif
        }

        // File name to its SHA-256, lower-case hex; null for a list not in the format.
        internal static Dictionary<string, string> Parse(byte[] list)
        {
            var sums = new Dictionary<string, string>(StringComparer.Ordinal);
            string text;
            try { text = new UTF8Encoding(false, true).GetString(list); }
            catch (ArgumentException) { return null; }
            foreach (string line in text.Split('\n'))
            {
                if (line.Length == 0) continue;
                var match = Regex.Match(line, @"\A([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]{0,127})\z");
                if (!match.Success || sums.ContainsKey(match.Groups[2].Value)) return null;
                sums[match.Groups[2].Value] = match.Groups[1].Value;
            }
            return sums.Count == 0 ? null : sums;
        }

        internal static string Sha256(string path)
        {
            using (var stream = File.OpenRead(path))
            using (var sha = SHA256.Create())
                return String.Concat(sha.ComputeHash(stream).Select(b => b.ToString("x2")));
        }
    }

    // Updates as decided for both systems: the service looks for a newer
    // release every six hours, fetches the installer of its own processor and
    // the signed list from the project's release page only, and installs it
    // only when the installer matches the list and the list its signature -
    // otherwise nothing is installed and a failure report waits. It installs by
    // itself, when the person lets it, only while the tunnel is not wanted: at
    // night or as the window exits; or at once, when the person asks.
    internal sealed class Updater
    {
        internal static readonly TimeSpan Every = TimeSpan.FromHours(6);
        internal const string Releases = "https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/";
        private const long InstallerLimit = 256L * 1024 * 1024;
        private readonly string folder;
        private readonly string publicKey;
        private readonly FailureQueue failures;
        private readonly Func<Uri, long, string, bool> download;
        private readonly Action<string> install;
        private DateTime lookedAt = DateTime.MinValue;

        // What the window shows: the newer version, or "" none; and its state:
        // "available" (seen; installed by hand only, without a key to check
        // it), "ready" (fetched and checked), "installing", "failed" (did not
        // pass the check: not installed).
        internal string Version { get; private set; }
        internal string State { get; private set; }
        internal string Installer { get; private set; }

        internal Updater(string folder, string publicKey, FailureQueue failures,
            Func<Uri, long, string, bool> download = null, Action<string> install = null)
        {
            this.folder = folder; this.publicKey = publicKey; this.failures = failures;
            this.download = download ?? Download;
            this.install = install ?? Install;
            Version = ""; State = "";
        }

        internal static string Architecture()
        {
            return System.Runtime.InteropServices.RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";
        }

        // The project's key for the clients, built into the service; null in
        // a build made without it, which then only offers updates.
        internal static string EmbeddedKey()
        {
            using (var stream = typeof(Updater).Assembly.GetManifestResourceStream("waypoint-client-release.pem"))
            {
                if (stream == null) return null;
                using (var reader = new StreamReader(stream)) return reader.ReadToEnd();
            }
        }

        // Called with every answer of the router; looks at most every six
        // hours, or at once when the router names a newer release than seen.
        internal void Consider(string release, System.Version own, DateTime now, bool force = false)
        {
            System.Version offered;
            if (String.IsNullOrEmpty(release) || !System.Version.TryParse(release, out offered) || !ClientView.Newer(release, own))
            {
                if (State != "installing") { Version = ""; State = ""; Installer = null; }
                return;
            }
            if (!force && release == Version && now - lookedAt < Every) return;
            if (release != Version) { Version = release; State = "available"; Installer = null; }
            lookedAt = now;
            if (publicKey == null || State == "ready" || State == "installing") return;
            string name = "Waypoint-" + release + "-" + Architecture() + ".msi";
            Directory.CreateDirectory(folder);
            foreach (string old in Directory.GetFiles(folder)) try { File.Delete(old); } catch (IOException) { }
            string list = Path.Combine(folder, ReleaseList.ListName), signature = Path.Combine(folder, ReleaseList.SignatureName), installer = Path.Combine(folder, name);
            var tag = new Uri(Releases + "v" + release + "/");
            if (!download(new Uri(tag, ReleaseList.ListName), 65536, list) || !download(new Uri(tag, ReleaseList.SignatureName), 128, signature) ||
                !download(new Uri(tag, name), InstallerLimit, installer)) return;   // not reachable now: next time
            var sums = ReleaseList.Verify(File.ReadAllBytes(list), File.ReadAllBytes(signature), publicKey) ? ReleaseList.Parse(File.ReadAllBytes(list)) : null;
            string expected;
            if (sums == null || !sums.TryGetValue(name, out expected) || ReleaseList.Sha256(installer) != expected)
            {
                foreach (string file in new[] { list, signature, installer }) try { File.Delete(file); } catch (IOException) { }
                State = "failed";
                failures.Record("update_signature", "update", sums == null ? "the release list did not pass its signature" : "the installer does not match the signed list", null);
                return;
            }
            Installer = installer;
            State = "ready";
        }

        // Whether it goes now: asked for by the person, or by itself when
        // the person lets it and the tunnel is not wanted - at night, or as
        // the window exits.
        internal bool Due(bool asked, bool automatic, bool tunnelWanted, bool windowExited, DateTime localNow)
        {
            if (State != "ready" || Installer == null) return false;
            if (asked) return true;
            bool night = localNow.Hour >= 2 && localNow.Hour < 5;
            return automatic && !tunnelWanted && (night || windowExited);
        }

        internal void InstallNow()
        {
            if (State != "ready" || Installer == null || !File.Exists(Installer)) return;
            // Checked again just before: nothing changed it since.
            var sums = ReleaseList.Verify(File.ReadAllBytes(Path.Combine(folder, ReleaseList.ListName)), File.ReadAllBytes(Path.Combine(folder, ReleaseList.SignatureName)), publicKey)
                ? ReleaseList.Parse(File.ReadAllBytes(Path.Combine(folder, ReleaseList.ListName))) : null;
            string expected;
            if (sums == null || !sums.TryGetValue(Path.GetFileName(Installer), out expected) || ReleaseList.Sha256(Installer) != expected)
            {
                State = "failed";
                failures.Record("update_signature", "update", "the installer changed after it was checked", null);
                return;
            }
            State = "installing";
            install(Installer);
        }

        // Only from the release page, over HTTPS, redirects to HTTPS only,
        // never larger than `limit`.
        private static bool Download(Uri url, long limit, string path)
        {
            try
            {
                Uri current = url;
                for (int hop = 0; hop < 5; hop++)
                {
                    if (current.Scheme != Uri.UriSchemeHttps) return false;
                    ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                    var request = (HttpWebRequest)WebRequest.Create(current);
                    request.AllowAutoRedirect = false;
                    request.Timeout = request.ReadWriteTimeout = 60000;
                    request.UserAgent = "Waypoint";
                    HttpWebResponse response;
                    try { response = (HttpWebResponse)request.GetResponse(); }
                    catch (WebException failure) { response = failure.Response as HttpWebResponse; if (response == null) return false; }
                    using (response)
                    {
                        int status = (int)response.StatusCode;
                        if (status >= 300 && status < 400 && response.Headers["Location"] != null) { current = new Uri(current, response.Headers["Location"]); continue; }
                        if (status != 200 || response.ContentLength > limit) return false;
                        using (var input = response.GetResponseStream())
                        using (var output = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
                        {
                            var buffer = new byte[81920]; long total = 0; int read;
                            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                            {
                                total += read;
                                if (total > limit) return false;
                                output.Write(buffer, 0, read);
                            }
                        }
                        return true;
                    }
                }
                return false;
            }
            catch (WebException) { return false; }
            catch (IOException) { return false; }
        }

        // The installer stops this service, updates it and starts it again:
        // it runs apart from this process. Services stay closed meanwhile -
        // the denials are persistent.
        private static void Install(string installer)
        {
            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            Process.Start(new ProcessStartInfo(Path.Combine(system, "msiexec.exe"),
                "/i \"" + installer + "\" /qn /norestart") { UseShellExecute = false, CreateNoWindow = true });
        }
    }
}
