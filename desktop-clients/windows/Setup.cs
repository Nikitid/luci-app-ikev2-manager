using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Windows.Forms;
using Microsoft.Win32;

// One file a user runs: installs or updates the service and the window, or with
// /uninstall takes everything away again. An update keeps the enrolled state and
// the installed denials; only uninstallation removes them.
internal static class Setup
{
    private const string Name = "IKEv2ManagerClient", Title = "Waypoint";
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + Name;
    private static readonly string System32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
    private static readonly string Destination = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Title);
    private static readonly string ServicePath = Path.Combine(Destination, "ClientService.exe");
    private static readonly string AppPath = Path.Combine(Destination, "IKEv2ManagerClient.exe");
    private static readonly string Shortcut = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), Title + ".lnk");

    // Earlier builds switched the browsers' own encrypted DNS off by policy.
    // That reaches beyond this program's services and is no longer done; what
    // such a build wrote is recorded here and is taken back on update and on
    // removal. Nothing new is written.
    private const string OwnedKey = @"Software\IKEv2ManagerClient";
    // `everything` also drops this program's whole record, at removal.
    private static void RemoveBrowserPolicies(bool everything)
    {
        using (var record = Registry.LocalMachine.OpenSubKey(OwnedKey))
        {
            var owned = record == null ? null : record.GetValue("BrowserPolicies") as string[];
            foreach (string identity in owned ?? new string[0])
            {
                string[] parts = identity.Split('|');
                if (parts.Length != 2) continue;
                using (var key = Registry.LocalMachine.OpenSubKey(parts[0], true))
                    if (key != null) key.DeleteValue(parts[1], false);
            }
        }
        if (everything) Registry.LocalMachine.DeleteSubKeyTree(OwnedKey, false);
        else using (var record = Registry.LocalMachine.OpenSubKey(OwnedKey, true)) if (record != null) record.DeleteValue("BrowserPolicies", false);
    }

    private sealed class Refusal : Exception { internal Refusal(string message) : base(message) { } }

    [STAThread]
    // The last step of an installation: it is done, and the program opens
    // unless the user clears the box.
    private static bool AskToOpen()
    {
        using (var done = new Form { Text = Title, ClientSize = new System.Drawing.Size(360, 130), FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false, MinimizeBox = false, StartPosition = FormStartPosition.CenterScreen, Font = new System.Drawing.Font("Segoe UI", 10) })
        {
            var open = new CheckBox { Text = "Открыть " + Title, Checked = true, AutoSize = true, Location = new System.Drawing.Point(22, 54) };
            var close = new Button { Text = "Готово", DialogResult = DialogResult.OK, AutoSize = true, Location = new System.Drawing.Point(250, 88) };
            done.Controls.Add(new Label { Text = Title + " установлен.", AutoSize = true, Location = new System.Drawing.Point(20, 20) });
            done.Controls.Add(open); done.Controls.Add(close);
            done.AcceptButton = close;
            done.ShowDialog();
            return open.Checked;
        }
    }

    private static int Main(string[] args)
    {
        bool quiet = Array.IndexOf(args, "/quiet") >= 0, remove = Array.IndexOf(args, "/uninstall") >= 0, reset = Array.IndexOf(args, "/reset") >= 0;
        foreach (string argument in args)
            if (argument != "/quiet" && argument != "/uninstall" && argument != "/reset") return 2;
        if (remove && reset) return 2;
        try
        {
            if (!Environment.Is64BitOperatingSystem || !Environment.Is64BitProcess) throw new Refusal("Нужна 64-разрядная Windows.");
            if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
                throw new Refusal("Запустите установку с правами администратора.");
            if (reset) { Reset(); return 0; }
            if (remove)
            {
                if (!quiet && MessageBox.Show("Удалить " + Title + "?\n\nРегистрация устройства будет удалена.", Title, MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return 0;
                Uninstall();
                if (!quiet) MessageBox.Show(Title + " удалён.", Title);
                return 0;
            }
            Install();
            if (!quiet)
            {
                if (AskToOpen()) Process.Start(new ProcessStartInfo(AppPath) { WorkingDirectory = Destination, UseShellExecute = false });
            }
            return 0;
        }
        catch (Refusal refusal) { if (!quiet) MessageBox.Show(refusal.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
        catch (Exception error)
        {
            // Type only: a path or a system message may carry local details.
            if (!quiet) MessageBox.Show("Установка не завершена (" + error.GetType().Name + "). Запустите установку ещё раз.",
                Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static void Install()
    {
        RejectRedirected(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Destination, ServicePath, AppPath);
        bool exists = ServiceExists();
        if (exists && !OwnService()) throw new Refusal("Имя службы клиента занято другой программой. Установка остановлена.");
        if (exists) StopService();
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        foreach (var sid in new[] { WellKnownSidType.BuiltinAdministratorsSid, WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinUsersSid })
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null),
                sid == WellKnownSidType.BuiltinUsersSid ? FileSystemRights.ReadAndExecute : FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        // An open window holds its own file: an update over it used to stop
        // half way, with the service already stopped. The window is closed;
        // the user opens it again, or setup does at the end.
        foreach (var process in Process.GetProcessesByName("IKEv2ManagerClient"))
            using (process) { try { process.Kill(); process.WaitForExit(5000); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { } }
        Directory.CreateDirectory(Destination);
        Directory.SetAccessControl(Destination, security);
        Place("ClientService.exe", ServicePath);
        Place("IKEv2ManagerClient.exe", AppPath);
        string self = Path.Combine(Destination, "Setup.exe");
        if (!String.Equals(Path.GetFullPath(Assembly.GetExecutingAssembly().Location), self, StringComparison.OrdinalIgnoreCase))
            Inherit(self, () => File.Copy(Assembly.GetExecutingAssembly().Location, self, true));
        if (!exists) Run("sc.exe", "create " + Name + " binPath= \"\\\"" + ServicePath + "\\\"\" start= auto DisplayName= \"" + Title + "\"");
        else Run("sc.exe", "config " + Name + " start= auto");
        Run("sc.exe", "description " + Name + " \"Keeps selected services inside the organization's IKEv2 tunnel and blocks them outside it.\"");
        Run("sc.exe", "failure " + Name + " reset= 86400 actions= restart/5000/restart/15000/restart/60000");
        using (var service = new ServiceController(Name))
        {
            service.Start();
            service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
        }
        object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
        object link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { Shortcut });
        link.GetType().InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { AppPath });
        link.GetType().InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, link, new object[] { Destination });
        link.GetType().InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
        RemoveBrowserPolicies(false);
        using (var key = Registry.LocalMachine.CreateSubKey(UninstallKey))
        {
            key.SetValue("DisplayName", Title);
            key.SetValue("DisplayVersion", Assembly.GetExecutingAssembly().GetName().Version.ToString(3));
            key.SetValue("Publisher", "Waypoint");
            key.SetValue("InstallLocation", Destination);
            key.SetValue("DisplayIcon", AppPath);
            key.SetValue("UninstallString", "\"" + self + "\" /uninstall");
            key.SetValue("QuietUninstallString", "\"" + self + "\" /uninstall /quiet");
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
    }

    // Everything the program set up on this computer goes - the VPN
    // connection, the blocking, the names, the registration - and the program
    // stays, ready to register again. The same removal uninstallation runs,
    // done by the service's own binary while the service is stopped.
    private static void Reset()
    {
        if (!ServiceExists() || !File.Exists(ServicePath)) throw new Refusal("Программа не установлена.");
        if (!OwnService()) throw new Refusal("Служба с именем клиента принадлежит другой программе.");
        StopService();
        try { Run(ServicePath, "--remove"); }
        finally
        {
            using (var service = new ServiceController(Name))
            {
                service.Start();
                service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
            }
        }
    }

    private static void Uninstall()
    {
        if (ServiceExists())
        {
            if (!OwnService()) throw new Refusal("Служба с именем клиента принадлежит другой программе. Удаление остановлено.");
            StopService();
        }
        // The service binary owns the knowledge of what it installed.
        if (File.Exists(ServicePath)) Run(ServicePath, "--remove");
        else if (Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), Name)))
            throw new Refusal("Файлы клиента повреждены: сначала установите клиент заново, затем удалите его.");
        if (ServiceExists()) Run("sc.exe", "delete " + Name);
        RemoveBrowserPolicies(true);
        if (File.Exists(Shortcut)) File.Delete(Shortcut);
        Registry.LocalMachine.DeleteSubKeyTree(UninstallKey, false);
        foreach (var process in Process.GetProcessesByName("IKEv2ManagerClient"))
            using (process) { try { process.Kill(); process.WaitForExit(5000); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { } }
        string self = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
        foreach (string file in new[] { ServicePath, AppPath }) if (File.Exists(file)) File.Delete(file);
        string installed = Path.Combine(Destination, "Setup.exe");
        if (!String.Equals(self, installed, StringComparison.OrdinalIgnoreCase))
        {
            if (File.Exists(installed)) File.Delete(installed);
            if (Directory.Exists(Destination)) Directory.Delete(Destination, false);
        }
        else
        {
            // A running image cannot delete itself; Windows removes it and the
            // then-empty folder once this process has exited.
            Process.Start(new ProcessStartInfo(Path.Combine(System32, "cmd.exe"),
                "/d /c ping -n 3 127.0.0.1 >nul & del /f /q \"" + installed + "\" & rmdir \"" + Destination + "\"")
                { CreateNoWindow = true, UseShellExecute = false, WorkingDirectory = System32 });
        }
    }

    private static void Place(string resource, string destination)
    {
        Inherit(destination, () =>
        {
            using (var source = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
            {
                if (source == null) throw new Refusal("Установочный файл повреждён.");
                using (var target = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None)) source.CopyTo(target);
            }
        });
    }

    // A file that existed may carry its own permissions; after writing it must
    // have only what the protected folder gives.
    private static void Inherit(string path, Action write)
    {
        write();
        var security = File.GetAccessControl(path);
        security.SetAccessRuleProtection(false, false);
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, false, typeof(SecurityIdentifier)))
            security.RemoveAccessRule(rule);
        File.SetAccessControl(path, security);
    }

    private static void RejectRedirected(params string[] paths)
    {
        foreach (string path in paths)
            if ((File.Exists(path) || Directory.Exists(path)) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new Refusal("Папка установки перенаправлена в другое место. Установка остановлена.");
    }

    private static bool ServiceExists()
    {
        foreach (var service in ServiceController.GetServices())
            using (service) if (String.Equals(service.ServiceName, Name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static bool OwnService()
    {
        using (var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + Name))
        {
            if (key == null) return false;
            string image = key.GetValue("ImagePath") as string, account = key.GetValue("ObjectName") as string;
            return image == "\"" + ServicePath + "\"" && String.Equals(account, "LocalSystem", StringComparison.OrdinalIgnoreCase);
        }
    }

    private static void StopService()
    {
        using (var service = new ServiceController(Name))
        {
            if (service.Status == ServiceControllerStatus.Stopped) return;
            if (service.Status != ServiceControllerStatus.StopPending) service.Stop();
            service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(60));
        }
    }

    private static void Run(string program, string arguments)
    {
        string path = Path.IsPathRooted(program) ? program : Path.Combine(System32, program);
        using (var process = Process.Start(new ProcessStartInfo(path, arguments) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = System32 }))
        {
            process.StandardOutput.ReadToEnd(); process.StandardError.ReadToEnd();
            if (!process.WaitForExit(120000) || process.ExitCode != 0) throw new InvalidOperationException("Step failed");
        }
    }
}
