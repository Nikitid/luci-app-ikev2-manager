using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;

// The installed product, driven only the way its window drives it: commands to
// the service and its published status. The fixture owns the router, the
// invitation and the trust anchor, and installs and removes the product.
internal static class ProductIntegrationTests
{
    private static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private static string Shown() { var view = ClientStatusReader.Read(); return view.State + "/" + view.ConnectionError; }
    private static bool Await(Func<ClientView, bool> reached, int milliseconds)
    {
        var elapsed = Stopwatch.StartNew();
        while (!reached(ClientStatusReader.Read()) && elapsed.ElapsedMilliseconds < milliseconds) Thread.Sleep(250);
        return reached(ClientStatusReader.Read());
    }
    private static bool Echo(string host, int port)
    {
        try
        {
            using (var client = new System.Net.Sockets.TcpClient())
            {
                var pending = client.BeginConnect(host, port, null, null);
                if (!pending.AsyncWaitHandle.WaitOne(4000)) return false;
                client.EndConnect(pending);
                client.ReceiveTimeout = client.SendTimeout = 4000;
                byte[] line = System.Text.Encoding.ASCII.GetBytes("installed-path\n"), answer = new byte[line.Length];
                var stream = client.GetStream();
                stream.Write(line, 0, line.Length);
                int total = 0, read;
                while (total < answer.Length && (read = stream.Read(answer, total, answer.Length - total)) > 0) total += read;
                return total == line.Length && System.Linq.Enumerable.SequenceEqual(line, answer);
            }
        }
        catch (System.Net.Sockets.SocketException) { return false; }
        catch (IOException) { return false; }
    }

