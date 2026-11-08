using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.ServiceProcess;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// The one file a user runs, and the one an earlier client opens to update. It
// carries the installers of both processors inside it and needs no network: a
// download that hangs or a release page that answers 504 cannot stop it. Its
// window is there at once and says what it does, what went wrong and how to go
// on. It takes the installer for this machine's processor, checks it against
// the digest written in at build time, moves over an installation made by the
// setup program of earlier releases, and installs. The registration and the
// installed denials stay; only removal, from the list of installed programs,
// takes them away.
internal static class Setup
{
    private const string Name = "IKEv2ManagerClient", Title = "Waypoint";
    private const string EarlierKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + Name;
    private static readonly string System32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
    private static readonly string Destination = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Title);
    internal static readonly string Log = Path.Combine(Path.GetTempPath(), "Waypoint-setup.log");

    internal sealed class Refusal : Exception
    {
        // Whether running it again can help: another installation finishing,
        // a service that took its time to stop.
        internal readonly bool Again;
        internal Refusal(string message, bool again = true) : base(message) { Again = again; }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool quiet = args.Length == 1 && args[0] == "/quiet";
        if (args.Length > 1 || (args.Length == 1 && !quiet)) return 2;
        string version = Assembly.GetExecutingAssembly().GetName().Version.ToString(3);
        if (quiet)
        {
            try { if (Install(version, text => { })) OpenWindow(); return 0; }
            catch (Exception) { return 1; }
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var window = new SetupWindow(version)) { Application.Run(window); return window.Succeeded ? 0 : 1; }
    }

    // Everything the setup does, telling each step to `say`. Returns whether
    // the window of the program was open before.
    internal static bool Install(string version, Action<string> say)
    {
        if (!Environment.Is64BitOperatingSystem) throw new Refusal("Нужна 64-разрядная Windows.", false);
        if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
            throw new Refusal("Запустите установку с правами администратора.", false);
        string architecture = NativeArm64() ? "arm64" : "x64";
        say("Проверяю установщик…");
        string package = Unpack(version, architecture);
        try
        {
            say("Закрываю прежнюю версию…");
            bool windowWasOpen = MoveEarlier();
            windowWasOpen |= CloseWindows("Waypoint");
            say("Устанавливаю Waypoint " + version + "…");
            int code = Run(Path.Combine(System32, "msiexec.exe"), "/i \"" + package + "\" /qn /norestart /l*v \"" + Log + "\"");
            // 3010: installed, and a restart will finish it.
            if (code == 1618) throw new Refusal("Сейчас идёт другая установка Windows. Дождитесь её конца и нажмите «Повторить».");
            if (code == 1602) throw new Refusal("Установка отменена.");
            if (code != 0 && code != 3010) throw new Refusal("Установка не завершена (код " + code + "). Нажмите «Повторить»; если не поможет, отправьте журнал установки.");
            return windowWasOpen;
        }
        finally { try { File.Delete(package); Directory.Delete(Path.GetDirectoryName(package)); } catch (Exception) { } }
    }

    // The installer for this machine, out of this file into a folder only
    // administrators can write to, and only if it is the one this setup was
    // built with.
    private static string Unpack(string version, string architecture)
    {
        string resource = "Waypoint-" + architecture + ".msi";
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
        string target = Path.Combine(folder, "Waypoint-" + version + "-" + architecture + ".msi");
        using (var source = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
        {
            if (source == null) throw new Refusal("В этом файле нет установщика для " + (architecture == "arm64" ? "ARM64" : "x64") + ". Скачайте WaypointSetup.exe заново.", false);
            using (var output = File.Create(target)) source.CopyTo(output);
        }
        if (Digest(target) != expected) throw new Refusal("Файл установки повреждён. Скачайте WaypointSetup.exe заново.", false);
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
            throw new Refusal("Найдена установка Waypoint в другом месте. Удалите её в «Параметрах» Windows и запустите установку ещё раз.", false);
        bool windowWasOpen = CloseWindows(Name);
        if (ServiceExists())
        {
            using (var service = new ServiceController(Name))
            {
                if (service.Status != ServiceControllerStatus.Stopped)
                {
                    if (service.Status != ServiceControllerStatus.StopPending) service.Stop();
                    try { service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(60)); }
                    catch (System.ServiceProcess.TimeoutException) { throw new Refusal("Прежняя служба Waypoint не остановилась за минуту. Нажмите «Повторить»."); }
                }
            }
            if (Run(Path.Combine(System32, "sc.exe"), "delete " + Name) != 0) throw new Refusal("Прежнюю службу не удалось заменить. Нажмите «Повторить».");
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

    // Setup runs as an administrator; the window must not. Asked to open a
    // file, the desktop's own shell starts it as the person signed in.
    internal static void OpenWindow()
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
            if (!process.WaitForExit(600000)) throw new Refusal("Установка не отвечает десять минут. Нажмите «Повторить».");
            return process.ExitCode;
        }
    }
}

