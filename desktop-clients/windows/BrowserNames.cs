using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;

namespace IkeV2Manager.Client
{
    // What the window says about this computer: the browsers that resolve
    // names around the tunnel, whether this program told them not to, and
    // the system's own name for a report.
    public static class BrowserNames
    {
        // A browser told to resolve names over its own encrypted channel never
        // asks the system, and reaches a service around the tunnel. This looks
        // at the settings of the browsers of the person at this window - their
        // own files, read and never written - and names those set that way.
        // "Automatic" in Chrome and its kin is not such a setting: with name
        // rules in place they ask the system. A browser already told by policy
        // to ask the system is not named.
        public static string[] SelfResolving()
        {
            return SelfResolving(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), true);
        }

        // `policies` off leaves the computer's own settings out, for a test.
        internal static string[] SelfResolving(string local, string roaming, bool policies)
        {
            var found = new List<string>();
            var chromium = new[] {
                new[] { "Chrome", @"Google\Chrome\User Data", @"SOFTWARE\Policies\Google\Chrome" },
                new[] { "Edge", @"Microsoft\Edge\User Data", @"SOFTWARE\Policies\Microsoft\Edge" },
                new[] { "Brave", @"BraveSoftware\Brave-Browser\User Data", @"SOFTWARE\Policies\BraveSoftware\Brave" },
                new[] { "Яндекс Браузер", @"Yandex\YandexBrowser\User Data", @"SOFTWARE\Policies\YandexBrowser" } };
            foreach (var browser in chromium)
            {
                try
                {
                    string state = Path.Combine(local, browser[1], "Local State");
                    if (!File.Exists(state) || new FileInfo(state).Length > 8388608) continue;
                    if (policies) using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(browser[2]))
                        if (key != null && (key.GetValue("DnsOverHttpsMode") as string) == "off") continue;
                    var root = new JavaScriptSerializer { MaxJsonLength = 8388608 }.DeserializeObject(File.ReadAllText(state)) as Dictionary<string, object>;
                    object section;
                    if (root == null || !root.TryGetValue("dns_over_https", out section)) continue;
                    var settings = section as Dictionary<string, object>; object mode;
                    if (settings != null && settings.TryGetValue("mode", out mode) && (mode as string) == "secure") found.Add(browser[0]);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                catch (ArgumentException) { }
                catch (InvalidOperationException) { }
                catch (System.Security.SecurityException) { }
            }
            try
            {
                bool told = false;
                if (policies) using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS"))
                    told = key != null && (key.GetValue("Enabled") as int?) == 0;
                string profiles = Path.Combine(roaming, @"Mozilla\Firefox\Profiles");
                if (!told && Directory.Exists(profiles))
                    foreach (string profile in Directory.GetDirectories(profiles))
                    {
                        string prefs = Path.Combine(profile, "prefs.js");
                        if (!File.Exists(prefs) || new FileInfo(prefs).Length > 8388608) continue;
                        if (System.Text.RegularExpressions.Regex.IsMatch(File.ReadAllText(prefs), @"user_pref\(""network\.trr\.mode"",\s*[23]\)")) { found.Add("Firefox"); break; }
                    }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (System.Security.SecurityException) { }
            return found.ToArray();
        }

        // Whether this program has told the browsers to ask the system - at the user's request, through setup.
        public static bool Told()
        {
            try { using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"Software\IKEv2ManagerClient")) return key != null && key.GetValue("BrowserPolicies") is string[]; }
            catch (System.Security.SecurityException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }

        // The system as a person would name it. Environment.OSVersion answers
        // 6.2 on every Windows since 8 to a program without a compatibility
        // manifest; the registry says what is installed. Windows 11 still calls
        // itself Windows 10 there, and only its build tells them apart.
        public static string WindowsVersion()
        {
            try
            {
                using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    string product = key == null ? null : key.GetValue("ProductName") as string;
                    string release = key == null ? null : key.GetValue("DisplayVersion") as string;
                    string build = key == null ? null : key.GetValue("CurrentBuild") as string;
                    object revision = key == null ? null : key.GetValue("UBR");
                    int number;
                    if (product == null || build == null) return Environment.OSVersion.VersionString;
                    if (Int32.TryParse(build, out number) && number >= 22000) product = product.Replace("Windows 10", "Windows 11");
                    return product + (String.IsNullOrEmpty(release) ? "" : " " + release) + " (build " + build + (revision is int ? "." + revision : "") + ")";
                }
            }
            catch (Exception) { return Environment.OSVersion.VersionString; }
        }
    }
}
