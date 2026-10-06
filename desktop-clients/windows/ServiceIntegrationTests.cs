using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.ServiceProcess;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using IkeV2Manager.Client;
using System.IO.Pipes;
using System.Security.Principal;
using System.Threading;

internal static class ServiceIntegrationTests
{
    internal static void Run(Func<bool> tcp, Func<bool> udp, IPAddress target)
    {
        string name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name);
        bool created = false;
        GuardReceipt plan = null;
        try
        {
            using (var store = new GuardStore(name))
            using (var guard = new WfpGuard(Guid.NewGuid(), new[] { target }))
            {
                plan = guard.Receipt();
                store.SavePlan(plan);
                // SYSTEM never loads the test service from the developer's
                // writable checkout. Its executable inherits the protected ACL.
                File.Copy(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ClientService.exe"), Path.Combine(directory, "ClientService.exe"));
            }
            string binary = "\"" + Path.Combine(directory, "ClientService.exe") + "\" --test " + name;
            Sc("create " + name + " binPath= \"" + binary.Replace("\"", "\\\"") + "\" start= demand");
            created = true;
            using (var service = new ServiceController(name))
            {
                service.Start();
                service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(15));
                Require(!tcp() && !udp(), "SCM service installs persistent denial");
                var status = ReadStatus(directory);
                Require((string)status["State"] == "blocked" && !(bool)status["Protected"] && (bool)status["GuardInstalled"],
                    "service does not claim end-to-end protection");
                RestrictedAccessTests.Run(directory);
                Require(ClientStatusReader.Read(name).State == "blocked", "client authenticates live service status");
                CheckCommands(name, directory);
                using (var process = Process.GetProcessById((int)status["ProcessId"]))
                {
                    Require(process.MainModule.FileName.Equals(Path.Combine(directory, "ClientService.exe"), StringComparison.OrdinalIgnoreCase),
                        "test service process belongs to protected installation");
                    process.Kill();
                    Require(process.WaitForExit(5000), "SCM service process terminated");
                }
                service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(15));
                Require(!tcp() && !udp(), "service crash preserves denial");
                service.Start();
                service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(15));
                Require(!tcp() && !udp(), "SCM restart recovers persistent denial");
                service.Stop();
                service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(15));
                Require(!tcp() && !udp(), "normal service stop preserves denial");
                Require((string)ReadStatus(directory)["State"] == "stopped", "normal stop publishes stopped status");
                Require(ClientStatusReader.Read(name).State == "service_stopped", "client recognizes stopped SCM service");
            }
        }
        finally
        {
            if (created)
            {
                using (var service = new ServiceController(name))
                {
                    service.Refresh();
                    if (service.Status != ServiceControllerStatus.Stopped)
                    {
                        service.Stop();
                        service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(15));
                    }
                }
                Sc("delete " + name);
            }
            if (plan != null)
                using (var guard = WfpGuard.Resume(plan)) guard.Remove();
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
        Require(tcp() && udp(), "service scenario restores baseline");
    }

    private static void CheckCommands(string name, string directory)
    {
        Require(ClientCommands.Send("continue", service: name) == "accepted", "control channel authenticates SCM process");
        var deadline = Stopwatch.StartNew();
        while ((string)ReadStatus(directory)["State"] != "registration_error" && deadline.ElapsedMilliseconds < 5000) Thread.Sleep(50);
        Require((string)ReadStatus(directory)["State"] == "registration_error", "missing registration returns safe asynchronous error");
        string request = new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
            { "version", 1 }, { "operation", "begin" }, { "endpoint", "https://vpn.example.invalid/client/v1/enroll" },
            { "invitation", new string('a', 64) }
        });
        RestrictedAccessTests.CheckControl(() => RawControl(name, request));
        Require(RawControl(name, "{\"version\":1,\"operation\":\"remove\"}") == "invalid_request", "unrecognized control operation rejected");
        using (var oversized = OpenControl(name))
        {
            oversized.Write(new byte[] { 1, 16, 0, 0 }, 0, 4); oversized.Flush();
            var elapsed = Stopwatch.StartNew();
            Require(RawControl(name, "{\"version\":1,\"operation\":\"remove\"}") == "invalid_request" &&
                elapsed.ElapsedMilliseconds < 1500, "oversized frame is rejected without waiting for its body");
        }
        using (var slow = OpenControl(name))
        {
            slow.WriteByte(1); slow.Flush(); Thread.Sleep(3500);
            Require(RawControl(name, "{\"version\":1,\"operation\":\"remove\"}") == "invalid_request", "slow client does not destroy control ownership");
        }
        Require(ClientCommands.Send("begin", "https://vpn.example.invalid/client/v1/enroll", new string('a', 64), name) == "accepted",
            "administrator can persist registration through service");
        Require(File.Exists(Path.Combine(directory, "enrollment.json")), "control registration persisted encrypted state");
    }

    private static NamedPipeClientStream OpenControl(string name)
    {
        var pipe = new NamedPipeClientStream(".", ClientCommands.PipeName(name), PipeAccessRights.ReadWrite | PipeAccessRights.Synchronize,
            PipeOptions.Asynchronous, TokenImpersonationLevel.Identification, HandleInheritability.None);
        try { pipe.Connect(3000); return pipe; } catch { pipe.Dispose(); throw; }
    }

    private static string RawControl(string name, string request)
    {
        using (var pipe = OpenControl(name))
        {
            ClientCommands.Write(pipe, request);
            string response = (string)ClientCommands.Parse(ClientCommands.Read(pipe))["state"];
            ClientCommands.Write(pipe, "{}");
            return response;
        }
    }

    private static Dictionary<string, object> ReadStatus(string directory)
    {
        return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(directory, "status.json")));
    }

    private static void Sc(string arguments)
    {
        using (var process = Process.Start(new ProcessStartInfo {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "sc.exe"),
            Arguments = arguments, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
            RedirectStandardError = true
        }))
        {
            if (!process.WaitForExit(10000)) { process.Kill(); throw new Exception("SCM command timed out"); }
            if (process.ExitCode != 0) throw new Exception("SCM command failed: " + process.ExitCode);
        }
    }

    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception("Service behavior failed: " + name);
        Console.WriteLine("PASS " + name);
    }
}