    // What a real service says about where the request came from, as a digest:
    // the fixture compares it with the exit's and the direct address, and the
    // addresses themselves never reach a log.
    private static string Origin(string url)
    {
        try
        {
            System.Net.ServicePointManager.SecurityProtocol = (System.Net.SecurityProtocolType)3072;
            var request = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
            request.Proxy = null; request.UserAgent = "curl/8"; request.Timeout = request.ReadWriteTimeout = 8000;
            request.KeepAlive = false; request.AllowAutoRedirect = false;
            using (var response = (System.Net.HttpWebResponse)request.GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream()))
            {
                string body = reader.ReadToEnd().Trim();
                if (!System.Text.RegularExpressions.Regex.IsMatch(body, @"\A[0-9]{1,3}(\.[0-9]{1,3}){3}\z")) return null;
                using (var digest = System.Security.Cryptography.SHA256.Create())
                    return BitConverter.ToString(digest.ComputeHash(System.Text.Encoding.ASCII.GetBytes(body))).Replace("-", "").ToLowerInvariant();
            }
        }
        catch (System.Net.WebException) { return null; }
        catch (IOException) { return null; }
    }

    // A host under a selected domain: answered only through the tunnel, with
    // an IPv4 address from the router's names network and nothing else.
    private static string namesNetwork = "172.31.254.128/25";
    private static bool Named(string host)
    {
        try
        {
            var answers = System.Net.Dns.GetHostAddresses(host);
            if (answers.Length != 1 || answers[0].AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) return false;
            string[] network = namesNetwork.Split('/');
            byte[] address = answers[0].GetAddressBytes(), first = System.Net.IPAddress.Parse(network[0]).GetAddressBytes();
            uint mask = UInt32.MaxValue << (32 - Int32.Parse(network[1]));
            uint value = ((uint)address[0] << 24) | ((uint)address[1] << 16) | ((uint)address[2] << 8) | address[3];
            uint start = ((uint)first[0] << 24) | ((uint)first[1] << 16) | ((uint)first[2] << 8) | first[3];
            return (value & mask) == start;
        }
        catch (System.Net.Sockets.SocketException) { return false; }
    }
    private static string Digest(string text)
    {
        using (var digest = System.Security.Cryptography.SHA256.Create())
            return BitConverter.ToString(digest.ComputeHash(System.Text.Encoding.ASCII.GetBytes(text))).Replace("-", "").ToLowerInvariant();
    }

    // UDP through the path: a TXT question to a public resolver that answers
    // with the network it was asked from. Returns that network's digest.
    private static string UdpOrigin(string resolver)
    {
        try
        {
            var question = new System.Collections.Generic.List<byte> { 0x4f, 0x4f, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
            foreach (string label in "o-o.myaddr.l.google.com".Split('.'))
            { question.Add((byte)label.Length); question.AddRange(System.Text.Encoding.ASCII.GetBytes(label)); }
            question.AddRange(new byte[] { 0, 0, 16, 0, 1 });
            using (var socket = new System.Net.Sockets.UdpClient())
            {
                socket.Client.ReceiveTimeout = 5000;
                socket.Connect(resolver, 53);
                socket.Send(question.ToArray(), question.Count);
                System.Net.IPEndPoint from = null;
                string answer = System.Text.Encoding.ASCII.GetString(socket.Receive(ref from));
                var match = System.Text.RegularExpressions.Regex.Match(answer, @"edns0-client-subnet ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\.[0-9]{1,3}/");
                return match.Success ? Digest(match.Groups[1].Value) : "no-subnet";
            }
        }
        catch (System.Net.Sockets.SocketException) { return null; }
    }

    // The address a real browser is seen from, read out of its page.
    private static string BrowserOrigin(string browser, string url)
    {
        string profile = Path.Combine(Path.GetTempPath(), "ikev2-client-browser-" + Guid.NewGuid().ToString("N"));
        try
        {
            var start = new ProcessStartInfo(browser, "--headless=new --disable-gpu --no-first-run --no-sandbox --user-data-dir=\"" + profile + "\" --dump-dom " + url)
                { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            using (var process = Process.Start(start))
            {
                var output = process.StandardOutput.ReadToEndAsync();
                process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(40000)) { try { process.Kill(); } catch (InvalidOperationException) { } return null; }
                var match = System.Text.RegularExpressions.Regex.Match(output.Result, @">\s*([0-9]{1,3}(?:\.[0-9]{1,3}){3})\s*<");
                return match.Success ? Digest(match.Groups[1].Value) : null;
            }
        }
        catch (System.ComponentModel.Win32Exception) { return null; }
        finally { try { if (Directory.Exists(profile)) Directory.Delete(profile, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }

    private static void Route(string arguments)
    {
        using (var process = Process.Start(new ProcessStartInfo("route.exe", arguments) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }))
        { process.StandardOutput.ReadToEnd(); process.WaitForExit(10000); }
    }

    private static int Main(string[] args)
    {
        string step = "start";
        try
        {
            var config = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(args[0]));
            if (config.ContainsKey("names_network")) namesNetwork = (string)config["names_network"];
            string url = config.ContainsKey("probe_url") ? (string)config["probe_url"] : null;
            string target = url == null ? (string)config["probe_host"] : null; int port = url == null ? (int)config["probe_port"] : 0;
            Func<bool> reachable = () => url == null ? Echo(target, port) : Origin(url) != null;
            string endpoint, invite;
            ClientCommands.ParseInvitation((string)config["invitation"], out endpoint, out invite);
            Require(Await(view => view.State == "enrollment_required", 15000), "Fresh installation is not waiting for registration: " + Shown());
            step = "registration";
            Require(ClientCommands.Send("begin", endpoint, invite) == "accepted", "Service refused the invitation");
            ClientCommands.Send("continue");
            Require(Await(view => view.State == "registration_pending", 20000), "Invitation was not claimed: " + Shown());
            Console.WriteLine("READY_NATIVE_PENDING");
            if (!Await(view => view.State == "blocked" && view.GuardInstalled, 90000))
            {
                // Say where it stands, from this machine's side, before failing.
                string host = new Uri(endpoint).Host; string seen = "unresolved";
                try { seen = System.Net.Dns.GetHostAddresses(host).Length + " address(es)"; } catch (System.Net.Sockets.SocketException) { }
                bool reachable443 = false;
                try { using (var probe = new System.Net.Sockets.TcpClient()) { var pending = probe.BeginConnect(host, new Uri(endpoint).Port, null, null); reachable443 = pending.AsyncWaitHandle.WaitOne(4000) && probe.Connected; } } catch (System.Net.Sockets.SocketException) { }
                Require(false, "Registration did not complete: " + Shown() + "; server name: " + seen + "; port reachable: " + reachable443);
            }
            Require(!reachable(), "Selected service answered before any connection");
            Console.WriteLine("READY_NATIVE_ENABLE");
            Thread.Sleep(3000);
            step = "connection";
            Require(ClientCommands.Send("connect") == "accepted", "Connect refused");
            Require(Await(view => view.Protected, 90000), "Installed client did not reach protection: " + Shown());
            var open = ClientStatusReader.Read();
            Require(open.Routed && open.Wanted && open.Services.Length == 1 && open.Services[0] == (string)config["service"] && open.Domains >= 1,
                "Installed client status is incomplete");
            Require(reachable(), "Selected service did not answer through the installed client");
            if (url == null) Require(!Echo(target, (int)config["closed_port"]), "A port outside the assignment answered");
            else Console.WriteLine("PROBE_ORIGIN=" + Origin(url));
            if (url == null)
            {
                Require(Named("deep.cdn." + target), "A host under the selected domain was not answered through the tunnel");
                Require(Echo("deep.cdn." + target, port), "A host under the selected domain did not answer through the installed client");
            }
            else if (config.ContainsKey("probe_under"))
            {
                string under = (string)config["probe_under"];
                Require(Named(new Uri(under).Host), "A host under the selected domain was not answered through the tunnel");
                Console.WriteLine("PROBE_UNDER=" + Origin(under));
            }
            if (config.ContainsKey("probe_dual"))
            {
                // A name that has an IPv6 address in public DNS must have none here.
                Require(Named((string)config["probe_dual"]), "A name with a public IPv6 address was not held to its tunnel address");
                Console.WriteLine("A dual-stack name resolved to its tunnel address only");
            }
            if (config.ContainsKey("probe_udp"))
            {
                Console.WriteLine("PROBE_UDP=" + UdpOrigin((string)config["probe_udp"]));
            }
            if (config.ContainsKey("browsers"))
                foreach (object browser in (System.Collections.ArrayList)config["browsers"])
                    if (File.Exists((string)browser))
                        Console.WriteLine("PROBE_BROWSER=" + Path.GetFileNameWithoutExtension((string)browser) + "=" + BrowserOrigin((string)browser, url));
            if (config.ContainsKey("hijack"))
            {
                // Another program's more specific route - what a second VPN does
                // when it claims part of the same network. The client must
                // notice that the route is no longer its own and close.
                step = "foreign route";
                var hijack = (System.Collections.Generic.Dictionary<string, object>)config["hijack"];
                string add = (string)hijack["network"] + " MASK " + (string)hijack["mask"] + " " + (string)hijack["gateway"];
                Route("ADD " + add);
                try
                {
                    Require(Await(view => !view.Protected, 20000), "A foreign route into the names network left the protected status");
                    Console.WriteLine("Foreign route closed access: " + Shown());
                }
                finally { Route("DELETE " + (string)hijack["network"] + " MASK " + (string)hijack["mask"]); }
                Require(Await(view => view.Protected, 120000), "Access did not return after the foreign route was removed: " + Shown());
                Require(reachable(), "Selected service did not recover after the foreign route was removed");
                Console.WriteLine("Access returned once the foreign route was gone");
                step = "connection";
            }
            if (config.ContainsKey("hold_seconds"))
            {
                // Leaves the product open and connected for someone to look at.
                Console.WriteLine("HOLD_OPEN release=" + ClientStatusReader.Read().Release);
                Thread.Sleep((int)config["hold_seconds"] * 1000);
                Require(ClientStatusReader.Read().Protected, "Protection did not last while the window was looked at: " + Shown());
            }
            Console.WriteLine("Native protected status and selected service traffic verified");
            step = "service crash";
            // The supervisor restarts a killed service; nothing answers between.
            int before = 0;
            foreach (var process in Process.GetProcessesByName("ClientService")) using (process) { before = process.Id; process.Kill(); process.WaitForExit(10000); }
            Require(before != 0, "Service process not found");
            Require(!reachable(), "Selected service answered while the service was dead");
            Require(Await(view => view.Protected, 120000), "Killed service did not return to protection: " + Shown());
            Require(reachable(), "Selected service did not recover after the service was killed");
            Console.WriteLine("Installed service recovered after being killed");
            step = "disconnect";
            Require(ClientCommands.Send("disconnect") == "accepted", "Disconnect refused");
            Require(Await(view => view.State == "blocked" && !view.Wanted, 15000), "Disconnect did not close: " + Shown());
            Require(!reachable(), "Selected service answered after disconnect");
            Console.WriteLine("Installed product registration, protection, crash recovery and disconnect passed");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Installed product check failed at " + step + " (" + error.GetType().Name + ")");
            if (error is InvalidOperationException) Console.Error.WriteLine("Assertion: " + error.Message);
            return 1;
        }
    }
}
