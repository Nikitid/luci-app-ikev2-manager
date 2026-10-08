using System;
using System.IO;
using System.Linq;
using IkeV2Manager.Client;

// What the window says about browsers, from files laid out the way browsers keep them.
internal static class BrowserNamesTests
{
    private static int Main()
    {
        string root = Path.Combine(Path.GetTempPath(), "waypoint-browsers-" + Guid.NewGuid().ToString("N"));
        string local = Path.Combine(root, "local"), roaming = Path.Combine(root, "roaming");
        try
        {
            Func<string, string, string> state = (folder, text) => { string d = Path.Combine(local, folder); Directory.CreateDirectory(d); File.WriteAllText(Path.Combine(d, "Local State"), text); return d; };
            Action<string, string> prefs = (name, text) => { string d = Path.Combine(roaming, @"Mozilla\Firefox\Profiles", name); Directory.CreateDirectory(d); File.WriteAllText(Path.Combine(d, "prefs.js"), text); };
            Directory.CreateDirectory(local); Directory.CreateDirectory(roaming);
            Expect(new string[0], local, roaming, "no browser at all");
            // Automatic is the browsers' default and asks the system once name rules exist; off asks it always.
            state(@"Google\Chrome\User Data", "{\"dns_over_https\":{\"mode\":\"automatic\"},\"other\":1}");
            state(@"Microsoft\Edge\User Data", "{\"dns_over_https\":{\"mode\":\"off\"}}");
            state(@"BraveSoftware\Brave-Browser\User Data", "{\"browser\":{}}");
            prefs("abc.default", "user_pref(\"network.trr.mode\", 5);\nuser_pref(\"browser.startup.page\", 3);\n");
            Expect(new string[0], local, roaming, "defaults and switched-off settings");
            // A provider chosen by hand, and Firefox's increased or maximum protection, go around the system.
            state(@"Google\Chrome\User Data", "{\"dns_over_https\":{\"mode\":\"secure\",\"templates\":\"https://dns.example/dns-query\"}}");
            Expect(new[] { "Chrome" }, local, roaming, "Chrome with its own provider");
            prefs("xyz.work", "user_pref(\"network.trr.mode\", 3);\n");
            state(@"Yandex\YandexBrowser\User Data", "{\"dns_over_https\":{\"mode\":\"secure\"}}");
            Expect(new[] { "Chrome", "Яндекс Браузер", "Firefox" }, local, roaming, "three browsers");
            prefs("xyz.work", "user_pref(\"network.trr.mode\", 2);\n");
            Expect(new[] { "Chrome", "Яндекс Браузер", "Firefox" }, local, roaming, "Firefox increased protection");
            // A broken or huge file is not a reason to fail or to accuse.
            state(@"Google\Chrome\User Data", "{ not json");
            state(@"Yandex\YandexBrowser\User Data", "[]");
            prefs("xyz.work", "");
            Expect(new string[0], local, roaming, "unreadable settings");
            Console.WriteLine("Browser name settings: defaults pass, own providers are named, broken files accuse nobody");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine("Browser names test failed: " + error.Message); return 1; }
        finally { try { Directory.Delete(root, true); } catch (IOException) { } }
    }

    private static void Expect(string[] wanted, string local, string roaming, string what)
    {
        string[] seen = ClientWindow.SelfResolvingBrowsers(local, roaming, false);
        if (!seen.SequenceEqual(wanted)) throw new Exception(what + ": saw [" + String.Join(", ", seen) + "]");
    }
}
