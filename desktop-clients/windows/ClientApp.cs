using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Threading.Tasks;
using System.Security.Principal;

namespace IkeV2Manager.Client
{
    internal sealed class ClientWindow : Form
    {
        // How a state reads at a glance: one colour and one sign, the same on macOS.
        private enum Tone { Open, Working, Attention, Off }
        private static Color Shade(Tone tone)
        {
            return tone == Tone.Open ? Color.FromArgb(33, 140, 69) : tone == Tone.Working ? Color.FromArgb(217, 140, 13) :
                tone == Tone.Attention ? Color.FromArgb(199, 51, 46) : Color.FromArgb(128, 128, 133);
        }
        private sealed class Surface : Panel { internal Surface() { DoubleBuffered = true; ResizeRedraw = true; } }
        private readonly Surface surface = new Surface { Dock = DockStyle.Fill };
        // What the surface draws; set by RefreshStatus.
        private string heading = "", description = "", servicesLine = "", servicesNote = "", availableLine = "", notice = "", checkedLine = "";
        private Tone tone = Tone.Off;
        // "system", "light" or "dark": the look this user chose for the window.
        private string theme = "system";
        private bool dark;
        private Color Back { get { return dark ? Color.FromArgb(30, 30, 32) : Color.FromArgb(245, 245, 247); } }
        private Color Sheet { get { return dark ? Color.FromArgb(44, 44, 46) : Color.White; } }
        private Color Ink { get { return dark ? Color.FromArgb(240, 240, 242) : Color.FromArgb(28, 28, 30); } }
        private Color Soft { get { return dark ? Color.FromArgb(160, 160, 166) : Color.FromArgb(110, 110, 115); } }
        private Color Line { get { return dark ? Color.FromArgb(70, 70, 74) : Color.FromArgb(217, 217, 222); } }
        private readonly List<Button> plain = new List<Button>();
        private const string Preferences = @"Software\Waypoint";
        [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

        // The system's choice unless the user made one; applied to the title
        // bar, the surface and the buttons.
        private void ApplyTheme()
        {
            bool systemDark = false;
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                    systemDark = key != null && (key.GetValue("AppsUseLightTheme") as int?) == 0;
            }
            catch (System.Security.SecurityException) { }
            catch (UnauthorizedAccessException) { }
            dark = theme == "dark" || (theme == "system" && systemDark);
            BackColor = Back;
            foreach (var button in plain) { button.BackColor = Sheet; button.ForeColor = Ink; button.FlatAppearance.BorderColor = Line; }
            if (IsHandleCreated) { int on = dark ? 1 : 0; DwmSetWindowAttribute(Handle, 20, ref on, 4); }
            surface.Invalidate();
        }