// The setup's window: there at once, one line for what it does now, a bar
// that moves while it works, and at the end either "installed" with the box
// to open the program, or what went wrong with "Retry" where that can help.
internal sealed class SetupWindow : Form
{
    private readonly string version;
    private readonly Label heading = new Label(), status = new Label();
    private readonly ProgressBar bar = new ProgressBar();
    private readonly CheckBox open = new CheckBox();
    private readonly Button primary = new Button(), secondary = new Button();
    private readonly LinkLabel log = new LinkLabel();
    private bool working;
    internal bool Succeeded { get; private set; }

    internal SetupWindow(string version)
    {
        this.version = version;
        Text = "Установка Waypoint";
        Font = SystemFonts.MessageBoxFont;
        AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(440, 176);
        try { Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch (ArgumentException) { }

        heading.Text = "Waypoint " + version;
        heading.Font = new Font(Font.FontFamily, Font.Size * 1.5f);
        heading.AutoSize = true;
        heading.Location = new Point(20, 18);
        status.AutoSize = false;
        status.Location = new Point(22, 58);
        status.Size = new Size(396, 40);
        status.Text = "Подготовка…";
        bar.Style = ProgressBarStyle.Marquee;
        bar.MarqueeAnimationSpeed = 30;
        bar.Location = new Point(22, 104);
        bar.Size = new Size(396, 6);
        open.Text = "Открыть Waypoint";
        open.Checked = true;
        open.AutoSize = true;
        open.Location = new Point(22, 102);
        open.Visible = false;
        log.Text = "Журнал установки";
        log.AutoSize = true;
        log.Location = new Point(22, 104);
        log.Visible = false;
        log.LinkClicked += delegate { try { Process.Start(new ProcessStartInfo("notepad.exe", "\"" + Setup.Log + "\"")); } catch (Exception) { } };
        foreach (var button in new[] { primary, secondary })
        {
            button.Size = new Size(104, 30);
            button.Visible = false;
        }
        primary.Location = new Point(314, 132);
        secondary.Location = new Point(202, 132);
        primary.Click += OnPrimary;
        secondary.Click += delegate { Close(); };
        secondary.Text = "Закрыть";
        Controls.AddRange(new Control[] { heading, status, bar, open, log, primary, secondary });
        Shown += delegate { Start(); };
        // Closing while it installs would leave the installation half done.
        FormClosing += (sender, args) => { if (working) args.Cancel = true; };
    }

    private void Start()
    {
        working = true;
        bar.Visible = true;
        open.Visible = log.Visible = primary.Visible = secondary.Visible = false;
        status.ForeColor = SystemColors.ControlText;
        var work = new Thread(() =>
        {
            Exception failure = null;
            try { Setup.Install(version, text => BeginInvoke((Action)(() => status.Text = text))); }
            catch (Exception error) { failure = error; }
            BeginInvoke((Action)(() => Finish(failure)));
        }) { IsBackground = true };
        work.Start();
    }

    private void Finish(Exception failure)
    {
        working = false;
        bar.Visible = false;
        if (failure == null)
        {
            Succeeded = true;
            status.Text = "Waypoint " + version + " установлен.";
            open.Visible = true;
            primary.Text = "Готово";
            primary.Visible = true;
            AcceptButton = primary;
            primary.Focus();
            return;
        }
        var refusal = failure as Setup.Refusal;
        // Type only for what this program did not foresee: a path or a
        // system message may carry local details.
        status.Text = refusal != null ? refusal.Message : "Установка не завершена (" + failure.GetType().Name + "). Нажмите «Повторить».";
        status.ForeColor = Color.FromArgb(0x99, 0x3A, 0x31);
        log.Visible = File.Exists(Setup.Log);
        bool again = refusal == null || refusal.Again;
        primary.Text = again ? "Повторить" : "Закрыть";
        primary.Visible = true;
        secondary.Visible = again;
        AcceptButton = primary;
        primary.Focus();
    }

    private void OnPrimary(object sender, EventArgs args)
    {
        if (primary.Text == "Повторить") { Start(); return; }
        if (Succeeded && open.Checked) Setup.OpenWindow();
        Close();
    }
}
