using System;
using System.IO;
using System.Linq;
using IkeV2Manager.Client;

// The networks a device's services carry are blocked without the tunnel by a
// guard of their own, which follows the offer: those of blocked services
// only, replaced whole when that changes, and gone when nothing is blocked.
internal static class NetworkGuardTests
{
    private const string Policy = "{\"version\":2,\"id\":\"office-pc\",\"revision\":1,\"server\":{\"address\":\"vpn.example.com\",\"remote_id\":\"vpn.example.com\"}," +
        "\"virtual_subnet\":\"172.31.254.0/24\",\"exit\":\"1\",\"resources\":[]," +
        "\"networks\":[{\"network\":\"198.51.100.0/24\",\"transports\":[{\"protocol\":\"tcp\",\"ports\":[443]}]}," +
        "{\"network\":\"203.0.113.0/24\",\"transports\":[{\"protocol\":\"tcp\",\"ports\":[443]}]}]}";

    private static DeviceServices Offer(bool chatClosed, bool apiClosed)
    {
        Func<string, string, bool, string> entry = (id, cidr, closed) => "{\"id\":\"" + id + "\",\"required\":true,\"on\":true,\"closed\":" + (closed ? "true" : "false") +
            ",\"choose_closed\":false,\"domains\":0,\"networks\":1,\"resources\":[],\"cidrs\":[\"" + cidr + "\"]}";
        return DeviceServices.Parse("{\"version\":1,\"id\":\"office-pc\",\"revision\":1,\"selected\":[],\"available\":[],\"entries\":[" +
            entry("chat", "198.51.100.0/24", chatClosed) + "," + entry("api", "203.0.113.0/24", apiClosed) + "]}", "office-pc");
    }

    // The chat service is required and blocked; the api service is the
    // person's to turn on and to block, here both or neither.
    private static DeviceServices Choosable(bool apiChosen)
    {
        string chosen = apiChosen ? "true" : "false";
        return DeviceServices.Parse("{\"version\":1,\"id\":\"office-pc\",\"revision\":1,\"selected\":[],\"available\":[],\"entries\":[" +
            "{\"id\":\"chat\",\"required\":true,\"on\":true,\"closed\":true,\"choose_closed\":false,\"domains\":0,\"networks\":1,\"resources\":[],\"cidrs\":[\"198.51.100.0/24\"]}," +
            "{\"id\":\"api\",\"required\":false,\"on\":" + chosen + ",\"closed\":" + chosen + ",\"choose_closed\":true,\"domains\":0,\"networks\":1,\"resources\":[],\"cidrs\":[\"203.0.113.0/24\"]}]}", "office-pc");
    }

    private static bool Installed(GuardReceipt plan)
    {
        try { using (var guard = WfpGuard.Recover(plan)) guard.VerifyProtection(); return true; }
        catch (Exception) { return false; }
    }

    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception("FAIL " + name);
        Console.WriteLine("PASS " + name);
    }

    public static void Run()
    {
        string name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name);
        GuardReceipt main = null, held = null;
        try
        {
            using (var runtime = new GuardRuntime(name))
            {
                runtime.StagePolicy(ClientPolicy.Parse(Policy));
                main = runtime.MainPlan();
                runtime.HoldNetworks(Offer(false, true));
                GuardReceipt first;
                first = runtime.NetworksPlan();
                Require(first != null && first.Addresses.SequenceEqual(new[] { "203.0.113.0/24" }) && Installed(first),
                    "only the network of a blocked service is blocked");
                held = first;
                runtime.HoldNetworks(Offer(true, true));
                GuardReceipt both;
                both = runtime.NetworksPlan();
                Require(both != null && both.Addresses.OrderBy(a => a).SequenceEqual(new[] { "198.51.100.0/24", "203.0.113.0/24" }) && Installed(both),
                    "a changed offer is held by a new guard");
                Require(!Installed(first), "the guard it replaced is gone");
                held = both;
                runtime.HoldNetworks(Choosable(false));
                held = runtime.NetworksPlan();
                Require(!runtime.ChoicePending() && runtime.Choose(new[] { "api" }, new[] { "api" }) && runtime.ChoicePending(),
                    "a choice the offer leaves to the person is taken");
                Require(!runtime.Choose(new[] { "chat" }, new string[0]) && !runtime.Choose(new string[0], new[] { "chat" }) &&
                    !runtime.Choose(new[] { "mail" }, new string[0]), "a choice the offer does not leave to the person is refused");
                Require(GuardRuntime.Reflects(Choosable(true), new[] { "api" }, new[] { "api" }) &&
                    !GuardRuntime.Reflects(Choosable(false), new[] { "api" }, new[] { "api" }) &&
                    GuardRuntime.Reflects(Choosable(false), new string[0], new string[0]), "a choice counts as done only once the offer shows it");
                runtime.HoldNetworks(Offer(false, false));
                GuardReceipt none;
                none = runtime.NetworksPlan();
                Require(none == null && !Installed(both), "nothing blocked leaves no guard behind");
                held = null;
            }
        }
        finally
        {
            if (held != null) try { WfpGuard.RemoveRecorded(held); } catch { }
            if (main != null) try { WfpGuard.RemoveRecorded(main); } catch { }
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }
}