        private void ChooseTheme(Control anchor)
        {
            var menu = new ContextMenuStrip();
            foreach (var item in new[] { new[] { "system", "Системная" }, new[] { "light", "Светлая" }, new[] { "dark", "Тёмная" } })
            {
                string value = item[0];
                var entry = new ToolStripMenuItem(item[1]) { Checked = theme == value };
                entry.Click += (sender, args) =>
                {
                    theme = value;
                    try { using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Preferences)) key.SetValue("Theme", value); }
                    catch (UnauthorizedAccessException) { }
                    ApplyTheme();
                };
                menu.Items.Add(entry);
            }
            menu.Show(anchor, new Point(0, anchor.Height));
        }
        private readonly string[] checkLabels = { "Блокировка вне туннеля", "Туннель", "Подтверждение сервера" };
        private readonly string[] checkValues = { "", "", "" };
        private readonly Tone[] checkTones = { Tone.Off, Tone.Off, Tone.Off };
        private readonly Button register = new Button { Text = "Регистрация…", AutoSize = true };
        private readonly Button resume = new Button { Text = "Продолжить", AutoSize = true };
        private readonly Button connect = new Button { Text = "Включить", AutoSize = true };
        private readonly Button disconnect = new Button { Text = "Отключить", AutoSize = true };
        private readonly Button update = new Button { Text = "Обновить", AutoSize = true, Visible = false, TabStop = false };
        // The one place downloads come from. The router supplies a version
        // number and nothing else.
        private const string Downloads = "https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v";
        // Set by a registration started in this window: the first thing a newly
        // registered device wants is its connection.
        private bool connectAfterRegistration;
        private readonly Timer timer = new Timer { Interval = 3000 };
        private ClientView current = new ClientView("status_unavailable");
        private bool commandBusy;

        internal ClientWindow()
        {
            Text = "Waypoint";
            ClientSize = new Size(560, 470);
            AutoScaleMode = AutoScaleMode.Dpi;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            Font = new Font("Segoe UI", 10);
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(Preferences))
                {
                    string chosen = key == null ? null : key.GetValue("Theme") as string;
                    if (chosen == "light" || chosen == "dark") theme = chosen;
                }
            }
            catch (System.Security.SecurityException) { }
            catch (UnauthorizedAccessException) { }
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch (ArgumentException) { }
            catch (IOException) { }
            StartPosition = FormStartPosition.CenterScreen;
            var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Bottom, Padding = new Padding(20, 8, 20, 16), WrapContents = true };
            var refresh = new Button { Text = "Проверить", AutoSize = true };
            var report = new Button { Text = "Отчёт…", AutoSize = true };
            var look = new Button { Text = "Тема", AutoSize = true };
            look.Click += (sender, args) => ChooseTheme(look);
            refresh.Click += (sender, args) => RefreshStatus();
            report.Click += (sender, args) => PreviewReport();
            register.Click += (sender, args) => BeginRegistration();
            resume.Click += (sender, args) => SubmitCommand("continue");
            connect.Click += (sender, args) => SubmitCommand("connect");
            disconnect.Click += (sender, args) => SubmitCommand("disconnect");
            update.Click += (sender, args) =>
            {
                if (!ClientView.Newer(current.Release, System.Reflection.Assembly.GetExecutingAssembly().GetName().Version)) return;
                try { System.Diagnostics.Process.Start(Downloads + current.Release + "/WaypointSetup.exe"); }
                catch (System.ComponentModel.Win32Exception) { MessageBox.Show(this, "Не удалось открыть браузер.", "Обновление"); }
            };
            // The next thing to do stands first and stands out.
            foreach (var primary in new[] { register, connect })
            {
                primary.FlatStyle = FlatStyle.Flat; primary.FlatAppearance.BorderSize = 0;
                primary.BackColor = Color.FromArgb(0, 103, 192); primary.ForeColor = Color.White;
            }
            foreach (var button in new[] { register, resume, connect, disconnect, refresh, report, look, update })
            {
                button.Margin = new Padding(4, 4, 4, 4); button.Padding = new Padding(4, 2, 4, 2);
                if (button.FlatStyle != FlatStyle.Flat)
                {
                    button.FlatStyle = FlatStyle.Flat; plain.Add(button);
                }
                buttons.Controls.Add(button);
            }
            surface.Paint += (sender, args) => Draw(args.Graphics, true);
            Controls.Add(surface);
            Controls.Add(buttons);
            timer.Tick += (sender, args) => RefreshStatus();
            Microsoft.Win32.SystemEvents.UserPreferenceChanged += SystemLookChanged;
            Shown += (sender, args) => { ApplyTheme(); RefreshStatus(); timer.Start(); };
            FormClosed += (sender, args) => { timer.Dispose(); Microsoft.Win32.SystemEvents.UserPreferenceChanged -= SystemLookChanged; };
        }

        private void SystemLookChanged(object sender, Microsoft.Win32.UserPreferenceChangedEventArgs change)
        {
            if (theme == "system" && !IsDisposed) BeginInvoke((Action)ApplyTheme);
        }

        // Draws the status, the checks and the services, and returns the height
        // they take, so the window is exactly as tall as what it says.
        private int Draw(Graphics g, bool paint)
        {
            float k = g.DpiX / 96f;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            float left = 24 * k, width = surface.ClientSize.Width - 48 * k, y = 22 * k;
            Color ink = Ink, soft = Soft, line = Line;
            using (var titleFont = new Font("Segoe UI Semibold", 15))
            using (var small = new Font("Segoe UI", 8))
            using (var bold = new Font("Segoe UI Semibold", 10))
            using (var sign = new Font("Segoe UI Symbol", 15, FontStyle.Bold))
            using (var inkBrush = new SolidBrush(ink))
            using (var softBrush = new SolidBrush(soft))
            using (var linePen = new Pen(line))
            using (var wrap = new StringFormat())
            using (var right = new StringFormat { Alignment = StringAlignment.Far, LineAlignment = StringAlignment.Center })
            using (var middle = new StringFormat { LineAlignment = StringAlignment.Center })
            using (var centre = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            {
                // Status: sign, what it is, what it means.
                float disc = 44 * k, textLeft = left + disc + 14 * k, textWidth = width - disc - 14 * k;
                if (paint)
                {
                    using (var halo = new SolidBrush(Color.FromArgb(38, Shade(tone)))) g.FillEllipse(halo, left, y, disc, disc);
                    using (var mark = new SolidBrush(Shade(tone)))
                        g.DrawString(tone == Tone.Open ? "\u2713" : tone == Tone.Working ? "\u2026" : tone == Tone.Attention ? "!" : "\u23FB",
                            sign, mark, new RectangleF(left, y, disc, disc), centre);
                    g.DrawString(heading, titleFont, inkBrush, textLeft - 3 * k, y - 4 * k);
                }
                float headingHeight = g.MeasureString(heading, titleFont).Height - 4 * k;
                SizeF detail = g.MeasureString(description, Font, (int)textWidth, wrap);
                if (paint) g.DrawString(description, Font, softBrush, new RectangleF(textLeft, y + headingHeight, textWidth, detail.Height + 2), wrap);
                y += Math.Max(disc, headingHeight + detail.Height) + 16 * k;

                // Checks.
                float pad = 14 * k, row = 26 * k, caption = 20 * k;
                float cardHeight = pad + caption + row * 3 + pad - 6 * k;
                if (paint)
                {
                    Card(g, left, y, width, cardHeight, linePen, 10 * k);
                    g.DrawString("ПРОВЕРКИ", small, softBrush, left + pad, y + pad - 2 * k);
                    for (int i = 0; i < 3; i++)
                    {
                        float top = y + pad + caption + row * i;
                        using (var dot = new SolidBrush(Shade(checkTones[i]))) g.FillEllipse(dot, left + pad, top + row / 2 - 4 * k, 8 * k, 8 * k);
                        g.DrawString(checkLabels[i], Font, inkBrush, new RectangleF(left + pad + 16 * k, top, width / 2, row), middle);
                        g.DrawString(checkValues[i], Font, softBrush, new RectangleF(left + width / 2, top, width / 2 - pad, row), right);
                    }
                }
                y += cardHeight + 12 * k;

                // Services.
                float inner = width - pad * 2;
                SizeF names = g.MeasureString(servicesLine, bold, (int)inner, wrap);
                SizeF note = servicesNote.Length == 0 ? SizeF.Empty : g.MeasureString(servicesNote, small, (int)inner, wrap);
                SizeF offered = availableLine.Length == 0 ? SizeF.Empty : g.MeasureString(availableLine, small, (int)inner, wrap);
                cardHeight = pad + caption + names.Height + note.Height + offered.Height + pad;
                if (paint)
                {
                    Card(g, left, y, width, cardHeight, linePen, 10 * k);
                    g.DrawString("СЕРВИСЫ", small, softBrush, left + pad, y + pad - 2 * k);
                    float top = y + pad + caption;
                    g.DrawString(servicesLine, bold, servicesNote.Length == 0 && current.Services.Length == 0 ? softBrush : inkBrush,
                        new RectangleF(left + pad, top, inner, names.Height + 2), wrap);
                    top += names.Height;
                    if (servicesNote.Length != 0) { g.DrawString(servicesNote, small, softBrush, new RectangleF(left + pad, top, inner, note.Height + 2), wrap); top += note.Height; }
                    if (availableLine.Length != 0) g.DrawString(availableLine, small, softBrush, new RectangleF(left + pad, top, inner, offered.Height + 2), wrap);
                }
                y += cardHeight + 12 * k;

                // What needs the user's attention: an update, a proxy.
                if (notice.Length != 0)
                {
                    SizeF said = g.MeasureString(notice, Font, (int)(width - 24 * k), wrap);
                    if (paint)
                    {
                        using (var amber = new SolidBrush(Color.FromArgb(30, Shade(Tone.Working))))
                        using (var shape = Rounded(left, y, width, said.Height + 20 * k, 10 * k)) g.FillPath(amber, shape);
                        g.DrawString(notice, Font, inkBrush, new RectangleF(left + 12 * k, y + 10 * k, width - 24 * k, said.Height + 2), wrap);
                    }
                    y += said.Height + 20 * k + 12 * k;
                }
                if (paint) g.DrawString(checkedLine, small, softBrush, left, y);
                y += g.MeasureString(checkedLine, small).Height + 4 * k;
            }
            return (int)Math.Ceiling(y);
        }

        private static System.Drawing.Drawing2D.GraphicsPath Rounded(float x, float y, float width, float height, float radius)
        {
            var path = new System.Drawing.Drawing2D.GraphicsPath();
            float d = radius * 2;
            path.AddArc(x, y, d, d, 180, 90); path.AddArc(x + width - d, y, d, d, 270, 90);
            path.AddArc(x + width - d, y + height - d, d, d, 0, 90); path.AddArc(x, y + height - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        private void Card(Graphics g, float x, float y, float width, float height, Pen border, float radius)
        {
            using (var shape = Rounded(x, y, width, height, radius)) using (var fill = new SolidBrush(Sheet)) { g.FillPath(fill, shape); g.DrawPath(border, shape); }
        }

        // The window is as tall as its content and its buttons.
        private void FitWindow()
        {
            int content;
            using (var g = surface.CreateGraphics()) content = Draw(g, false);
            int wanted = content + (ClientSize.Height - surface.ClientSize.Height);
            if (Math.Abs(ClientSize.Height - wanted) > 1) ClientSize = new Size(ClientSize.Width, wanted);
            surface.Invalidate();
        }

        private void BeginRegistration()
        {
            if (commandBusy) return;
            if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
            {
                MessageBox.Show(this, "Запустите программу от имени администратора.", "Регистрация");
                return;
            }
            using (var dialog = new Form { Text = "Регистрация", ClientSize = new Size(560, 170),
                StartPosition = FormStartPosition.CenterParent, Font = Font, MinimizeBox = false, MaximizeBox = false })
            {
                var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1 };
                var input = new TextBox { Dock = DockStyle.Fill, UseSystemPasswordChar = true };
                var submit = new Button { Text = "Зарегистрировать", AutoSize = true, DialogResult = DialogResult.OK };
                layout.Controls.Add(new Label { Text = "Ссылка приглашения", AutoSize = true });
                layout.Controls.Add(input); layout.Controls.Add(submit); dialog.Controls.Add(layout); dialog.AcceptButton = submit;
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                try
                {
                    string endpoint, token;
                    ClientCommands.ParseInvitation(input.Text, out endpoint, out token);
                    input.Clear();
                    connectAfterRegistration = true;
                    SubmitCommand("begin", endpoint, token);
                }
                catch (ArgumentException) { MessageBox.Show(this, "Приглашение имеет неверный формат.", "Регистрация"); }
                catch (FormatException) { MessageBox.Show(this, "Приглашение имеет неверный формат.", "Регистрация"); }
            }
        }

        private async void SubmitCommand(string operation, string endpoint = null, string invitation = null)
        {
            if (commandBusy) return;
            commandBusy = true;
            try
            {
                string result = await Task.Factory.StartNew(() => ClientCommands.Send(operation, endpoint, invitation));
                if (IsDisposed) return;
                if (result == "accepted" && operation == "begin")
                    await Task.Factory.StartNew(() => ClientCommands.Send("continue"));
                else if (result != "accepted" && result != "busy")
                    MessageBox.Show(this, result == "administrator_required" ? "Требуются права администратора." : "Действие отклонено.", "Регистрация");
            }
            catch { if (!IsDisposed) MessageBox.Show(this, "Служба не отвечает.", "Регистрация"); }
            finally { commandBusy = false; if (!IsDisposed) RefreshStatus(); }
        }

        private void RefreshStatus() { Present(ClientStatusReader.Read()); }

        // Everything the window says follows from one reading of the service.
        internal void Present(ClientView view)
        {
            current = view;
            tone = current.State == "protected" ? Tone.Open :
                current.State == "connecting" || current.State == "tunnel_connected" || current.State == "registration_pending" ? Tone.Working :
                current.State == "blocked" || current.State == "enrollment_required" ? Tone.Off : Tone.Attention;
            string code = current.ConnectionError;
            switch (current.State)
            {
                case "blocked":
                    heading = current.Wanted ? "Доступ закрыт" : "Доступ выключен";
                    description = current.Warnings != null && current.Warnings.Contains("open") ? "Сервисы идут напрямую, без туннеля." :
                        current.Wanted ? "Нет подключения. Сервисы заблокированы." : "Сервисы заблокированы.";
                    break;
                case "enrollment_required":
                    heading = "Устройство не зарегистрировано";
                    description = "Нужна ссылка приглашения от администратора.";
                    break;
                case "registration_pending":
                    heading = "Регистрация";
                    description = code == "enrollment_connection_failed" ? "Нет связи с сервером." :
                        code == "enrollment_access_rejected" ? "Приглашение недействительно. Запросите новое." :
                        code != "none" ? "Неожиданный ответ сервера (" + code + ")." : "Ожидается ответ сервера.";
                    break;
                case "registration_error":
                    heading = "Ошибка регистрации";
                    description = "Настройки не получены. Повторите регистрацию.";
                    break;
                case "connecting":
                    heading = "Подключение";
                    description = "Устанавливается туннель.";
                    break;
                case "protected":
                    heading = "Доступ открыт";
                    description = "Сервисы идут через туннель.";
                    break;
                case "tunnel_connected":
                    heading = "Проверка доступа";
                    description = code == "path_connection_failed" ? "Нет связи с сервером." :
                        code == "path_different_policy" ? "Настройки обновляются." :
                        code == "device_access_revoked" ? "Доступ отозван администратором." :
                        code == "path_response_invalid" ? "Ответ сервера не принят." : "Сервер ещё не подтвердил доступ.";
                    break;
                case "connection_error":
                    heading = "Нет подключения";
                    description = "Туннель не установлен. Попытка повторится.";
                    break;
                case "access_closed":
                    heading = "Доступ не разрешён";
                    description = "Доступ для этого устройства выключен администратором.";
                    break;
                case "error":
                    heading = "Ошибка службы";
                    description = "Состояние защиты не подтверждено. Подробности в отчёте.";
                    break;
                case "service_missing":
                    heading = "Служба не установлена";
                    description = "Переустановите программу.";
                    break;
                case "service_stopped":
                    heading = "Служба остановлена";
                    description = "Состояние защиты не подтверждено.";
                    break;
                default:
                    heading = "Состояние неизвестно";
                    description = "Подробности в отчёте.";
                    break;
            }
            bool fresh = current.State == "enrollment_required";
            bool relaxed = current.Warnings != null && current.Warnings.Contains("open");
            checkValues[0] = relaxed ? "выключена администратором" : current.GuardInstalled ? "включена" : fresh ? "после регистрации" : "не подтверждена";
            checkTones[0] = relaxed ? Tone.Off : current.GuardInstalled ? Tone.Open : fresh ? Tone.Off : Tone.Attention;
            checkValues[1] = current.Routed ? "подключён" : current.State == "connecting" ? "подключается" : "нет";
            checkTones[1] = current.Routed ? Tone.Open : current.State == "connecting" ? Tone.Working : Tone.Off;
            checkValues[2] = current.Protected ? "получено" : "нет";
            checkTones[2] = current.Protected ? Tone.Open : current.Routed ? Tone.Working : Tone.Off;
            servicesLine = current.Services.Length != 0 ? String.Join(" \u00B7 ", current.Services) :
                current.Domains == 0 ? "Не назначены" : "Доменов: " + current.Domains;
            servicesNote = current.Services.Length == 0 ? "" : "Доменов: " + current.Domains;
            availableLine = current.Available.Length == 0 ? "" : "По запросу: " + String.Join(", ", current.Available);
            bool registered = current.GuardInstalled && current.State != "registration_pending" && current.State != "registration_error";
            register.Visible = current.State == "enrollment_required" || current.State == "registration_error";
            resume.Visible = current.State == "registration_pending" || current.State == "registration_error";
            connect.Visible = registered && !current.Wanted;
            disconnect.Visible = registered && current.Wanted;
            bool newer = ClientView.Newer(current.Release, System.Reflection.Assembly.GetExecutingAssembly().GetName().Version);
            update.Visible = newer;
            if (connectAfterRegistration && registered && current.State == "blocked" && !current.Wanted && !commandBusy)
            {
                connectAfterRegistration = false;
                SubmitCommand("connect");
            }
            notice = (newer ? "Доступна версия " + current.Release + "." : "") +
                (current.Warnings != null && current.Warnings.Contains("proxy") ? (newer ? "\r\n" : "") +
                    "Включён системный прокси: трафик через него идёт в обход туннеля." : "");
            var own = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
            checkedLine = "Проверено " + DateTime.Now.ToString("HH:mm:ss") + " \u00B7 v" + own.Major + "." + own.Minor + "." + Math.Max(own.Build, 0);
            FitWindow();
        }

        private void PreviewReport()
        {
            using (var preview = CreateReportPreview()) preview.ShowDialog(this);
        }

        internal Form CreateReportPreview()
        {
            var serializer = new JavaScriptSerializer();
            var fields = serializer.Deserialize<Dictionary<string, object>>(current.Report());
            string json = "{\r\n" + String.Join(",\r\n", fields.Select(pair => "  " + serializer.Serialize(pair.Key) + ": " + serializer.Serialize(pair.Value))) + "\r\n}";
            var preview = new Form { Text = "Отчёт", ClientSize = new Size(600, 320), StartPosition = FormStartPosition.CenterParent };
            var content = new TextBox { Text = json, Multiline = true, ReadOnly = true, Dock = DockStyle.Fill,
                ScrollBars = ScrollBars.Both, Font = new Font(FontFamily.GenericMonospace, 10), WordWrap = false };
            var save = new Button { Text = "Сохранить…", Dock = DockStyle.Bottom, Height = 40 };
            save.Click += (sender, args) =>
            {
                using (var dialog = new SaveFileDialog { Filter = "JSON (*.json)|*.json", FileName = "ikev2-client-report.json", OverwritePrompt = true })
                {
                    if (dialog.ShowDialog(preview) != DialogResult.OK) return;
                    try { File.WriteAllText(dialog.FileName, json, new UTF8Encoding(false)); }
                    catch (IOException) { MessageBox.Show(preview, "Не удалось сохранить отчёт.", "Отчёт"); }
                    catch (UnauthorizedAccessException) { MessageBox.Show(preview, "Нет доступа к выбранному файлу.", "Отчёт"); }
                }
            };
            preview.Controls.Add(content);
            preview.Controls.Add(save);
            return preview;
        }

        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new ClientWindow());
        }
    }
}
