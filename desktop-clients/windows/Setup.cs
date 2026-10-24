using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.ServiceProcess;
using System.Windows.Forms;
using Microsoft.Win32;

// The one file a user runs, and the one an earlier client opens to update: it
// takes the installer for this machine's processor - lying next to it, or
// from the same release - checks it against the digest written in at build
// time, moves over an installation made by the setup program of earlier
// releases, and installs. The registration and the installed denials stay;
// only removal, from the list of installed programs, takes them away.
internal static class Setup
{
    private const string Name = "IKEv2ManagerClient", Title = "Waypoint";
    private const string Releases = "https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v";
    private const string EarlierKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + Name;
    private static readonly string System32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
    private static readonly string Destination = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Title);

    private sealed class Refusal : Exception { internal Refusal(string message) : base(message) { } }

    [STAThread]
    private static int Main(string[] args)
    {
        bool quiet = args.Length == 1 && args[0] == "/quiet";
        if (args.Length > 1 || (args.Length == 1 && !quiet)) return 2;
        try
        {
            if (!Environment.Is64BitOperatingSystem) throw new Refusal("Нужна 64-разрядная Windows.");
            if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
                throw new Refusal("Запустите установку с правами администратора.");
            string version = Assembly.GetExecutingAssembly().GetName().Version.ToString(3);
            string architecture = NativeArm64() ? "arm64" : "x64";
            string package = Fetch(version, architecture);
            try
            {
                bool windowWasOpen = MoveEarlier();
                windowWasOpen |= CloseWindows("Waypoint");
                int code = Run(Path.Combine(System32, "msiexec.exe"), "/i \"" + package + "\" /qb! /norestart /l*v \"" + Path.Combine(Path.GetTempPath(), "Waypoint-setup.log") + "\"");
                // 3010: installed, and a restart will finish it.
                if (code != 0 && code != 3010) throw new Refusal("Установка не завершена (код " + code + "). Запустите установку ещё раз.");
                if (quiet ? windowWasOpen : AskToOpen(version)) OpenWindow();
            }
            finally { try { File.Delete(package); Directory.Delete(Path.GetDirectoryName(package)); } catch (Exception) { } }
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

    // The installer for this machine, in a folder only administrators can
    // write to, and only if it is the one this setup was built with.
    private static string Fetch(string version, string architecture)
    {
        string file = "Waypoint-" + version + "-" + architecture + ".msi";
        string expected = architecture == "arm64" ? Release.Arm64 : Release.X64;
        string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Temp", "Waypoint-" + Guid.NewGuid().ToString("N"));
        // Anybody may create files in the system's Temp; this folder is the
        // administrators' and the system's alone, so nothing is swapped in
        // between the check and the installation.
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { WellKnownSidType.BuiltinAdministratorsSid, WellKnownSidType.LocalSystemSid })
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        Directory.CreateDirectory(folder, security);
        string target = Path.Combine(folder, file);
        string beside = Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), file);
        if (File.Exists(beside) && Digest(beside) == expected) { File.Copy(beside, target); return target; }
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
        try
        {
            using (var client = new WebClient()) client.DownloadFile(Releases + version + "/" + file, target);
        }
        catch (WebException) { throw new Refusal("Не удалось скачать установщик. Проверьте интернет и запустите установку ещё раз."); }
        if (Digest(target) != expected) { File.Delete(target); throw new Refusal("Скачанный установщик повреждён. Запустите установку ещё раз."); }
        return target;
    }

    private static string Digest(string path)
    {
        using (var sha = SHA256.Create()) using (var stream = File.OpenRead(path))
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }

    // An installation by the setup program of earlier releases: its service
    // and files go, its registration and denials in ProgramData stay for the
    // new service to take up. Says whether its window was open.
    private static bool MoveEarlier()
    {
        string uninstall;
        using (var key = Registry.LocalMachine.OpenSubKey(EarlierKey)) uninstall = key == null ? null : key.GetValue("UninstallString") as string;
        if (uninstall == null) return false;
        string earlierSetup = Path.Combine(Destination, "Setup.exe");
        if (!uninstall.StartsWith("\"" + earlierSetup + "\"", StringComparison.OrdinalIgnoreCase))
            throw new Refusal("Найдена установка Waypoint в другом месте. Удалите её и запустите установку ещё раз.");
        bool windowWasOpen = CloseWindows(Name);
        if (ServiceExists())
        {
            using (var service = new ServiceController(Name))
            {
                if (service.Status != ServiceControllerStatus.Stopped)
                {
                    if (service.Status != ServiceControllerStatus.StopPending) service.Stop();
                    service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(60));
                }
            }
            if (Run(Path.Combine(System32, "sc.exe"), "delete " + Name) != 0) throw new Refusal("Прежнюю службу не удалось заменить. Запустите установку ещё раз.");
        }
        foreach (string file in new[] { "Setup.exe", "IKEv2ManagerClient.exe", "ClientService.exe" })
        {
            string path = Path.Combine(Destination, file);
            if (File.Exists(path)) File.Delete(path);
        }
        string shortcut = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), Title + ".lnk");
        if (File.Exists(shortcut)) File.Delete(shortcut);
        Registry.LocalMachine.DeleteSubKeyTree(EarlierKey, false);
        return windowWasOpen;
    }

    private static bool CloseWindows(string process)
    {
        bool found = false;
        foreach (var window in Process.GetProcessesByName(process))
            using (window)
            {
                found = true;
                try { window.Kill(); window.WaitForExit(5000); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { }
            }
        return found;
    }

    // The last step of a setup the person runs: it is done, and the program
    // opens unless they clear the box.
    private static bool AskToOpen(string version)
    {
        using (var done = new Form { Text = Title, ClientSize = new System.Drawing.Size(360, 130), FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false, MinimizeBox = false, StartPosition = FormStartPosition.CenterScreen, Font = new System.Drawing.Font("Segoe UI", 10) })
        {
            var open = new CheckBox { Text = "Открыть " + Title, Checked = true, AutoSize = true, Location = new System.Drawing.Point(22, 54) };
            var close = new Button { Text = "Готово", DialogResult = DialogResult.OK, AutoSize = true, Location = new System.Drawing.Point(250, 88) };
            done.Controls.Add(new Label { Text = Title + " " + version + " установлен.", AutoSize = true, Location = new System.Drawing.Point(20, 20) });
            done.Controls.Add(open); done.Controls.Add(close);
            done.AcceptButton = close;
            done.TopMost = true;
            done.Shown += (sender, args) => { done.Activate(); close.Focus(); };
            done.ShowDialog();
            return open.Checked;
        }
    }

    // Setup runs as an administrator; the window must not. Asked to open a
    // file, the desktop's own shell starts it as the person signed in.
    private static void OpenWindow()
    {
        try
        {
            Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"),
                "\"" + Path.Combine(Destination, "Waypoint.exe") + "\"") { UseShellExecute = false });
        }
        catch (System.ComponentModel.Win32Exception) { }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);

    // The machine's own processor, whatever this program runs as on it.
    private static bool NativeArm64()
    {
        ushort process, native;
        try { return IsWow64Process2(Process.GetCurrentProcess().Handle, out process, out native) && native == 0xAA64; }
        catch (EntryPointNotFoundException) { return false; }
    }

    private static bool ServiceExists()
    {
        foreach (var service in ServiceController.GetServices())
            using (service) if (String.Equals(service.ServiceName, Name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static int Run(string path, string arguments)
    {
        using (var process = Process.Start(new ProcessStartInfo(path, arguments) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = System32 }))
        {
            if (!process.WaitForExit(600000)) throw new Refusal("Установка не отвечает. Запустите установку ещё раз.");
            return process.ExitCode;
        }
    }
}
