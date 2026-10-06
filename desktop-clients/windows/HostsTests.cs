using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

internal sealed class HostsFixture
{
    public string name { get; set; }
    public string original { get; set; }
    public List<HostEntry> entries { get; set; }
    public string expected { get; set; }
    public bool fails { get; set; }
}

internal static class HostsTests
{
    private static int Main(string[] args)
    {
        try
        {
            var fixtures = new JavaScriptSerializer().Deserialize<List<HostsFixture>>(File.ReadAllText(args[0]));
            foreach (HostsFixture fixture in fixtures)
            {
                string result;
                try { result = ManagedHosts.Reconcile(fixture.original, fixture.entries); }
                catch (ArgumentException) { if (fixture.fails) continue; throw; }
                if (fixture.fails || result != fixture.expected || ManagedHosts.Reconcile(result, fixture.entries) != result)
                    throw new Exception("Fixture failed: " + fixture.name);
            }
            Console.WriteLine("Hosts behavior tests passed: " + fixtures.Count);
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
    }
}
