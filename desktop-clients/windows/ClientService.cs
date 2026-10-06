using System;
using System.ServiceProcess;
using System.Text.RegularExpressions;

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

        protected override void OnStart(string[] args)
        {
            runtime = new GuardRuntime(storeName, true);
            try { commands = new ClientCommandServer(ServiceName, runtime); }
            catch { runtime.Dispose(); runtime = null; throw; }
        }
        protected override void OnStop()
        {
            RequestAdditionalTime(60000);
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
            string name = "IKEv2ManagerClient";
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
