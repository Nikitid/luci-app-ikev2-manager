using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Management;
using System.Net;
using System.Reflection;
using System.Security;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Xml;

namespace Nikitid.IkeV2ProfileInstaller
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                AppInvocation invocation = AppInvocation.Parse(args,
                    AppDomain.CurrentDomain.BaseDirectory);
                ProfileDocument profile = String.IsNullOrEmpty(invocation.ProfilePath) ?
                    null : ProfileDocument.Load(invocation.ProfilePath);
                if (profile != null && !String.IsNullOrEmpty(invocation.FriendlyName))
                    profile.SetName(invocation.FriendlyName);
                Application.Run(new InstallerForm(profile, invocation.Operation));
            }
            catch (Exception exception)
            {
                InstallerLog.Write("Startup failed", exception);
                MessageBox.Show(ExceptionText.Format(exception), "Nikitid IKEv2 Setup",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }

    internal sealed class InstallerForm : Form
    {
        private ProfileDocument profile;
        private readonly Label statusLabel;
        private readonly StatusDot statusDot;
        private readonly Button installButton;
        private readonly Button removeButton;
        private readonly Button openButton;
        private readonly Button browseButton;
        private readonly TextBox nameTextBox;
        private readonly Label detailsValueLabel;

        private readonly string automaticOperation;

        internal InstallerForm(ProfileDocument profile, string automaticOperation)
        {
            this.profile = profile;
            this.automaticOperation = automaticOperation;
            Text = "Nikitid IKEv2 Setup";
            ClientSize = new Size(720, 420);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 10F);
            ForeColor = AppPalette.Text;
            BackColor = AppPalette.Surface;
            AutoScaleMode = AutoScaleMode.Dpi;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ??
                SystemIcons.Application;

            Panel card = new Panel {
                Dock = DockStyle.Fill,
                BackColor = AppPalette.Surface
            };
            Controls.Add(card);

            card.Controls.Add(new Label {
                Text = "IKEv2 VPN",
                Font = new Font("Segoe UI Semibold", 21F),
                ForeColor = AppPalette.Text,
                AutoSize = true,
                Location = new Point(44, 43),
                BackColor = AppPalette.Surface
            });
            browseButton = MakeButton("Выбрать XML", 540, 44, 136, false, BrowseProfile);
            card.Controls.Add(browseButton);
            card.Controls.Add(new Label {
                Text = "Настройка защищённого подключения Windows",
                Font = new Font("Segoe UI", 9.5F),
                ForeColor = AppPalette.Muted,
                AutoSize = true,
                Location = new Point(44, 86),
                BackColor = AppPalette.Surface
            });
            card.Controls.Add(new Label {
                Text = "Имя подключения\n\nСервер\nDNS через VPN\nРежим",
                ForeColor = AppPalette.Muted,
                AutoSize = true,
                Location = new Point(44, 124),
                Font = new Font("Segoe UI", 9.5F),
                BackColor = AppPalette.Surface
            });
            nameTextBox = new TextBox {
                Text = profile == null ? "" : profile.Name,
                Location = new Point(12, 8),
                Size = new Size(454, 22),
                BorderStyle = BorderStyle.None,
                BackColor = AppPalette.Input,
                ForeColor = AppPalette.Text,
                Font = new Font("Segoe UI", 10.5F)
            };
            InputPanel nameInput = new InputPanel {
                CornerRadius = 8,
                Location = new Point(198, 116),
                Size = new Size(478, 36),
                BackColor = AppPalette.Input,
                BorderColor = AppPalette.ButtonBorder,
                FocusBorderColor = AppPalette.Accent
            };
            nameInput.Controls.Add(nameTextBox);
            card.Controls.Add(nameInput);
            detailsValueLabel = new Label {
                Text = "—\n—\n—",
                AutoSize = true,
                Location = new Point(198, 167),
                Font = new Font("Segoe UI Semibold", 9.7F),
                ForeColor = AppPalette.Text,
                BackColor = AppPalette.Surface
            };
            card.Controls.Add(detailsValueLabel);
            if (profile != null)
                ShowProfile(profile);

            statusLabel = new Label {
                AutoSize = false,
                Size = new Size(614, 42),
                Location = new Point(62, 246),
                ForeColor = AppPalette.Muted,
                BackColor = AppPalette.Surface,
                TextAlign = ContentAlignment.MiddleLeft,
                AutoEllipsis = true,
                Font = new Font("Segoe UI", 9.5F)
            };
            card.Controls.Add(statusLabel);

            statusDot = new StatusDot {
                DotColor = AppPalette.Accent,
                Size = new Size(10, 10),
                Location = new Point(46, 262),
                BackColor = AppPalette.Surface
            };
            card.Controls.Add(statusDot);

            installButton = MakeButton("Установить", 540, 336, 136, true, InstallProfile);
            removeButton = MakeButton("Удалить", 374, 336, 136, false, RemoveProfile);
            openButton = MakeButton("Открыть VPN", 209, 336, 136, false, OpenVpnSettings);
            card.Controls.Add(openButton);
            card.Controls.Add(removeButton);
            card.Controls.Add(installButton);

            Button diagnostics = MakeButton("Журнал", 44, 336, 136, false, OpenLog);
            card.Controls.Add(diagnostics);
            AcceptButton = installButton;
            Shown += FormShown;
        }

        private void FormShown(object sender, EventArgs args)
        {
            RefreshStatus();
            if (profile != null && automaticOperation == "install")
                InstallProfile(this, EventArgs.Empty);
            else if (profile != null && automaticOperation == "remove")
                RunOperation("remove", delegate { return VpnProfileStore.Remove(profile); });
        }

        protected override void OnHandleCreated(EventArgs args)
        {
            base.OnHandleCreated(args);
            DarkTitleBar.Apply(Handle);
        }

        private Button MakeButton(string text, int x, int y, int width,
            bool primary, EventHandler handler)
        {
            bool danger = text == "Удалить";
            bool ghost = text == "Журнал";
            Button button = new ModernButton(primary ? ButtonRole.Primary :
                (danger ? ButtonRole.Danger : (ghost ? ButtonRole.Ghost : ButtonRole.Secondary))) {
                Text = text,
                AutoSize = false,
                Size = new Size(width, 38),
                Location = new Point(x, y),
                Font = new Font("Segoe UI Semibold", 9.3F),
                Cursor = Cursors.Hand
            };
            button.Click += handler;
            return button;
        }

        private void BrowseProfile(object sender, EventArgs args)
        {
            using (OpenFileDialog dialog = new OpenFileDialog {
                Title = "Выберите профиль VPNv2 XML",
                Filter = "Профиль VPNv2 (*.vpnv2.xml)|*.vpnv2.xml|XML-файл (*.xml)|*.xml",
                CheckFileExists = true,
                Multiselect = false,
                RestoreDirectory = true
            })
            {
                if (dialog.ShowDialog(this) != DialogResult.OK)
                    return;
                try
                {
                    ShowProfile(ProfileDocument.Load(dialog.FileName));
                    RefreshStatus();
                }
                catch (Exception exception)
                {
                    ShowFailure("open profile", exception);
                }
            }
        }

        private void ShowProfile(ProfileDocument value)
        {
            profile = value;
            nameTextBox.Text = value.Name;
            detailsValueLabel.Text = value.Server + "\n" + value.DnsServers + "\n" +
                (value.ForceTunnel ? "Весь трафик через VPN" : "Раздельная маршрутизация");
        }

        private void RefreshStatus()
        {
			if (profile == null)
			{
				SetStatus("Выберите XML-профиль, чтобы продолжить.", AppPalette.Muted);
				installButton.Enabled = false;
				removeButton.Enabled = false;
				openButton.Enabled = true;
				nameTextBox.Enabled = false;
				return;
			}
			nameTextBox.Enabled = true;
            // Asked off the window's thread: Windows' VPN commands take a moment.
            ProfileDocument asked = profile;
            SetStatus("Проверка профиля…", AppPalette.Muted);
            System.Threading.ThreadPool.QueueUserWorkItem(delegate {
                bool installed = false;
                Exception failure = null;
                try { installed = VpnProfileStore.Exists(asked); }
                catch (Exception exception) { failure = exception; }
                if (IsDisposed || !IsHandleCreated) return;
                BeginInvoke((MethodInvoker)delegate {
                    if (profile != asked) return;
                    if (failure != null)
                    {
                        SetStatus("Не удалось прочитать состояние: " + ExceptionText.Format(failure), AppPalette.Error);
                        installButton.Text = "Установить";
                        installButton.Enabled = true;
                        removeButton.Enabled = true;
                        return;
                    }
                    SetStatus(installed
                        ? "Профиль установлен. Его можно безопасно обновить."
                        : "Профиль ещё не установлен.", installed ?
                        AppPalette.Success : AppPalette.Accent);
                    installButton.Text = installed ? "Обновить" : "Установить";
                    installButton.Enabled = true;
                    removeButton.Enabled = installed;
                    openButton.Enabled = installed;
                });
            });
        }

        private void InstallProfile(object sender, EventArgs args)
        {
            RunOperation("install", delegate { return VpnProfileStore.Install(profile); });
        }

        private void RemoveProfile(object sender, EventArgs args)
        {
            try
            {
                profile.SetName(nameTextBox.Text.Trim());
            }
            catch (Exception exception)
            {
                ShowFailure("remove", exception);
                nameTextBox.Focus();
                return;
            }
            if (MessageBox.Show("Удалить VPN-профиль «" + profile.Name + "»?",
                    "Nikitid IKEv2 Setup", MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question) != DialogResult.Yes)
                return;

            RunOperation("remove", delegate { return VpnProfileStore.Remove(profile); });
        }

        // Everything is done for the person running this, with no
        // administrator's right asked for, on a thread of its own.
        private void RunOperation(string operation, Func<string> action)
        {
            try
            {
                profile.SetName(nameTextBox.Text.Trim());
            }
            catch (Exception exception)
            {
                ShowFailure(operation, exception);
                nameTextBox.Focus();
                return;
            }

            SetBusy(true);
            SetStatus(operation == "install" ? "Установка профиля…" : "Удаление профиля…", AppPalette.Accent);
            InstallerLog.Write(operation + " started for " + profile.Name);
            System.Threading.ThreadPool.QueueUserWorkItem(delegate {
                string message = null;
                Exception failure = null;
                try { message = action(); }
                catch (Exception exception) { failure = exception; }
                if (IsDisposed || !IsHandleCreated) return;
                BeginInvoke((MethodInvoker)delegate {
                    SetBusy(false);
                    if (failure != null)
                    {
                        ShowFailure(operation, failure);
                        return;
                    }
                    InstallerLog.Write(operation + " completed for " + profile.Name);
                    installButton.Text = operation == "install" ? "Обновить" : "Установить";
                    removeButton.Enabled = operation == "install";
                    openButton.Enabled = true;
                    SetStatus(message, AppPalette.Success);
                });
            });
        }

        private void SetBusy(bool busy)
        {
            installButton.Enabled = !busy && profile != null;
            nameTextBox.Enabled = !busy && profile != null;
            browseButton.Enabled = !busy;
            if (busy)
                removeButton.Enabled = false;
            Cursor = busy ? Cursors.WaitCursor : Cursors.Default;
        }

        private void SetStatus(string text, Color color)
        {
            statusLabel.ForeColor = color;
            statusLabel.Text = text;
            statusDot.DotColor = color;
        }

        private void ShowFailure(string operation, Exception exception)
        {
            InstallerLog.Write(operation + " failed", exception);
            string text = ExceptionText.Format(exception);
            SetStatus("Операция не выполнена: " + text, AppPalette.Error);
            MessageBox.Show(text + "\n\nПодробности записаны в:\n" + InstallerLog.Path,
                "Не удалось изменить VPN-профиль", MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }

        private void OpenVpnSettings(object sender, EventArgs args)
        {
            Process.Start(new ProcessStartInfo {
                FileName = "ms-settings:network-vpn",
                UseShellExecute = true
            });
        }

        private void OpenLog(object sender, EventArgs args)
        {
            InstallerLog.EnsureExists();
            Process.Start(new ProcessStartInfo {
                FileName = InstallerLog.Path,
                UseShellExecute = true
            });
        }
    }

    internal enum ButtonRole
    {
        Primary,
        Secondary,
        Danger,
        Ghost
    }

    internal sealed class ModernButton : Button
    {
        private readonly ButtonRole role;
        private bool hovered;
        private bool pressed;

        internal ModernButton(ButtonRole role)
        {
            this.role = role;
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseVisualStyleBackColor = false;
            TabStop = true;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        protected override void OnMouseEnter(EventArgs args)
        {
            hovered = true;
            Invalidate();
            base.OnMouseEnter(args);
        }

        protected override void OnMouseLeave(EventArgs args)
        {
            hovered = false;
            pressed = false;
            Invalidate();
            base.OnMouseLeave(args);
        }

        protected override void OnMouseDown(MouseEventArgs args)
        {
            pressed = true;
            Invalidate();
            base.OnMouseDown(args);
        }

        protected override void OnMouseUp(MouseEventArgs args)
        {
            pressed = false;
            Invalidate();
            base.OnMouseUp(args);
        }

        protected override void OnEnabledChanged(EventArgs args)
        {
            Invalidate();
            base.OnEnabledChanged(args);
        }

        protected override void OnPaint(PaintEventArgs args)
        {
            args.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            args.Graphics.Clear(Parent == null ? AppPalette.Surface : Parent.BackColor);
            Rectangle bounds = new Rectangle(1, 1, Width - 3, Height - 3);
            Color fill = AppPalette.Button;
            Color border = AppPalette.ButtonBorder;
            Color text = AppPalette.Text;

            if (role == ButtonRole.Primary)
            {
                fill = pressed ? AppPalette.AccentPressed :
                    (hovered ? AppPalette.AccentHover : AppPalette.Accent);
                border = fill;
                text = Color.White;
            }
            else if (role == ButtonRole.Danger)
            {
                fill = hovered ? AppPalette.DangerHover : AppPalette.DangerButton;
                border = AppPalette.DangerBorder;
                text = AppPalette.Error;
            }
            else
            {
                fill = pressed ? AppPalette.Input :
                    (hovered ? AppPalette.ButtonHover : AppPalette.Button);
                text = role == ButtonRole.Ghost ? AppPalette.Muted : AppPalette.Text;
            }

            if (!Enabled)
            {
                fill = AppPalette.Input;
                border = AppPalette.Border;
                text = AppPalette.Muted;
            }

            using (GraphicsPath path = DrawingTools.RoundRect(bounds, 8))
            using (SolidBrush brush = new SolidBrush(fill))
            using (Pen pen = new Pen(border))
            {
                args.Graphics.FillPath(brush, path);
                args.Graphics.DrawPath(pen, path);
            }
            TextRenderer.DrawText(args.Graphics, Text, Font, bounds, text,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }
    }

    internal static class AppPalette
    {
        internal static readonly Color Background = Color.FromArgb(7, 10, 17);
        internal static readonly Color Surface = Color.FromArgb(17, 23, 35);
        internal static readonly Color Input = Color.FromArgb(10, 15, 25);
        internal static readonly Color Border = Color.FromArgb(45, 54, 73);
        internal static readonly Color Button = Color.FromArgb(29, 37, 52);
        internal static readonly Color ButtonHover = Color.FromArgb(42, 51, 70);
        internal static readonly Color ButtonBorder = Color.FromArgb(57, 67, 88);
        internal static readonly Color Text = Color.FromArgb(240, 242, 249);
        internal static readonly Color Muted = Color.FromArgb(151, 160, 181);
        internal static readonly Color Accent = Color.FromArgb(126, 113, 246);
        internal static readonly Color AccentHover = Color.FromArgb(145, 133, 255);
        internal static readonly Color AccentPressed = Color.FromArgb(105, 92, 221);
        internal static readonly Color Success = Color.FromArgb(89, 207, 150);
        internal static readonly Color Error = Color.FromArgb(242, 108, 126);
        internal static readonly Color DangerButton = Color.FromArgb(38, 27, 37);
        internal static readonly Color DangerHover = Color.FromArgb(61, 34, 44);
        internal static readonly Color DangerBorder = Color.FromArgb(91, 45, 58);
    }

    internal sealed class BackdropPanel : Panel
    {
        internal BackdropPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnPaintBackground(PaintEventArgs args)
        {
            args.Graphics.Clear(AppPalette.Background);
            args.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            DrawGlow(args.Graphics, new Rectangle(-150, -170, 520, 400),
                Color.FromArgb(72, 89, 76, 226), 15);
            DrawGlow(args.Graphics, new Rectangle(475, 300, 350, 270),
                Color.FromArgb(42, 34, 143, 164), 12);
        }

        private static void DrawGlow(Graphics graphics, Rectangle area,
            Color color, int layers)
        {
            for (int layer = layers; layer > 0; layer--)
            {
                float ratio = (float)layer / layers;
                int insetX = (int)((1F - ratio) * area.Width * 0.30F);
                int insetY = (int)((1F - ratio) * area.Height * 0.30F);
                Rectangle ellipse = Rectangle.Inflate(area, -insetX, -insetY);
                int alpha = Math.Max(2, color.A / layers);
                using (SolidBrush brush = new SolidBrush(Color.FromArgb(alpha,
                    color.R, color.G, color.B)))
                    graphics.FillEllipse(brush, ellipse);
            }
        }
    }

    internal sealed class RoundedPanel : Panel
    {
        internal int CornerRadius { get; set; }
        internal Color BorderColor { get; set; }

        internal RoundedPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnResize(EventArgs args)
        {
            base.OnResize(args);
            Region previous = Region;
            Region = DrawingTools.RoundedRegion(ClientRectangle, CornerRadius);
            if (previous != null)
                previous.Dispose();
        }

        protected override void OnPaint(PaintEventArgs args)
        {
            base.OnPaint(args);
            args.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = DrawingTools.RoundRect(bounds, CornerRadius))
            using (Pen pen = new Pen(BorderColor))
                args.Graphics.DrawPath(pen, path);
        }
    }

    internal sealed class InputPanel : Panel
    {
        internal int CornerRadius { get; set; }
        internal Color BorderColor { get; set; }
        internal Color FocusBorderColor { get; set; }
        private bool focused;

        internal InputPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnControlAdded(ControlEventArgs args)
        {
            base.OnControlAdded(args);
            args.Control.Enter += delegate { focused = true; Invalidate(); };
            args.Control.Leave += delegate { focused = false; Invalidate(); };
        }

        protected override void OnResize(EventArgs args)
        {
            base.OnResize(args);
            Region previous = Region;
            Region = DrawingTools.RoundedRegion(ClientRectangle, CornerRadius);
            if (previous != null)
                previous.Dispose();
        }

        protected override void OnPaint(PaintEventArgs args)
        {
            base.OnPaint(args);
            args.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = DrawingTools.RoundRect(bounds, CornerRadius))
            using (Pen pen = new Pen(focused ? FocusBorderColor : BorderColor))
                args.Graphics.DrawPath(pen, path);
        }
    }

    internal sealed class StatusDot : Control
    {
        private Color dotColor;
        internal Color DotColor {
            get { return dotColor; }
            set { dotColor = value; Invalidate(); }
        }

        protected override void OnPaint(PaintEventArgs args)
        {
            args.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush brush = new SolidBrush(dotColor))
                args.Graphics.FillEllipse(brush, 1, 1, Width - 2, Height - 2);
        }
    }

    internal static class DrawingTools
    {
        internal static Region RoundedRegion(Rectangle bounds, int radius)
        {
            if (bounds.Width < 2 || bounds.Height < 2)
                return new Region(bounds);
            using (GraphicsPath path = RoundRect(new Rectangle(0, 0,
                bounds.Width, bounds.Height), radius))
                return new Region(path);
        }

        internal static GraphicsPath RoundRect(Rectangle bounds, int radius)
        {
            int diameter = Math.Max(2, radius * 2);
            GraphicsPath path = new GraphicsPath();
            path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
            path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
            path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter,
                diameter, diameter, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    internal static class DarkTitleBar
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr window, int attribute,
            ref int value, int size);

        internal static void Apply(IntPtr window)
        {
            try
            {
                int enabled = 1;
                if (DwmSetWindowAttribute(window, 20, ref enabled, sizeof(int)) != 0)
                    DwmSetWindowAttribute(window, 19, ref enabled, sizeof(int));
            }
            catch (DllNotFoundException) {}
            catch (EntryPointNotFoundException) {}
        }
    }

    internal sealed class AppInvocation
    {
        internal string ProfilePath { get; private set; }
        internal string Operation { get; private set; }
        internal string FriendlyName { get; private set; }

        internal static AppInvocation Parse(string[] args, string directory)
        {
            string operation = null;
            string friendlyName = null;
            List<string> paths = new List<string>();
            for (int index = 0; index < args.Length; index++)
            {
                string argument = args[index];
                if (argument == "--install" || argument == "--remove")
                    operation = argument.Substring(2);
                else if (argument == "--name")
                {
                    if (++index >= args.Length)
                        throw new ArgumentException("После --name отсутствует имя подключения.");
                    friendlyName = args[index];
                }
                else
                    paths.Add(argument);
            }
            string profilePath = ProfileDocument.Find(paths.ToArray(), directory);
            if (!String.IsNullOrEmpty(operation) && String.IsNullOrEmpty(profilePath))
                throw new ArgumentException("Для автоматической операции нужен XML-профиль.");
            if (!String.IsNullOrEmpty(friendlyName) && String.IsNullOrEmpty(profilePath))
                throw new ArgumentException("Для изменения имени нужен XML-профиль.");
            return new AppInvocation {
                ProfilePath = profilePath,
                Operation = operation,
                FriendlyName = friendlyName
            };
        }
    }

    internal sealed class ProfileDocument
    {
        private ProfileDocument() {}

        internal string Path { get; private set; }
        internal string Name { get; private set; }
        internal string Server { get; private set; }
        internal string DnsServers { get; private set; }
        internal bool ForceTunnel { get; private set; }
        internal string Xml { get; private set; }

        internal void SetName(string value)
        {
            ValidateName(value);
            XmlDocument document = new XmlDocument { PreserveWhitespace = true };
            document.XmlResolver = null;
            document.LoadXml(Xml);
            XmlNode nameNode = document.SelectSingleNode("/VPNProfile/ProfileName");
            if (nameNode == null)
                throw new InvalidDataException("В профиле отсутствует имя профиля.");
            nameNode.InnerText = value;
            Name = value;
            Xml = document.OuterXml;
        }

        internal static string Find(string[] args, string directory)
        {
            if (args.Length > 0)
            {
                if (File.Exists(args[0]))
                    return System.IO.Path.GetFullPath(args[0]);
                throw new FileNotFoundException("Указанный XML-профиль не найден.", args[0]);
            }

            string[] files = Directory.GetFiles(directory, "*.vpnv2.xml");
            if (files.Length == 1)
                return files[0];
            return null;
        }

        internal static ProfileDocument Load(string path)
        {
            XmlDocument document = new XmlDocument { PreserveWhitespace = true };
            document.XmlResolver = null;
            document.Load(path);
            if (document.DocumentElement == null || document.DocumentElement.Name != "VPNProfile")
                throw new InvalidDataException("Файл не является VPNv2-профилем Windows.");

            string name = Required(document, "/VPNProfile/ProfileName", "имя профиля");
            string server = Required(document, "/VPNProfile/NativeProfile/Servers", "VPN-сервер");
            string dns = Required(document,
                "/VPNProfile/DomainNameInformation/DnsServers", "DNS VPN");
            string domain = Required(document,
                "/VPNProfile/DomainNameInformation/DomainName", "DNS-пространство");
            if (domain != ".")
                throw new InvalidDataException("DNS-пространство профиля должно быть точкой (.).");
            ValidateName(name);
            ValidateServer(server);
            ValidateDns(dns);

            string routing = Required(document,
                "/VPNProfile/NativeProfile/RoutingPolicyType", "режим маршрутизации");
            return new ProfileDocument {
                Path = System.IO.Path.GetFullPath(path),
                Name = name,
                Server = server,
                DnsServers = dns,
                ForceTunnel = string.Equals(routing, "ForceTunnel", StringComparison.OrdinalIgnoreCase),
                Xml = document.OuterXml
            };
        }

        private static string Required(XmlDocument document, string xpath, string label)
        {
            XmlNode node = document.SelectSingleNode(xpath);
            string value = node == null ? "" : node.InnerText.Trim();
            if (value.Length == 0)
                throw new InvalidDataException("В профиле отсутствует " + label + ".");
            return value;
        }

        private static void ValidateName(string value)
        {
            if (String.IsNullOrWhiteSpace(value) || value.Length > 128 ||
                value.Any(Char.IsControl) ||
                value.IndexOfAny(new[] {'\\', '/', ':', '*', '?', '"', '<', '>', '|', ';'}) >= 0)
                throw new InvalidDataException("Имя VPN-профиля содержит недопустимые символы.");
        }

        private static void ValidateServer(string value)
        {
            if (value.Length > 253 || value.IndexOfAny(new[] {'/', '\\', '@'}) >= 0)
                throw new InvalidDataException("Некорректное имя VPN-сервера.");
        }

        private static void ValidateDns(string value)
        {
            // Use the .NET Framework overload explicitly. Mono also exposes a
            // newer Split(Char, StringSplitOptions) overload and otherwise
            // binds this source to a method that isn't present on Windows.
            foreach (string item in value.Split(
                new char[] { ',' }, StringSplitOptions.None))
            {
                IPAddress address;
                if (!IPAddress.TryParse(item.Trim(), out address))
                    throw new InvalidDataException("Некорректный адрес DNS в VPN-профиле.");
            }
        }
    }

    // The connection, made by VpnProfile.ps1 - carried inside this program -
    // with Windows' own VPN commands for the user who runs it. It used to go
    // through the MDM bridge, which Windows 10 refuses outside the system's
    // own account; these commands need no administrator on Windows 10 or 11.
    internal static class VpnProfileStore
    {
        internal static bool Exists(ProfileDocument document)
        {
            return Run("status", document).Contains("\"installed\":true");
        }

        internal static string Install(ProfileDocument document) { return Message(Run("install", document)); }

        internal static string Remove(ProfileDocument document) { return Message(Run("remove", document)); }

        // The script's one line of JSON: {"ok":..., "message":"..."}.
        internal static string Message(string answer)
        {
            Match message = Regex.Match(answer, "\"message\":\"((?:[^\"\\\\]|\\\\.)*)\"");
            string text = message.Success ? Regex.Unescape(message.Groups[1].Value) : answer;
            if (!answer.Contains("\"ok\":true")) throw new InvalidOperationException(text);
            return text;
        }

        private static string Run(string operation, ProfileDocument document)
        {
            string folder = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "Nikitid-IKEv2-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            try
            {
                string script = System.IO.Path.Combine(folder, "VpnProfile.ps1");
                string xml = System.IO.Path.Combine(folder, "profile.vpnv2.xml");
                using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("VpnProfile.ps1"))
                using (FileStream target = File.Create(script))
                {
                    if (source == null) throw new InvalidOperationException("Программа повреждена: нет сценария профиля.");
                    source.CopyTo(target);
                }
                File.WriteAllText(xml, document.Xml, new UTF8Encoding(false));
                string shell = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");
                var start = new ProcessStartInfo(shell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script +
                    "\" -Operation " + operation + " -Profile \"" + xml + "\" -Name \"" + document.Name + "\"") {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8 };
                using (Process process = Process.Start(start))
                {
                    var error = process.StandardError.ReadToEndAsync();
                    string output = process.StandardOutput.ReadToEnd();
                    if (!process.WaitForExit(120000))
                    {
                        try { process.Kill(); } catch {}
                        throw new TimeoutException("Windows не ответила за две минуты.");
                    }
                    string line = output.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.StartsWith("{"));
                    if (line == null)
                        throw new InvalidOperationException("Windows не выполнила команду VPN. " + error.Result.Trim());
                    return line;
                }
            }
            finally
            {
                try { Directory.Delete(folder, true); } catch {}
            }
        }
    }

    internal static class Elevation
    {
        internal static bool IsAdministrator()
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(identity).IsInRole(
                WindowsBuiltInRole.Administrator);
        }
    }

    internal static class ExceptionText
    {
        internal static string Format(Exception exception)
        {
            StringBuilder text = new StringBuilder();
            for (Exception current = exception; current != null; current = current.InnerException)
            {
                if (text.Length != 0)
                    text.Append(" — ");
                text.Append(current.Message.Trim());
                text.Append(" [0x");
                text.Append(current.HResult.ToString("X8"));
                text.Append(']');
                ManagementException management = current as ManagementException;
                if (management != null)
                    text.Append(" WMI: ").Append(management.ErrorCode);
            }
            return text.ToString();
        }
    }

    internal static class InstallerLog
    {
        internal static readonly string Path = System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Nikitid", "IKEv2 Manager", "installer.log");

        internal static void EnsureExists()
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path));
            if (!File.Exists(Path))
                File.WriteAllText(Path, "Nikitid IKEv2 Setup log\r\n", Encoding.UTF8);
        }

        internal static void Write(string message)
        {
            EnsureExists();
            File.AppendAllText(Path,
                DateTimeOffset.Now.ToString("u") + " " + message + "\r\n", Encoding.UTF8);
        }

        internal static void Write(string message, Exception exception)
        {
            Write(message + ": " + ExceptionText.Format(exception) + "\r\n" + exception);
        }
    }
}
