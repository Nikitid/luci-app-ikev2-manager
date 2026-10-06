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

    private static int Main(string[] args)
    {
        string step = "start";
        try
        {
            var config = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(args[0]));
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
            Require(Await(view => view.State == "blocked" && view.GuardInstalled, 90000), "Registration did not complete: " + Shown());
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
