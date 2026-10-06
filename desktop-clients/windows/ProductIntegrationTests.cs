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

    private static int Main(string[] args)
    {
        string step = "start";
        try
        {
            var config = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(args[0]));
            string target = (string)config["probe_host"]; int port = (int)config["probe_port"];
            string endpoint, invite;
            ClientCommands.ParseInvitation((string)config["invitation"], out endpoint, out invite);
            Require(Await(view => view.State == "enrollment_required", 15000), "Fresh installation is not waiting for registration: " + Shown());
            step = "registration";
            Require(ClientCommands.Send("begin", endpoint, invite) == "accepted", "Service refused the invitation");
            ClientCommands.Send("continue");
            Require(Await(view => view.State == "registration_pending", 20000), "Invitation was not claimed: " + Shown());
            Console.WriteLine("READY_NATIVE_PENDING");
            Require(Await(view => view.State == "blocked" && view.GuardInstalled, 90000), "Registration did not complete: " + Shown());
            Require(!Echo(target, port), "Selected service answered before any connection");
            Console.WriteLine("READY_NATIVE_ENABLE");
            Thread.Sleep(3000);
            step = "connection";
            Require(ClientCommands.Send("connect") == "accepted", "Connect refused");
            Require(Await(view => view.Protected, 90000), "Installed client did not reach protection: " + Shown());
            var open = ClientStatusReader.Read();
            Require(open.Routed && open.Wanted && open.Services.Length == 1 && open.Services[0] == "api" && open.Domains == 1,
                "Installed client status is incomplete");
            Require(Echo(target, port), "Selected service did not answer through the installed client");
            Require(!Echo(target, (int)config["closed_port"]), "A port outside the assignment answered");
            Console.WriteLine("Native protected status and selected service traffic verified");
            step = "service crash";
            // The supervisor restarts a killed service; nothing answers between.
            int before = 0;
            foreach (var process in Process.GetProcessesByName("ClientService")) using (process) { before = process.Id; process.Kill(); process.WaitForExit(10000); }
            Require(before != 0, "Service process not found");
            Require(!Echo(target, port), "Selected service answered while the service was dead");
            Require(Await(view => view.Protected, 120000), "Killed service did not return to protection: " + Shown());
            Require(Echo(target, port), "Selected service did not recover after the service was killed");
            Console.WriteLine("Installed service recovered after being killed");
            step = "disconnect";
            Require(ClientCommands.Send("disconnect") == "accepted", "Disconnect refused");
            Require(Await(view => view.State == "blocked" && !view.Wanted, 15000), "Disconnect did not close: " + Shown());
            Require(!Echo(target, port), "Selected service answered after disconnect");
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
