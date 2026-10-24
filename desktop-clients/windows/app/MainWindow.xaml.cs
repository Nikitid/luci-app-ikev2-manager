using System.Diagnostics;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Win32;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.UI;

namespace Waypoint;

// The window shows one reading of the service at a time and sends it what the
// person asks for. Everything it says comes from ClientPresentation; anything
// that needs a right is done by the service, or by its binary started with an
// administrator's right.
public sealed partial class MainWindow : Window
{
    const string Preferences = @"Software\Waypoint";
    // The one place downloads come from. The router supplies a version number
    // and nothing else.
    const string Downloads = "https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v";
    static readonly Version Own = typeof(MainWindow).Assembly.GetName().Version;

    readonly DispatcherQueueTimerHolder timer;
    readonly Tray tray;
    readonly TextBox[] addressValues = new TextBox[4];
    readonly Button[] addressCopy = new Button[4];
    ClientView current = new("status_unavailable");
    ClientPresentation shown;
    string servicesShown = "";
    string theme = "system";
    bool busy, reading, quitting, connectAfterRegistration;

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Waypoint.ico"));
        double scale = Root.XamlRoot?.RasterizationScale ?? GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new SizeInt32((int)(980 * scale), (int)(640 * scale)));
        Center();

        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(Preferences);
            if (key?.GetValue("Theme") is string chosen && (chosen == "light" || chosen == "dark")) theme = chosen;
        }
        catch (System.Security.SecurityException) { }
        catch (UnauthorizedAccessException) { }
        ApplyTheme();
        Root.ActualThemeChanged += (_, _) => PaintCaption();

        for (int i = 0; i < 4; i++) AddAddressRow(i);

        tray = new Tray(ShowWindow, () => _ = Command(current.Wanted ? "disconnect" : "connect"), Quit);
        tray.Show();
        // Closing the window leaves the icon in the notification area: the
        // service goes on, and the person can get back to it from there.
        AppWindow.Closing += (_, args) =>
        {
            if (quitting || !tray.Visible) { Teardown(); return; }
            args.Cancel = true;
            AppWindow.Hide();
        };

        timer = new DispatcherQueueTimerHolder(DispatcherQueue, TimeSpan.FromSeconds(3), Refresh);
        ThreadPool.RegisterWaitForSingleObject(Program.ShowRequests, (_, _) => DispatcherQueue.TryEnqueue(ShowWindow), null, -1, false);
        Activated += FirstActivation;
        Refresh();
    }

    void FirstActivation(object sender, WindowActivatedEventArgs args)
    {
        Activated -= FirstActivation;
        PaintCaption();
        if (Program.Register) DispatcherQueue.TryEnqueue(() => OnRegister(null, null));
    }

    void Center()
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2, area.Y + (area.Height - AppWindow.Size.Height) / 2));
    }

    void ShowWindow()
    {
        AppWindow.Show();
        Activate();
        Program.SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
        Refresh();
    }

    void Quit()
    {
        quitting = true;
        Close();
    }

    void Teardown()
    {
        timer.Stop();
        tray.Dispose();
    }

    // ---- Reading ----------------------------------------------------------

    async void Refresh()
    {
        if (reading) return;
        reading = true;
        try
        {
            var (view, self, told) = await Task.Run(() => (ClientStatusReader.Read(), BrowserNames.SelfResolving(), BrowserNames.Told()));
            Present(view, self, told);
        }
        finally { reading = false; }
    }

    static Color Shade(Tone tone) => tone switch
    {
        Tone.Open => Color.FromArgb(255, 33, 140, 69),
        Tone.Working => Color.FromArgb(255, 217, 140, 13),
        Tone.Attention => Color.FromArgb(255, 199, 51, 46),
        _ => Color.FromArgb(255, 128, 128, 133),
    };

    static string Glyph(Tone tone) => tone switch
    {
        Tone.Open => "", Tone.Working => "", Tone.Attention => "", _ => "",
    };

    void Present(ClientView view, string[] self, bool told)
    {
        current = view;
        var p = shown = ClientPresentation.Of(view, Own, self, told);
        var brush = new SolidColorBrush(Shade(p.Tone));
        Halo.Fill = brush;
        Sign.Glyph = Glyph(p.Tone);
        Sign.Foreground = brush;
        Heading.Text = p.Heading;
        Description.Text = p.Description;

        Notice.Message = string.Join("\n", p.Notes);
        Notice.IsOpen = p.Notes.Length != 0;

        Checks.Children.Clear();
        foreach (var check in p.Checks)
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 8, Height = 8, Fill = new SolidColorBrush(Shade(check.Tone)), VerticalAlignment = VerticalAlignment.Center });
            var label = new TextBlock { Text = check.Label };
            Grid.SetColumn(label, 1);
            row.Children.Add(label);
            var value = new TextBlock { Text = check.Value, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], TextAlignment = TextAlignment.Right, TextWrapping = TextWrapping.Wrap, MaxWidth = 320 };
            Grid.SetColumn(value, 2);
            row.Children.Add(value);
            Checks.Children.Add(row);
        }

        PresentServices(p);

        for (int i = 0; i < 4; i++)
        {
            string value = p.Addresses[i];
            addressValues[i].Text = value.Length == 0 ? "Нет данных" : value;
            addressCopy[i].IsEnabled = value.Length != 0;
        }

        RegisterButton.Visibility = Shown(p.Register);
        ResumeButton.Visibility = Shown(p.Resume);
        ConnectButton.Visibility = Shown(p.Connect);
        DisconnectButton.Visibility = Shown(p.Disconnect);
        UpdateButton.Visibility = Shown(p.Update);
        BrowsersButton.Visibility = Shown(p.Browsers);
        CheckedLine.Text = "Проверено " + DateTime.Now.ToString("HH:mm:ss") + " · v" + Own.Major + "." + Own.Minor + "." + Math.Max(Own.Build, 0);
        tray.Update("Waypoint: " + p.Heading, p.Disconnect ? "Отключить" : p.Connect ? "Включить" : null);

        // The first thing a newly registered device wants is its connection.
        if (connectAfterRegistration && p.Registered && view.State == "blocked" && !view.Wanted && !busy)
        {
            connectAfterRegistration = false;
            _ = Command("connect");
        }
    }

    static Visibility Shown(bool shown) => shown ? Visibility.Visible : Visibility.Collapsed;

    // Rows are made again only when what they say changes: the poll every three
    // seconds must not take a switch from under the person's finger.
    void PresentServices(ClientPresentation p)
    {
        string signature = string.Join("|", p.Services.Select(s => s.Id + ":" + s.On + ":" + s.Closed + ":" + s.CanTurn + ":" + s.CanClose + ":" + s.Label)) + "|" + p.Choosing;
        bool rows = p.Services.Length != 0;
        ServicesLine.Visibility = ServicesNote.Visibility = Shown(!rows);
        AvailableLine.Visibility = Shown(!rows && p.AvailableLine.Length != 0);
        ServicesLine.Text = p.ServicesLine;
        ServicesNote.Text = p.ServicesNote;
        AvailableLine.Text = p.AvailableLine;
        if (signature == servicesShown) return;
        servicesShown = signature;
        Services.Children.Clear();
        foreach (var service in p.Services)
        {
            var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 4, 0, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            words.Children.Add(new TextBlock { Text = service.Label, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
            words.Children.Add(new TextBlock { Text = service.Note, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
            row.Children.Add(words);
            var closed = new CheckBox { Content = "Только через туннель", IsChecked = service.Closed, IsEnabled = service.CanClose && !p.Choosing,
                Visibility = Shown(service.ChooseClosed), MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
            ToolTipService.SetToolTip(closed, "Когда туннель не подключён, сервис закрыт, а не открывается напрямую.");
            Grid.SetColumn(closed, 1);
            row.Children.Add(closed);
            var on = new ToggleSwitch { IsOn = service.On, IsEnabled = service.CanTurn && !p.Choosing, OnContent = "", OffContent = "",
                MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
            ToolTipService.SetToolTip(on, service.CanTurn ? "Включить или выключить сервис" : "Обязательный сервис");
            Grid.SetColumn(on, 2);
            row.Children.Add(on);
            string id = service.Id;
            on.Toggled += (_, _) => { if (on.IsOn != service.On) Choose(id, on.IsOn, null); };
            closed.Click += (_, _) => Choose(id, null, closed.IsChecked == true);
            Services.Children.Add(row);
        }
    }

    void Choose(string id, bool? on, bool? closed)
    {
        if (shown == null || shown.Choosing) return;
        ClientPresentation.Chosen(shown.Services, id, on, closed, out var chosenOn, out var chosenClosed);
        servicesShown = "";
        _ = Command("choose", chosenOn: chosenOn, chosenClosed: chosenClosed);
    }

    void AddAddressRow(int index)
    {
        var block = new StackPanel { Spacing = 4 };
        block.Children.Add(new TextBlock { Text = ClientPresentation.AddressLabels[index], Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        var line = new Grid { ColumnSpacing = 6 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var value = new TextBox { IsReadOnly = true, Text = "Нет данных", FontFamily = new FontFamily("Consolas") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(value, ClientPresentation.AddressLabels[index]);
        var copy = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, IsEnabled = false };
        ToolTipService.SetToolTip(copy, "Скопировать");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(copy, "Скопировать: " + ClientPresentation.AddressLabels[index]);
        copy.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(shown?.Addresses[index] ?? "");
            Clipboard.SetContent(package);
            ToolTipService.SetToolTip(copy, "Скопировано");
        };
        Grid.SetColumn(copy, 1);
        line.Children.Add(value);
        line.Children.Add(copy);
        block.Children.Add(line);
        Addresses.Children.Add(block);
        addressValues[index] = value;
        addressCopy[index] = copy;
    }

    // ---- Commands ---------------------------------------------------------

    async Task Command(string operation, string endpoint = null, string invitation = null, string[] chosenOn = null, string[] chosenClosed = null)
    {
        if (busy) return;
        busy = true;
        try
        {
            string result = await Task.Run(() => ClientCommands.Send(operation, endpoint, invitation, on: chosenOn, closed: chosenClosed));
            if (result == "accepted" && operation == "begin")
                await Task.Run(() => ClientCommands.Send("continue"));
            else if (result != "accepted" && result != "busy")
                await Say(operation == "choose" ? "Сервисы" : "Waypoint",
                    result == "administrator_required" ? "Требуются права администратора." :
                    operation == "choose" ? "Этот выбор сейчас недоступен: предложение изменилось. Посмотрите на список ещё раз." : "Действие отклонено.");
        }
        catch (Exception) { await Say("Waypoint", "Служба не отвечает."); }
        finally { busy = false; Refresh(); }
    }

    async Task Say(string title, string text)
    {
        if (Root.XamlRoot == null) return;
        await new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "OK", RequestedTheme = Root.ActualTheme }.ShowAsync();
    }

    async Task<bool> Ask(string title, string text, string yes)
    {
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = yes, CloseButtonText = "Отмена", DefaultButton = ContentDialogButton.Close, RequestedTheme = Root.ActualTheme };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    // The service's binary does what needs an administrator; Windows asks for
    // the right, and this window never holds it. Null when it was not started.
    static async Task<int?> Elevated(string request, TimeSpan wait)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "ClientService.exe"), request) { UseShellExecute = true, Verb = "runas" });
            if (process == null) return null;
            using var deadline = new CancellationTokenSource(wait);
            try { await process.WaitForExitAsync(deadline.Token); } catch (OperationCanceledException) { return -1; }
            return process.ExitCode;
        }
        catch (System.ComponentModel.Win32Exception) { return null; }
    }

    async void OnRegister(object sender, RoutedEventArgs args)
    {
        if (busy) return;
        if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
        {
            // Registration changes the system, so Windows asks for an
            // administrator; the window opens again with that right and goes
            // straight to the link. This one closes.
            try
            {
                Process.Start(new ProcessStartInfo(Environment.ProcessPath, "--register") { UseShellExecute = true, Verb = "runas" });
                Quit();
            }
            catch (System.ComponentModel.Win32Exception) { await Say("Регистрация", "Для регистрации нужны права администратора."); }
            return;
        }
        var input = new PasswordBox { PlaceholderText = "https://…" };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Регистрация", PrimaryButtonText = "Зарегистрировать", CloseButtonText = "Отмена",
            DefaultButton = ContentDialogButton.Primary, RequestedTheme = Root.ActualTheme,
            Content = new StackPanel { Spacing = 8, Children = { new TextBlock { Text = "Ссылка приглашения от администратора" }, input } } };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            ClientCommands.ParseInvitation(input.Password, out var endpoint, out var token);
            input.Password = "";
            connectAfterRegistration = true;
            await Command("begin", endpoint, token);
        }
        catch (ArgumentException) { await Say("Регистрация", "Приглашение имеет неверный формат."); }
        catch (FormatException) { await Say("Регистрация", "Приглашение имеет неверный формат."); }
    }

    void OnResume(object sender, RoutedEventArgs args) => _ = Command("continue");
    void OnConnect(object sender, RoutedEventArgs args) => _ = Command("connect");
    void OnDisconnect(object sender, RoutedEventArgs args) => _ = Command("disconnect");
    void OnRefresh(object sender, RoutedEventArgs args) => Refresh();

    async void OnUpdate(object sender, RoutedEventArgs args)
    {
        if (!ClientView.Newer(current.Release, Own)) return;
        try { Process.Start(new ProcessStartInfo(Downloads + current.Release + "/WaypointSetup.exe") { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { await Say("Обновление", "Не удалось открыть браузер."); }
    }

    async void OnBrowsers(object sender, RoutedEventArgs args)
    {
        bool told = BrowserNames.Told();
        var self = BrowserNames.SelfResolving();
        string question = told
            ? "Waypoint задал браузерам на этом компьютере политику «использовать системный DNS».\n\nВернуть браузерам их собственную настройку?"
            : "Браузер со своим DNS поверх HTTPS (DoH)" + (self.Length == 0 ? "" : " (" + string.Join(", ", self) + ")") +
              " открывает сервисы в обход туннеля.\n\nWaypoint может задать Chrome, Edge, Brave, Яндекс Браузеру и Firefox политику «использовать системный DNS». " +
              "Она действует для всех сайтов и всех пользователей этого компьютера; вернуть её можно здесь же.";
        if (!await Ask("DNS в браузерах", question, told ? "Вернуть" : "Задать")) return;
        int? code = await Elevated(told ? "--browsers-off" : "--browsers-on", TimeSpan.FromSeconds(60));
        if (code == null) await Say("DNS в браузерах", "Нужны права администратора.");
        else if (code != 0) await Say("DNS в браузерах", "Настройка не изменена. Повторите.");
        else if (!told) await Say("DNS в браузерах", "Готово. Перезапустите браузеры, чтобы настройка вступила в силу.");
        Refresh();
    }

    async void OnReset(object sender, RoutedEventArgs args)
    {
        if (!await Ask("Сброс Waypoint", "Сбросить Waypoint на этом компьютере?\n\nБудут удалены: VPN-подключение, блокировки, DNS-записи сервисов и регистрация устройства. " +
            "Программа останется; чтобы вернуть доступ, понадобится новая ссылка от администратора.", "Сбросить")) return;
        // As long as the removal may take: stopping the service, the removal and the start again.
        int? code = await Elevated("--reset", TimeSpan.FromSeconds(240));
        if (code == null) await Say("Сброс Waypoint", "Сброс не запущен: нужны права администратора.");
        else if (code == -1) await Say("Сброс Waypoint", "Сброс ещё идёт. Подождите минуту и нажмите «Проверить».");
        else if (code != 0) await Say("Сброс Waypoint", "Сброс не завершён. Причина записана в отчёт: повторите сброс или отправьте отчёт администратору.");
        Refresh();
    }

    async void OnReport(object sender, RoutedEventArgs args)
    {
        var serializer = new JavaScriptSerializer();
        var fields = serializer.Deserialize<Dictionary<string, object>>(current.Report());
        string json = "{\r\n" + string.Join(",\r\n", fields.Select(pair => "  " + serializer.Serialize(pair.Key) + ": " + serializer.Serialize(pair.Value))) + "\r\n}";
        await new ReportDialog(this, json, current.State).ShowAsync();
    }

    // ---- Look -------------------------------------------------------------

    void OnTheme(object sender, RoutedEventArgs args)
    {
        theme = (string)((FrameworkElement)sender).Tag;
        try { using var key = Registry.CurrentUser.CreateSubKey(Preferences); key.SetValue("Theme", theme); }
        catch (UnauthorizedAccessException) { }
        ApplyTheme();
    }

    void ApplyTheme()
    {
        Root.RequestedTheme = theme == "light" ? ElementTheme.Light : theme == "dark" ? ElementTheme.Dark : ElementTheme.Default;
        ThemeSystem.IsChecked = theme == "system";
        ThemeLight.IsChecked = theme == "light";
        ThemeDark.IsChecked = theme == "dark";
        PaintCaption();
    }

    // The caption buttons are drawn by the system over the window's content
    // and follow the content's light or dark, not the system's.
    void PaintCaption()
    {
        if (!AppWindowTitleBar.IsCustomizationSupported()) return;
        bool dark = Root.ActualTheme == ElementTheme.Dark;
        var bar = AppWindow.TitleBar;
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonForegroundColor = dark ? Colors.White : Colors.Black;
        bar.ButtonHoverBackgroundColor = dark ? Color.FromArgb(40, 255, 255, 255) : Color.FromArgb(20, 0, 0, 0);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetDpiForWindow(IntPtr window);
}

// The three-second poll, stopped with the window.
sealed class DispatcherQueueTimerHolder
{
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;

    public DispatcherQueueTimerHolder(Microsoft.UI.Dispatching.DispatcherQueue queue, TimeSpan interval, Action tick)
    {
        timer = queue.CreateTimer();
        timer.Interval = interval;
        timer.Tick += (_, _) => tick();
        timer.Start();
    }

    public void Stop() => timer.Stop();
}
