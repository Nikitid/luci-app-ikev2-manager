using System;
using System.IO;
using System.Diagnostics;
using System.Text;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using IkeV2Manager.Client;

internal static class ManagedVpnProfileTests
{
    private static string PowerShell(string script)
    {
        using (var process = Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe"), "-NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script))) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }))
        {
            var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(30000)) { process.Kill(); throw new Exception("Profile test timed out"); }
            if (process.ExitCode != 0) throw new Exception("Profile test setup unavailable");
            return output.Result.Trim();
        }
    }
    private static int Main(string[] args)
    {
        var owner = Guid.NewGuid(); string name = "Waypoint " + owner.ToString("N");
        string step = "initial profile";
        string snapshot = "$p=@(Get-VpnConnection -AllUserConnection | Where-Object Name -NE '"+name+"' | Sort-Object Name | Select-Object Name,Guid,ServerAddress,SplitTunneling,Routes);$j=ConvertTo-Json -InputObject $p -Depth 8 -Compress;[Console]::Out.Write($j)";
        string before = PowerShell(snapshot);
        try
        {
            var serializer = new JavaScriptSerializer();
            var fixtures = (object[])serializer.DeserializeObject(File.ReadAllText(args[0]));
            var document = (Dictionary<string,object>)((Dictionary<string,object>)fixtures[0])["policy"];
            var first = ClientPolicy.Parse(serializer.Serialize(document));
            var profile = ManagedVpnProfile.Ensure(first, owner, Guid.Empty);
            step = "repeat identity";
            if (ManagedVpnProfile.Ensure(first, owner, profile.EntryId).EntryId != profile.EntryId) throw new Exception();
            step = "foreign identity refusal";
            bool refused = false;
            try { ManagedVpnProfile.Ensure(first, owner, Guid.NewGuid()); }
            catch (InvalidOperationException) { refused = true; }
            if (!refused) throw new Exception();
            step = "route replacement";
            var resources = (object[])document["resources"];
            var resource = (Dictionary<string,object>)resources[0];
            resource["id"] = "new-domain";
            resource["domain"] = "added.api.example.com";
            resource["address"] = "172.31.254.240";
            document["revision"] = 2;
            document["virtual_subnet"] = "172.31.254.0/24";
            document["resources"] = new object[] {resource};
            var changed = ClientPolicy.Parse(serializer.Serialize(document));
            ManagedVpnProfile.Ensure(changed, owner, profile.EntryId);
            step = "profile looked at";
            if (!ManagedVpnProfile.InPlace(changed, owner, profile.EntryId, false) || ManagedVpnProfile.InPlace(changed, owner, profile.EntryId, true) ||
                ManagedVpnProfile.InPlace(first, owner, profile.EntryId, false)) throw new Exception();
            if (!ManagedVpnProfile.InPlace(changed, owner, profile.EntryId, false)) throw new Exception("looking changed the profile");
            step = "unrelated profiles";
            if (PowerShell(snapshot) != before) throw new Exception();
            Console.WriteLine("Native IKEv2 profile creation, stable identity, strict ownership, /32 route update and unrelated VPN preservation passed");
            // Names: one owned set of rules; names over HTTPS as one recorded
            // entry for the resolver, made, changed and removed with the rules,
            // and never anybody else's.
            step = "name rules";
            string resolver = "172.31.254.127", foreign = "172.31.254.126";
            string can = PowerShell("[Console]::Out.Write([bool](Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue))");
            string rules = "[Console]::Out.Write((@(Get-DnsClientNrptRule | Where-Object Comment -CEQ '" + name + "' | ForEach-Object { $_.Namespace } | Sort-Object -Unique) -join ' ') + '|' + (@(Get-DnsClientNrptRule | Where-Object Comment -CEQ '" + name + "' | ForEach-Object { $_.NameServers } | Sort-Object -Unique) -join ' '))";
            Func<string, string> https = address => PowerShell("$e=Get-DnsClientDohServerAddress -ServerAddress '" + address + "' -ErrorAction SilentlyContinue;[Console]::Out.Write($(if($e){$e.DohTemplate+' '+$e.AutoUpgrade+' '+$e.AllowFallbackToUdp}else{'none'}))");
            if (can == "True") PowerShell("Add-DnsClientDohServerAddress -ServerAddress '" + foreign + "' -DohTemplate 'https://other.example.net/dns-query' -AllowFallbackToUdp $true -AutoUpgrade $false | Out-Null");
            try
            {
                ManagedVpnProfile.ApplyNames(owner, resolver, new[] { "probe.waypoint-test.example" }, "vpn.example.com");
                if (PowerShell(rules) != ".probe.waypoint-test.example probe.waypoint-test.example|" + resolver) throw new Exception("rules");
                if (can == "True" && https(resolver) != "https://vpn.example.com/dns-query True True") throw new Exception("https entry");
                // Looking changes nothing, and tells in place from not in place.
                step = "name rules looked at";
                if (!ManagedVpnProfile.NamesInPlace(owner, resolver, new[] { "probe.waypoint-test.example" }, "vpn.example.com")) throw new Exception("in place not seen");
                if (ManagedVpnProfile.NamesInPlace(owner, resolver, new[] { "probe.waypoint-test.example", "more.waypoint-test.example" }, "vpn.example.com") ||
                    ManagedVpnProfile.NamesAbsent(owner) || (can == "True" && ManagedVpnProfile.NamesInPlace(owner, resolver, new[] { "probe.waypoint-test.example" }, null)))
                    throw new Exception("a difference not seen");
                if (PowerShell(rules) != ".probe.waypoint-test.example probe.waypoint-test.example|" + resolver || (can == "True" && https(resolver) != "https://vpn.example.com/dns-query True True"))
                    throw new Exception("looking changed something");
                step = "name rules repeated";
                ManagedVpnProfile.ApplyNames(owner, resolver, new[] { "probe.waypoint-test.example" }, "vpn.example.com");
                if (can == "True" && https(resolver) != "https://vpn.example.com/dns-query True True") throw new Exception("https entry repeated");
                step = "names over HTTPS withdrawn";
                ManagedVpnProfile.ApplyNames(owner, resolver, new[] { "probe.waypoint-test.example" }, null);
                if (https(resolver) != "none" || PowerShell(rules) != ".probe.waypoint-test.example probe.waypoint-test.example|" + resolver) throw new Exception("withdrawn");
                step = "name rules removed";
                ManagedVpnProfile.ApplyNames(owner, resolver, new[] { "probe.waypoint-test.example" }, "vpn.example.com");
                ManagedVpnProfile.RemoveNames(owner);
                if (PowerShell(rules) != "|" || https(resolver) != "none") throw new Exception("removed");
                if (can == "True" && https(foreign) != "https://other.example.net/dns-query False True") throw new Exception("foreign entry");
                Console.WriteLine("Name rules and names over HTTPS: made, repeated, withdrawn and removed as one owned set" + (can == "True" ? ", another entry left alone" : " (this Windows has no encrypted names; rules only)"));
            }
            finally
            {
                try { ManagedVpnProfile.RemoveNames(owner); } catch { }
                if (can == "True") PowerShell("Remove-DnsClientDohServerAddress -ServerAddress '" + foreign + "','" + resolver + "' -ErrorAction SilentlyContinue; exit 0");
            }
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine("Managed profile test failed at " + step + " (" + error.GetType().Name + ")"); return 1; }
        finally
        {
            PowerShell("$ErrorActionPreference='Stop';$p=Get-VpnConnection -AllUserConnection | Where-Object Name -CEQ '"+name+"';if($p){Remove-VpnConnection -Name '"+name+"' -AllUserConnection -Force};[Console]::Out.Write('removed')");
        }
    }
}
