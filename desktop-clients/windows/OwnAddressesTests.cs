using System;
using System.Collections.Generic;
using System.IO;
using IkeV2Manager.Client;

// The shared examples of what a person may add as their own site or network,
// fixtures/own-addresses.json: this client refuses what the router refuses,
// with the same reason, before anything is sent.
internal static class OwnAddressesTests
{
    private static int Main(string[] args)
    {
        var table = (Dictionary<string, object>)new System.Web.Script.Serialization.JavaScriptSerializer().DeserializeObject(File.ReadAllText(args[0]));
        string server = (string)table["server"];
        int checkedCount = 0;
        foreach (string kind in new[] { "domains", "networks" })
            foreach (Dictionary<string, object> example in (object[])table[kind])
            {
                string input = (string)example["input"], reason;
                string got = kind == "domains" ? OwnAddresses.CheckDomain(input, server, out reason) : OwnAddresses.CheckNetwork(input, out reason);
                object ok, why;
                example.TryGetValue("ok", out ok); example.TryGetValue("reason", out why);
                if (got != (string)ok || reason != (string)why)
                {
                    Console.Error.WriteLine("Own address " + kind + " \"" + input + "\": got " + (got ?? "refused " + reason) + ", the table says " + (ok ?? "refused " + why));
                    return 1;
                }
                checkedCount++;
            }
        Console.WriteLine("Own address checks passed: " + checkedCount + " examples refused or taken as the router does");
        return 0;
    }
}
