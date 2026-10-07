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
            step = "unrelated profiles";
            if (PowerShell(snapshot) != before) throw new Exception();
            Console.WriteLine("Native IKEv2 profile creation, stable identity, strict ownership, /32 route update and unrelated VPN preservation passed");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine("Managed profile test failed at " + step + " (" + error.GetType().Name + ")"); return 1; }
        finally
        {
            PowerShell("$ErrorActionPreference='Stop';$p=Get-VpnConnection -AllUserConnection | Where-Object Name -CEQ '"+name+"';if($p){Remove-VpnConnection -Name '"+name+"' -AllUserConnection -Force};[Console]::Out.Write('removed')");
        }
    }
}
