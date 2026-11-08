using System;
using System.ServiceProcess;
using System.Text.RegularExpressions;
using System.Threading;

namespace IkeV2Manager.Client
{
    internal sealed class ClientService : ServiceBase
    {
        private readonly string storeName;
        private GuardRuntime runtime;
        private ClientCommandServer commands;

        private ClientService(string name, string store)
        {
            ServiceName = name;
            storeName = store;
            AutoLog = false;
            CanShutdown = CanStop = true;
        }

        // An installation of the tests restarts after a stalled step within
        // seconds, not minutes; nothing else about it differs.
        private bool Test { get { return storeName != Removal.Product; } }

        protected override void OnStart(string[] args)
        {
            runtime = new GuardRuntime(storeName, true, Test ? TimeSpan.FromSeconds(20) : (TimeSpan?)null);
            try { commands = new ClientCommandServer(ServiceName, runtime); }
            catch { runtime.Dispose(); runtime = null; throw; }
        }
        protected override void OnStop()
        {
            RequestAdditionalTime(60000);
            // A test of the reset needs a service that does not stop.
            if (Test && System.IO.File.Exists(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), storeName, "test-stall-stop")))
                Thread.Sleep(Timeout.Infinite);
            StopController();
        }
        private void StopController()
        {
            if (commands != null) { commands.Dispose(); commands = null; }
            if (runtime != null) { runtime.Dispose(); runtime = null; }
        }
        protected override void OnShutdown() { StopController(); }

        private static int Main(string[] args)
        {
            string name = Removal.Product;
            // Asked for by the window or the installer, with an administrator's right.
            if (args.Length == 1 && Array.IndexOf(Maintenance.Requests, args[0]) >= 0) return Maintenance.Run(name, args[0]);
            if (args.Length == 1 && args[0] == "--remove") return Maintenance.Run(name, "--uninstall");
            if (args.Length != 0)
            {
                // Isolated service integration tests use their own protected
                // store and SCM identity. No configurable command or user path.
                if (args.Length != 2 || args[0] != "--test" ||
                    !Regex.IsMatch(args[1], @"\AIKEv2Manager-Test-[a-f0-9]{32}\z")) return 2;
                name = args[1];
            }
            ServiceBase.Run(new ClientService(name, name));
            return 0;
        }
    }
}
