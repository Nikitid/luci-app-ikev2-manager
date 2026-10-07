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
        private readonly string[] checkLabels = { "Блокировка вне туннеля", "Туннель и маршруты", "Путь через офис" };
        private readonly string[] checkValues = { "", "", "" };
        private readonly Tone[] checkTones = { Tone.Off, Tone.Off, Tone.Off };
        private readonly Button register = new Button { Text = "Зарегистрировать устройство…", AutoSize = true };
        private readonly Button resume = new Button { Text = "Продолжить регистрацию", AutoSize = true };
        private readonly Button connect = new Button { Text = "Включить доступ", AutoSize = true };
        private readonly Button disconnect = new Button { Text = "Отключить доступ", AutoSize = true };
        private readonly Button update = new Button { Text = "Скачать обновление", AutoSize = true, Visible = false, TabStop = false };
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
            Text = "IKEv2 Manager";
            ClientSize = new Size(560, 470);
            AutoScaleMode = AutoScaleMode.Dpi;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            Font = new Font("Segoe UI", 10);
            BackColor = Color.FromArgb(245, 245, 247);
            StartPosition = FormStartPosition.CenterScreen;
            var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Bottom, Padding = new Padding(20, 8, 20, 16), WrapContents = true };
            var refresh = new Button { Text = "Проверить", AutoSize = true };
            var report = new Button { Text = "Отчёт…", AutoSize = true };
            refresh.Click += (sender, args) => RefreshStatus();
            report.Click += (sender, args) => PreviewReport();
            register.Click += (sender, args) => BeginRegistration();
            resume.Click += (sender, args) => SubmitCommand("continue");
            connect.Click += (sender, args) => SubmitCommand("connect");
            disconnect.Click += (sender, args) => SubmitCommand("disconnect");
            update.Click += (sender, args) =>
            {
                if (!ClientView.Newer(current.Release, System.Reflection.Assembly.GetExecutingAssembly().GetName().Version)) return;
                try { System.Diagnostics.Process.Start(Downloads + current.Release + "/IKEv2ManagerClientSetup.exe"); }
                catch (System.ComponentModel.Win32Exception) { MessageBox.Show(this, "Не удалось открыть браузер.", "Обновление"); }
            };
            // The next thing to do stands first and stands out.
            foreach (var primary in new[] { register, connect })
            {
                primary.FlatStyle = FlatStyle.Flat; primary.FlatAppearance.BorderSize = 0;
                primary.BackColor = Color.FromArgb(0, 103, 192); primary.ForeColor = Color.White;
            }
            foreach (var button in new[] { register, resume, connect, disconnect, refresh, report, update })
            {
                button.Margin = new Padding(4, 4, 4, 4); button.Padding = new Padding(4, 2, 4, 2);
                if (button.FlatStyle != FlatStyle.Flat)
                {
                    button.FlatStyle = FlatStyle.Flat; button.BackColor = Color.White;
                    button.FlatAppearance.BorderColor = Color.FromArgb(200, 200, 206);
                }
                buttons.Controls.Add(button);
            }
            surface.Paint += (sender, args) => Draw(args.Graphics, true);
            Controls.Add(surface);
            Controls.Add(buttons);
            timer.Tick += (sender, args) => RefreshStatus();
            Shown += (sender, args) => { RefreshStatus(); timer.Start(); };
            FormClosed += (sender, args) => timer.Dispose();
        }

        // Draws the status, the checks and the services, and returns the height
        // they take, so the window is exactly as tall as what it says.
        private int Draw(Graphics g, bool paint)
        {
            float k = g.DpiX / 96f;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            float left = 24 * k, width = surface.ClientSize.Width - 48 * k, y = 22 * k;
            Color ink = Color.FromArgb(28, 28, 30), soft = Color.FromArgb(110, 110, 115), line = Color.FromArgb(217, 217, 222);
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
                    g.DrawString("СЕРВИСЫ ЧЕРЕЗ ОФИС", small, softBrush, left + pad, y + pad - 2 * k);
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

        private static void Card(Graphics g, float x, float y, float width, float height, Pen border, float radius)
        {
            using (var shape = Rounded(x, y, width, height, radius)) { g.FillPath(Brushes.White, shape); g.DrawPath(border, shape); }
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
                MessageBox.Show(this, "Для начальной регистрации запустите приложение с правами администратора. Продолжение регистрации доступно без повышения прав.", "Регистрация");
                return;
            }
            using (var dialog = new Form { Text = "Регистрация доступа", ClientSize = new Size(560, 170),
                StartPosition = FormStartPosition.CenterParent, Font = Font, MinimizeBox = false, MaximizeBox = false })
            {
                var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1 };
                var input = new TextBox { Dock = DockStyle.Fill, UseSystemPasswordChar = true };
                var submit = new Button { Text = "Зарегистрировать", AutoSize = true, DialogResult = DialogResult.OK };
                layout.Controls.Add(new Label { Text = "Вставьте ссылку приглашения, выданную администратором", AutoSize = true });
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
                    MessageBox.Show(this, result == "administrator_required" ? "Требуются права администратора." : "Служба отклонила действие. Проверьте состояние клиента.", "Регистрация");
            }
            catch { if (!IsDisposed) MessageBox.Show(this, "Не удалось связаться с системной службой. Проверьте её состояние.", "Регистрация"); }
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
            switch (current.State)
            {
                case "blocked":
                    heading = current.Wanted ? "Доступ закрыт" : "Доступ выключен";
                    description = (current.Wanted ? "Нет подтверждённого подключения к офису. Сервисы офиса заблокированы." :
                        "Вы выключили доступ. Сервисы офиса заблокированы, остальной интернет работает как обычно.");
                    break;
                case "enrollment_required":
                    heading = "Устройство не зарегистрировано";
                    description = ("Получите у администратора ссылку приглашения и нажмите «Зарегистрировать устройство».");
                    break;
                case "registration_pending":
                    heading = "Регистрация не завершена";
                    description = (current.ConnectionError == "enrollment_connection_failed" ? "Нет связи с роутером по адресу из приглашения. Проверьте интернет; попытка повторяется автоматически." :
                        current.ConnectionError == "enrollment_access_rejected" ? "Роутер не принял приглашение: оно истекло, уже использовано или отменено. Попросите у администратора новое." :
                        current.ConnectionError != "none" ? "Роутер ответил не так, как ожидалось (" + current.ConnectionError + "). Попытка повторяется автоматически." :
                        "Ожидается выдача настроек сервера. Подключение VPN и защита выбранных сервисов ещё не подтверждены.");
                    break;
                case "registration_error":
                    heading = "Ошибка регистрации";
                    description = ("Не удалось получить или сохранить настройки. VPN не активирован. Подробности состояния доступны в отчёте.");
                    break;
                case "connecting":
                    heading = "Подключение";
                    description = ("Служба устанавливает IKEv2-соединение. Доступ к закреплённым адресам остаётся заблокирован.");
                    break;
                case "protected":
                    heading = "Доступ открыт";
                    description = ("Выбранные сервисы идут через офис: туннель, маршруты и путь на роутере подтверждены. Остальной трафик идёт как обычно.");
                    break;
                case "tunnel_connected":
                    heading = "Туннель установлен";
                    description = (PathText(current.ConnectionError));
                    break;
                case "connection_error":
                    heading = "Не удалось подключить VPN";
                    description = ("Служба не подтвердила нужный туннель или маршруты. Доступ к закреплённым адресам остаётся заблокирован; попытка повторится автоматически.");
                    break;
                case "access_closed":
                    heading = "Доступ не включён";
                    description = ("Роутер знает это устройство, но доступ для него не включён администратором или отозван. Выбранные сервисы остаются заблокированы; проверка повторяется автоматически.");
                    break;
                case "error":
                    heading = "Ошибка системной службы";
                    description = ("Служба не смогла подтвердить защиту или обновить настройки с сервера. Доступ не подтверждён; повторная синхронизация выполняется автоматически.");
                    break;
                case "service_missing":
                    heading = "Служба не установлена";
                    description = ("Системный компонент клиента отсутствует. Защита ещё не настроена.");
                    break;
                case "service_stopped":
                    heading = "Служба остановлена";
                    description = ("Блокировки могут оставаться включены. Их текущее состояние не подтверждено.");
                    break;
                default:
                    heading = "Состояние не подтверждено";
                    description = ("Проверка службы или её статуса не прошла. Код состояния доступен в отчёте.");
                    break;
            }
            bool fresh = current.State == "enrollment_required";
            checkValues[0] = current.GuardInstalled ? "включена" : fresh ? "появится после регистрации" : "не подтверждена";
            checkTones[0] = current.GuardInstalled ? Tone.Open : fresh ? Tone.Off : Tone.Attention;
            checkValues[1] = current.Routed ? "подтверждены" : current.State == "connecting" ? "устанавливаются" : "нет";
            checkTones[1] = current.Routed ? Tone.Open : current.State == "connecting" ? Tone.Working : Tone.Off;
            checkValues[2] = current.Protected ? "подтверждён" : "не подтверждён";
            checkTones[2] = current.Protected ? Tone.Open : current.Routed ? Tone.Working : Tone.Off;
            servicesLine = current.Services.Length != 0 ? String.Join(" \u00B7 ", current.Services) :
                current.Domains == 0 ? "Пока не назначены" : "Доменов: " + current.Domains + ", названия уточняются";
            servicesNote = current.Services.Length == 0 ? "" : "Доменов: " + current.Domains + " \u00B7 версия настроек " + current.Revision;
            availableLine = current.Available.Length == 0 ? "" : "По запросу у администратора: " + String.Join(", ", current.Available);
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
            notice = (newer ? "Доступна версия " + current.Release + ". Установка сохранит регистрацию." : "") +
                (current.Warnings != null && current.Warnings.Contains("proxy") ? (newer ? "\r\n" : "") +
                    "На компьютере включён прокси: программы, которые ходят через него, обращаются к сервисам в обход офиса." : "");
            var own = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
            checkedLine = "Проверено " + DateTime.Now.ToString("HH:mm:ss") + " \u00B7 v" + own.Major + "." + own.Minor + "." + Math.Max(own.Build, 0);
            FitWindow();
        }

        private static string PathText(string code)
        {
            switch (code)
            {
                case "path_unavailable": return "Роутер пока не подтвердил путь для выбранных сервисов. Доступ к ним остаётся заблокирован; проверка повторяется автоматически.";
                case "path_connection_failed": return "Нет связи со службой доступа на роутере. Доступ к выбранным сервисам остаётся заблокирован; проверка повторяется автоматически.";
                case "path_different_policy": return "Роутер и клиент применяют разные версии настроек. Доступ остаётся заблокирован, пока настройки не совпадут.";
                case "device_access_revoked": return "Доступ этого устройства отозван администратором. Выбранные сервисы остаются заблокированы.";
                case "path_response_invalid": return "Роутер прислал ответ, который клиент не принял. Доступ к выбранным сервисам остаётся заблокирован.";
                default: return "IKEv2 и маршруты выбранных адресов подтверждены. Ожидается подтверждение пути от роутера; доступ пока заблокирован.";
            }
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
            var preview = new Form { Text = "Отчёт о состоянии", ClientSize = new Size(600, 320), StartPosition = FormStartPosition.CenterParent };
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
