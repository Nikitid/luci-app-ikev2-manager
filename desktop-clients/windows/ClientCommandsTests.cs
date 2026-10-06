using System;
using System.Collections.Generic;
using IkeV2Manager.Client;

internal static class ClientCommandsTests
{
    private static int Main()
    {
        try
        {
            string token = new string('a', 64), endpoint, parsed;
            ClientCommands.ParseInvitation(" https://vpn.example.com:8443/client/v1/enroll#" + token + " ", out endpoint, out parsed);
            if (endpoint != "https://vpn.example.com:8443/client/v1/enroll" || parsed != token || endpoint.Contains(token))
                throw new Exception("Invitation key was not separated from HTTPS endpoint");
            foreach (string link in new[] { "http://vpn.example.com/client/v1/enroll#" + token,
                "https://vpn.example.com/client/v1/enroll?secret=value#" + token,
                "https://user@vpn.example.com/client/v1/enroll#" + token,
                "https://vpn.example.com/ubus#" + token, "https://vpn.example.com/client/v1/enroll",
                "https://vpn.example.com/client/v1/enroll#short", "not a URI" })
                Reject(() => { string a, b; ClientCommands.ParseInvitation(link, out a, out b); });
            ClientCommands.Validate(ClientCommands.Parse("{\"version\":1,\"operation\":\"continue\"}"));
            foreach (string json in new[] { "{\"version\":2,\"operation\":\"continue\"}",
                "{\"version\":1,\"operation\":\"delete\"}", "{\"version\":1,\"operation\":\"continue\",\"path\":\"file\"}",
                "{\"version\":1,\"operation\":\"begin\"}", "[]", "{}" })
                Reject(() => ClientCommands.Validate(ClientCommands.Parse(json)));
            Reject(() => ClientCommands.PipeName("other-service"));
            Console.WriteLine("Control protocol checks passed: invitation separation, endpoint restrictions, operations and fields");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
    }

    private static void Reject(Action action)
    {
        try { action(); }
        catch (ArgumentException) { return; }
        catch (FormatException) { return; }
        throw new Exception("Unsafe client control input accepted");
    }
}
