using System;
using System.IO;

namespace Nikitid.IkeV2ProfileInstaller
{
    internal static class ProfileDocumentTests
    {
        private const string Profile =
            "<VPNProfile><ProfileName>IKEv2 - test</ProfileName>" +
            "<DomainNameInformation><DomainName>.</DomainName>" +
            "<DnsServers>10.20.30.1</DnsServers><AutoTrigger>false</AutoTrigger>" +
            "<Persistent>false</Persistent></DomainNameInformation>" +
            "<NativeProfile><Servers>vpn.example.test</Servers>" +
            "<RoutingPolicyType>ForceTunnel</RoutingPolicyType>" +
            "<NativeProtocolType>IKEv2</NativeProtocolType></NativeProfile>" +
            "</VPNProfile>";

        private static int Main()
        {
            string directory = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(), "nikitid-vpn-test-" + Guid.NewGuid());
            Directory.CreateDirectory(directory);
            string path = System.IO.Path.Combine(directory, "test.vpnv2.xml");
            try
            {
                File.WriteAllText(path, Profile);
                ProfileDocument document = ProfileDocument.Load(path);
                Assert(document.Name == "IKEv2 - test", "profile name");
                Assert(document.Server == "vpn.example.test", "server");
                Assert(document.DnsServers == "10.20.30.1", "DNS");
                Assert(document.ForceTunnel, "routing mode");

				string emptyDirectory = System.IO.Path.Combine(directory, "empty");
				Directory.CreateDirectory(emptyDirectory);
				Assert(ProfileDocument.Find(new string[0], emptyDirectory) == null,
					"installer can start without an adjacent profile");

				Assert(VpnProfileStore.Message("{\"ok\":true,\"message\":\"Профиль \\\"VPN\\\" удалён.\"}") == "Профиль \"VPN\" удалён.",
					"the script's answer is read with its quotes");
				bool refused = false;
				try { VpnProfileStore.Message("{\"message\":\"Windows отказала\",\"ok\":false}"); }
				catch (InvalidOperationException error) { refused = error.Message == "Windows отказала"; }
				Assert(refused, "a refusal of the script is a failure with its words");

                document.SetName("Office VPN");
                Assert(document.Name == "Office VPN", "edited friendly name");
                Assert(document.Xml.Contains(
                    "<ProfileName>Office VPN</ProfileName>"), "edited XML profile name");

                File.WriteAllText(path, Profile.Replace(
                    "<DomainName>.</DomainName>",
                    "<DomainName>example.test</DomainName>"));
                bool rejected = false;
                try { ProfileDocument.Load(path); }
                catch (InvalidDataException) { rejected = true; }
                Assert(rejected, "non-catch-all DNS rule rejection");
                Console.WriteLine("Windows profile document tests OK");
                return 0;
            }
            finally
            {
                if (File.Exists(path))
                    File.Delete(path);
                if (Directory.Exists(directory))
                    Directory.Delete(directory, true);
            }
        }

        private static void Assert(bool value, string label)
        {
            if (!value)
                throw new InvalidOperationException("Assertion failed: " + label);
        }
    }
}
