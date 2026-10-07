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
        private readonly Label heading = new Label { AutoSize = true, Font = new Font("Segoe UI", 18, FontStyle.Bold), Margin = new Padding(0, 0, 0, 12) };
        private readonly Label description = new Label { AutoSize = true, MaximumSize = new Size(560, 0), Margin = new Padding(0, 0, 0, 24) };
        private readonly Label guard = new Label { AutoSize = true, Margin = new Padding(0, 0, 0, 6) };
        private readonly Label tunnel = new Label { AutoSize = true, Margin = new Padding(0, 0, 0, 6) };
        private readonly Label path = new Label { AutoSize = true, Margin = new Padding(0, 0, 0, 12) };
        private readonly Label services = new Label { AutoSize = true, MaximumSize = new Size(560, 0), Margin = new Padding(0, 0, 0, 6) };
        private readonly Button register = new Button { Text = "Регистрация…", AutoSize = true };
        private readonly Button resume = new Button { Text = "Продолжить регистрацию", AutoSize = true };
        private readonly Button connect = new Button { Text = "Подключить", AutoSize = true };
        private readonly Button disconnect = new Button { Text = "Отключить", AutoSize = true };
        private readonly Button update = new Button { Text = "Скачать обновление", AutoSize = true, Visible = false };
        // The one place downloads come from. The router supplies a version
        // number and nothing else.
        private const string Downloads = "https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v";
        // Set by a registration started in this window: the first thing a newly
        // registered device wants is its connection.
        private bool connectAfterRegistration;
        private readonly Label updated = new Label { AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(0, 20, 0, 12) };
        private readonly Timer timer = new Timer { Interval = 3000 };
        private ClientView current = new ClientView("status_unavailable");
        private bool commandBusy;

        internal ClientWindow()
        {
            Text = "IKEv2 Manager";
            ClientSize = new Size(620, 430);
            MinimumSize = new Size(580, 440);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 10);
            StartPosition = FormStartPosition.CenterScreen;
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(28), ColumnCount = 1, RowCount = 8 };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            layout.Controls.Add(heading);
            layout.Controls.Add(description);
            layout.Controls.Add(guard);
            layout.Controls.Add(tunnel);
            layout.Controls.Add(path);
            layout.Controls.Add(services);
            layout.Controls.Add(updated);
            var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Margin = Padding.Empty };
            var refresh = new Button { Text = "Проверить сейчас", AutoSize = true, Margin = new Padding(0, 0, 12, 0) };
            var report = new Button { Text = "Отчёт…", AutoSize = true };
            refresh.Click += (sender, args) => RefreshStatus();
            report.Click += (sender, args) => PreviewReport();
            buttons.Controls.Add(refresh);
            buttons.Controls.Add(report);
            register.Click += (sender, args) => BeginRegistration();
            resume.Click += (sender, args) => SubmitCommand("continue");
            buttons.Controls.Add(register);
            buttons.Controls.Add(resume);
            connect.Click += (sender, args) => SubmitCommand("connect");
            disconnect.Click += (sender, args) => SubmitCommand("disconnect");
            buttons.Controls.Add(connect); buttons.Controls.Add(disconnect);
            update.Click += (sender, args) =>
            {
                if (!ClientView.Newer(current.Release, System.Reflection.Assembly.GetExecutingAssembly().GetName().Version)) return;
                try { System.Diagnostics.Process.Start(Downloads + current.Release + "/IKEv2ManagerClientSetup.exe"); }
                catch (System.ComponentModel.Win32Exception) { MessageBox.Show(this, "Не удалось открыть браузер.", "Обновление"); }
            };
            buttons.Controls.Add(update);
            buttons.WrapContents = true;
            layout.Controls.Add(buttons);
            Controls.Add(layout);
            // Text wraps at the width the window really has, at any scaling:
            // a fixed limit cut words in half on a scaled display.
            Resize += (sender, args) => FitText();
            timer.Tick += (sender, args) => RefreshStatus();
            Shown += (sender, args) => { RefreshStatus(); timer.Start(); };
            FormClosed += (sender, args) => timer.Dispose();
        }

        // Long texts are broken into lines here, word by word, for the width the
        // window has. Left to the label, a line was cut in the middle of a word.
        private void FitText()
        {
            var layout = Controls.Count == 0 ? null : Controls[0] as TableLayoutPanel;
            if (layout == null) return;
            // The column the labels sit in, less a margin of safety: a line that
            // is a pixel too long is cut by the label at whatever letter fits.
            int[] columns = layout.GetColumnWidths();
            int width = Math.Max(200, (columns.Length == 0 ? layout.ClientSize.Width - layout.Padding.Horizontal : columns[0]) - 32);
            foreach (var label in new[] { description, services, updated })
            {
                string original = label.Tag as string ?? label.Text;
                var lines = new List<string>();
                foreach (string paragraph in original.Replace("\r\n", "\n").Split('\n'))
                {
                    string line = "";
                    foreach (string word in paragraph.Split(' '))
                    {
                        string longer = line.Length == 0 ? word : line + " " + word;
                        if (line.Length != 0 && TextRenderer.MeasureText(longer, label.Font).Width > width)
                        { lines.Add(line); line = word; }
                        else line = longer;
                    }
                    lines.Add(line);
                }
                label.Tag = original;
                label.MaximumSize = Size.Empty;
                label.AutoSize = true;
                label.Text = String.Join("\r\n", lines);
            }
        }

        // The text a label is asked to show, before it is broken into lines.
        private static void Say(Label label, string text) { label.Tag = text; label.Text = text; }

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

        private void RefreshStatus()
        {
            current = ClientStatusReader.Read();
            heading.ForeColor = current.State == "blocked" ? Color.FromArgb(155, 87, 0) :
                current.Protected ? Color.FromArgb(0, 110, 60) : SystemColors.ControlText;
            switch (current.State)
            {
                case "blocked":
                    heading.Text = "Доступ закрыт";
                    Say(description, "Нет подтверждённого подключения к офису. Выбранные адреса остаются заблокированы.");
                    break;
                case "enrollment_required":
                    heading.Text = "Требуется настройка доступа";
                    Say(description, "Клиент ещё не получил политику доступа организации.");
                    break;
                case "registration_pending":
                    heading.Text = "Регистрация не завершена";
                    Say(description, current.ConnectionError == "enrollment_connection_failed" ? "Нет связи с роутером по адресу из приглашения. Проверьте интернет; попытка повторяется автоматически." :
                        current.ConnectionError == "enrollment_access_rejected" ? "Роутер не принял приглашение: оно истекло, уже использовано или отменено. Попросите у администратора новое." :
                        current.ConnectionError != "none" ? "Роутер ответил не так, как ожидалось (" + current.ConnectionError + "). Попытка повторяется автоматически." :
                        "Ожидается выдача настроек сервера. Подключение VPN и защита выбранных сервисов ещё не подтверждены.");
                    break;
                case "registration_error":
                    heading.Text = "Ошибка регистрации";
                    Say(description, "Не удалось получить или сохранить настройки. VPN не активирован. Подробности состояния доступны в отчёте.");
                    break;
                case "connecting":
                    heading.Text = "Подключение к VPN";
                    Say(description, "Служба устанавливает IKEv2-соединение. Доступ к закреплённым адресам остаётся заблокирован.");
                    break;
                case "protected":
                    heading.Text = "Доступ открыт";
                    Say(description, "Выбранные сервисы идут через офис: туннель, маршруты и путь на роутере подтверждены. Остальной трафик идёт как обычно.");
                    break;
                case "tunnel_connected":
                    heading.Text = "Туннель установлен";
                    Say(description, PathText(current.ConnectionError));
                    break;
                case "connection_error":
                    heading.Text = "Не удалось подключить VPN";
                    Say(description, "Служба не подтвердила нужный туннель или маршруты. Доступ к закреплённым адресам остаётся заблокирован; попытка повторится автоматически.");
                    break;
                case "access_closed":
                    heading.Text = "Доступ не включён";
                    Say(description, "Роутер знает это устройство, но доступ для него не включён администратором или отозван. Выбранные сервисы остаются заблокированы; проверка повторяется автоматически.");
                    break;
                case "error":
                    heading.Text = "Ошибка системной службы";
                    Say(description, "Служба не смогла подтвердить защиту или обновить настройки с сервера. Доступ не подтверждён; повторная синхронизация выполняется автоматически.");
                    break;
                case "service_missing":
                    heading.Text = "Служба не установлена";
                    Say(description, "Системный компонент клиента отсутствует. Защита ещё не настроена.");
                    break;
                case "service_stopped":
                    heading.Text = "Служба остановлена";
                    Say(description, "Блокировки могут оставаться включены. Их текущее состояние не подтверждено.");
                    break;
                default:
                    heading.Text = "Состояние не подтверждено";
                    Say(description, "Проверка службы или её статуса не прошла. Код состояния доступен в отчёте.");
                    break;
            }
            guard.Text = "Блокировка вне туннеля: " + (current.GuardInstalled ? "включена и проверена" : "не подтверждена");
            tunnel.Text = "Туннель и маршруты выбранных сервисов: " + (current.Routed ? "подтверждены" : current.State == "connecting" ? "устанавливаются" : "нет");
            path.Text = "Путь на роутере: " + (current.Protected ? "подтверждён" : "не подтверждён");
            Say(services, (current.Services.Length == 0 ? (current.Domains == 0 ? "Назначенные сервисы: нет" : "Назначенные сервисы: доменов " + current.Domains + ", названия уточняются") :
                "Назначенные сервисы (доменов: " + current.Domains + ", версия настроек " + current.Revision + "): " + String.Join(", ", current.Services)) +
                (current.Available.Length == 0 ? "" : "\r\nДоступны по запросу у администратора: " + String.Join(", ", current.Available)) +
                (current.Warnings != null && current.Warnings.Contains("proxy") ? "\r\nВнимание: на этом компьютере включён прокси. Программы, которые ходят через него, обращаются к выбранным сервисам в обход туннеля." : ""));
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
            Say(updated, "Проверено: " + DateTime.Now.ToString("HH:mm:ss") +
                (update.Visible ? "\r\nДоступна версия " + current.Release + ". Скачайте установщик и запустите его: регистрация сохранится." : ""));
            FitText();
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
