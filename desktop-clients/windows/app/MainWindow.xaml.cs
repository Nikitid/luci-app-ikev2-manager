using System.Diagnostics;
using System.Security.Principal;
using System.Web.Script.Serialization;
using IkeV2Manager.Client;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Win32;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.UI;

namespace Waypoint;

// Layout Б. The window shows one reading of the service at a time and sends
// it what the person asks for. What it says comes from ClientPresentation and
// WindowModel, which the tests check; this file only draws it. Anything that
// needs a right is done by the service, or by its binary started with an
// administrator's right.
public sealed partial class MainWindow : Window
{
    // The one place downloads come from. The router supplies a version number
    // and nothing else.
    const string Downloads = "https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v";
    static readonly Version Own = typeof(MainWindow).Assembly.GetName().Version;

    readonly DispatcherQueueTimerHolder timer, reportTimer;
    readonly Reports reports = new();
    readonly Tray tray;
    ClientView current = new("status_unavailable");
    ClientPresentation shown;
    WindowModel model;
    // The page on screen and what it was drawn from: a page is drawn again
    // only when what it shows changed, so the poll every three seconds never
    // takes a switch from under the person's finger.
    string section = "overview", drawn = "";
    string theme = "system";
    bool busy, reading, quitting, connectAfterRegistration, loaded, welcomeDone;
    bool? taskbarLight;

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        double scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new SizeInt32((int)(1100 * scale), (int)(720 * scale)));
        Center();

        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(Program.SettingsKey);
            if (key?.GetValue("Theme") is string chosen && (chosen == "light" || chosen == "dark")) theme = chosen;
        }
        catch (System.Security.SecurityException) { }
        catch (UnauthorizedAccessException) { }
        ApplyTheme();
        Root.ActualThemeChanged += (_, _) => { PaintCaption(); drawn = ""; Draw(); };

        tray = new Tray(ShowWindow, OnTrayChoice);
        tray.Show();
        FollowTaskbar();
        // Closing the window leaves the icon in the notification area: the
        // service goes on, and the person can get back to it from there.
        AppWindow.Closing += (_, args) =>
        {
            if (quitting || !tray.Visible) { Teardown(); return; }
            args.Cancel = true;
            AppWindow.Hide();
        };

        // The frame does not wait for data: the sections are named at once.
        NavOverview.Content = "Обзор";
        NavServices.Content = "Сервисы";
        NavOwn.Content = "Свои сайты и адреса";
        NavReports.Content = "Обращения";
        NavState.Content = new TextBlock { Text = "Читаю состояние…", Style = Styled("SecondaryBody") };
        Nav.SelectedItem = NavOverview;
        timer = new DispatcherQueueTimerHolder(DispatcherQueue, TimeSpan.FromSeconds(3), Refresh);
        // Support's answers are looked for at start and every ten minutes.
        reports.Changed += () => { drawn = ""; Draw(); };
        reportTimer = new DispatcherQueueTimerHolder(DispatcherQueue, TimeSpan.FromMinutes(10), () => reports.LookAround());
        reports.LookAround();
        ThreadPool.RegisterWaitForSingleObject(Program.ShowRequests, (_, _) => DispatcherQueue.TryEnqueue(ShowWindow), null, -1, false);
        Activated += FirstActivation;
        // The frame is drawn at once; the area of data says it is loading until
        // the first reading comes.
        Draw();
        Refresh();
    }

    void FirstActivation(object sender, WindowActivatedEventArgs args)
    {
        Activated -= FirstActivation;
        PaintCaption();
        if (Program.Register) DispatcherQueue.TryEnqueue(() => OnRegister());
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

    // "Exit Waypoint": the window and the icon go; the service, and with it
    // the tunnel, stays. The exit is also a moment an update may go by itself.
    void Quit()
    {
        _ = Task.Run(() => { try { ClientCommands.Send("window_exited"); } catch (Exception) { } });
        quitting = true;
        Close();
    }

    void Teardown()
    {
        timer.Stop();
        reportTimer.Stop();
        tray.Dispose();
    }

    // ---- Reading ----------------------------------------------------------

    async void Refresh()
    {
        if (reading) return;
        reading = true;
        try
        {
            var (view, self, told) = await Task.Run(() => (Read(), BrowserNames.SelfResolving(), BrowserNames.Told()));
            loaded = true;
            current = view;
            shown = ClientPresentation.Of(view, Own, self, told);
            model = WindowModel.Of(view, DateTime.UtcNow);
            FollowTaskbar();
            PresentFrame();
            Draw();
            // The first thing a newly registered device wants is its connection.
            if (connectAfterRegistration && shown.Registered && view.State == "blocked" && !view.Wanted && !busy)
            {
                connectAfterRegistration = false;
                _ = Command("connect");
            }
        }
        finally { reading = false; }
    }

    // The service's status. A debug build takes it from a file when told to,
    // late or failing on purpose, so the window can be checked with slow and
    // broken data without a service; a release build always asks the service.
    static ClientView Read()
    {
#if DEBUG
        string demo = Environment.GetEnvironmentVariable("WAYPOINT_DEMO_STATUS");
        if (!string.IsNullOrEmpty(demo))
        {
            if (int.TryParse(Environment.GetEnvironmentVariable("WAYPOINT_DEMO_DELAY"), out int delay)) Thread.Sleep(delay);
            if (Environment.GetEnvironmentVariable("WAYPOINT_DEMO_FAIL") == "1") return new ClientView("status_unavailable");
            string json = File.ReadAllText(demo);
            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
            data["UpdatedAtUtc"] = DateTime.UtcNow.ToString("o", System.Globalization.CultureInfo.InvariantCulture);
            return ClientStatusReader.Evaluate(new JavaScriptSerializer().Serialize(data), (uint)(int)data["ProcessId"], DateTime.UtcNow);
        }
#endif
        return ClientStatusReader.Read();
    }

    // What every section shares: the badges of the navigation, the state at
    // its foot, the tray icon and its menu.
    void PresentFrame()
    {
        NavOverview.Content = NavLabel("Обзор", null);
        NavServices.Content = NavLabel("Сервисы", model.ServicesBadge);
        NavOwn.Content = NavLabel("Свои сайты и адреса", model.OwnBadge);
        NavOwn.Visibility = Shown(model.OwnBadge != null);
        int unread = reports.Unread;
        NavReports.Content = NavLabel("Обращения", unread == 0 ? null : unread.ToString());
        NavState.Content = new TextBlock { Text = shown.Heading, TextTrimming = TextTrimming.CharacterEllipsis,
            Style = shown.Tone == Tone.Attention ? Styled("DangerBody") : shown.Tone == Tone.Working ? Styled("WarningBody") : Styled("SecondaryBody") };
        NavStateSign.Glyph = Glyph(shown.Tone);
        NavStateSign.Style = Styled("SecondaryIcon");
        if (shown.Tone == Tone.Attention || shown.Tone == Tone.Working) NavStateSign.Foreground = ToneBrush(shown.Tone);
        else NavStateSign.ClearValue(IconElement.ForegroundProperty);
        AutomationProperties.SetName(NavState, "Состояние: " + shown.Heading);
        tray.Update("Waypoint: " + shown.Heading, TrayState(shown.Tone), WindowModel.Tray(current, shown, model, DateTime.UtcNow));
    }

    static object NavLabel(string text, string badge)
    {
        if (badge == null) return text;
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock { Text = text, TextTrimming = TextTrimming.CharacterEllipsis });
        var count = Caption(badge);
        count.TextWrapping = TextWrapping.NoWrap;
        count.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(count, 1);
        grid.Children.Add(count);
        return grid;
    }

    static string TrayState(Tone tone) => tone switch { Tone.Open => "open", Tone.Working => "connecting", Tone.Attention => "attention", _ => "off" };

    // The window's icon and the tray's follow the taskbar's light or dark,
    // which is not the theme of apps: Stone on a light taskbar, graphite on
    // a dark one. Looked at with every reading, so a change shows within it.
    void FollowTaskbar()
    {
        bool light = true;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            light = !(key?.GetValue("SystemUsesLightTheme") is int value && value == 0);
        }
        catch (Exception) { }
        if (taskbarLight == light) return;
        taskbarLight = light;
        string icon = Path.Combine(AppContext.BaseDirectory, "Assets", light ? "Waypoint.ico" : "Waypoint-dark.ico");
        AppWindow.SetIcon(icon);
        TitleIcon.Source = new BitmapImage(new Uri(icon));
        tray.Taskbar(light);
    }

    // ---- Drawing ----------------------------------------------------------

    void OnNavigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItemContainer?.Tag is not string tag) return;
        if (tag == "state") { Nav.SelectedItem = NavOverview; return; }
        if (tag == section) return;
        section = tag;
        drawn = "";
        Scroller.ChangeView(null, 0, null, true);
        Draw();
        Fade();
    }

    void Go(NavigationViewItem item) => Nav.SelectedItem = item;

    void Fade()
    {
        if (!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled) return;
        var fade = new DoubleAnimation { From = 1, To = 0, Duration = new Duration(TimeSpan.FromMilliseconds(200)), EnableDependentAnimation = true };
        Storyboard.SetTarget(fade, Veil);
        Storyboard.SetTargetProperty(fade, "Opacity");
        var board = new Storyboard();
        board.Children.Add(fade);
        board.Begin();
    }

    void Draw()
    {
        if (ShowWelcome()) return;
        string signature = section + "|" + (loaded ? current.Report() : "loading") + "|" + reports.All.Count + "|" + reports.Unread + "|" + Root.ActualTheme;
        // The report carries the time it was made; leave it out.
        signature = System.Text.RegularExpressions.Regex.Replace(signature, "\"CreatedAtUtc\":\"[^\"]*\"", "");
        signature += "|" + string.Join(",", (current.Entries ?? new ServiceChoice[0]).Select(e => e.Id + e.On + e.Closed + e.Health + e.Reason)) +
            "|" + current.CheckAnswer + current.CheckNextAt + "|" + current.Update?.State + current.Update?.Auto + "|" + current.Own?.Pending +
            "|" + string.Join(",", current.Own?.Domains ?? new string[0]) + string.Join(",", current.Own?.Networks ?? new string[0]) + "|" + busy;
        if (signature == drawn) return;
        drawn = signature;
        Body.Content = !loaded ? Loading() : section switch
        {
            "services" => ServicesPage(),
            "own" => OwnPage(),
            "reports" => ReportsPage(),
            "settings" => SettingsPage(),
            _ => OverviewPage(),
        };
    }

    UIElement Loading()
    {
        var page = Page();
        page.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left });
        page.Children.Add(Secondary("Читаю состояние службы…"));
        return page;
    }

    // Overview: the state, one action where one is due, the update, the
    // services' status, the set in three lines, and the addresses another VPN
    // has to let past.
    UIElement OverviewPage()
    {
        var p = shown; var m = model;
        var page = Page();
        var head = new Grid { ColumnSpacing = 16 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel { Spacing = 4 };
        words.Children.Add(new TextBlock { Text = p.Heading, Style = Styled(p.Tone == Tone.Attention ? "StateHeadingAttention" : "StateHeading") });
        words.Children.Add(Secondary(m.Summary ?? p.Description));
        head.Children.Add(words);
        if (p.Connect || p.Disconnect)
        {
            var toggle = new ToggleSwitch { IsOn = current.Wanted, OnContent = "", OffContent = "", MinWidth = 0, VerticalAlignment = VerticalAlignment.Top, IsEnabled = !busy };
            AutomationProperties.SetName(toggle, "Подключение");
            toggle.Toggled += (_, _) => { if (toggle.IsOn != current.Wanted) _ = Command(toggle.IsOn ? "connect" : "disconnect"); };
            Grid.SetColumn(toggle, 1);
            head.Children.Add(toggle);
        }
        page.Children.Add(head);
        var action = MainAction();
        if (action != null) page.Children.Add(action);

        if (m.UpdateLine != null) page.Children.Add(UpdateBar(m));
        if (reports.Unread > 0)
        {
            var support = new InfoBar { Severity = InfoBarSeverity.Informational, IsClosable = false, IsOpen = true, Message = "Поддержка ответила на ваше обращение." };
            support.ActionButton = Plain("Открыть", () => Go(NavReports));
            page.Children.Add(support);
        }
        foreach (string note in p.Notes.Where(n => !n.StartsWith("Доступна версия", StringComparison.Ordinal) && !n.StartsWith("Выбор сервисов", StringComparison.Ordinal)))
            page.Children.Add(new InfoBar { Severity = InfoBarSeverity.Warning, IsClosable = false, IsOpen = true, Message = note });

        if (p.Registered)
        {
            page.Children.Add(StatusSection("Сервисы", m.Status));
            var set = Card();
            var rows = new StackPanel();
            rows.Children.Add(SetRow("Обязательные", m.SetRequired, () => Go(NavServices), true));
            rows.Children.Add(SetRow("По выбору", m.SetChosen, () => Go(NavServices), m.SetOwn != null));
            if (m.SetOwn != null) rows.Children.Add(SetRow("Свои сайты и адреса", m.SetOwn, () => Go(NavOwn), false));
            set.Child = rows;
            page.Children.Add(Label("Набор"));
            page.Children.Add(set);
            page.Children.Add(OtherVpn());
        }
        return page;
    }

    // The one action the state asks for, as the accent button; null when none.
    UIElement MainAction()
    {
        Button button = null;
        string after = null;
        switch (current.State)
        {
            case "enrollment_required": button = Accent("Зарегистрировать…", OnRegister); break;
            case "registration_error": button = Accent("Повторить", () => _ = Command("continue")); break;
            case "connection_error": button = Accent("Подключить снова", () => _ = Command("connect")); after = "повтор через 30 с"; break;
            case "needs_reset": button = Accent("Сбросить…", OnReset); break;
            case "service_stopped": button = Accent("Запустить службу", () => _ = StartService(false)); break;
            case "status_stale": button = Accent("Перезапустить службу", () => _ = StartService(true)); break;
            case "error" when current.ConnectionError == "enrollment_missing" || current.ConnectionError == "guard_changed": button = Accent("Сбросить…", OnReset); break;
        }
        if (button == null) return null;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(button);
        if (after != null) { var later = Secondary(after); later.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(later); }
        return row;
    }

    InfoBar UpdateBar(WindowModel m)
    {
        var bar = new InfoBar { IsOpen = true, IsClosable = false, Message = m.UpdateLine,
            Severity = m.UpdateFailed ? InfoBarSeverity.Error : InfoBarSeverity.Informational };
        if (m.UpdateAction != null)
            bar.ActionButton = Plain(m.UpdateAction, () => { if (m.UpdateAction == "Обновить") _ = Command("update_now"); else OnDownload(); });
        return bar;
    }

    // The status of a section: its name and a notch per service, a line, and
    // under it what is wrong on the left - in the colour of danger - or what
    // the section is, and on the right the state and the time of the check.
    UIElement StatusSection(string title, SectionStatus status)
    {
        var block = new StackPanel { Spacing = 6, Margin = new Thickness(0, 12, 0, 0) };
        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(new TextBlock { Text = title, Style = (Style)Res("SubtitleTextBlockStyle") });
        var notches = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3.5, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 4) };
        foreach (var notch in status.Notches ?? new Notch[0])
        {
            var mark = new Microsoft.UI.Xaml.Shapes.Rectangle { Style = Styled(notch.Failed ? "NotchFailed" : "Notch"), VerticalAlignment = VerticalAlignment.Bottom };
            ToolTipService.SetToolTip(mark, notch.Label + (notch.Failed ? ": не отвечает" : ""));
            AutomationProperties.SetName(mark, notch.Label + (notch.Failed ? ", не отвечает" : ", работает"));
            notches.Children.Add(mark);
        }
        Grid.SetColumn(notches, 1);
        top.Children.Add(notches);
        block.Children.Add(top);
        block.Children.Add(new Border { Style = Styled(status.Failed ? "DangerLine" : "Hairline") });
        var line = new Grid { ColumnSpacing = 12 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = Caption(status.Left);
        if (status.Failed) left.Style = Styled("DangerCaption");
        line.Children.Add(left);
        var right = Caption(status.Right);
        right.TextWrapping = TextWrapping.NoWrap;
        if (status.Stale) right.Style = Styled("WarningCaption");
        Grid.SetColumn(right, 1);
        line.Children.Add(right);
        block.Children.Add(line);
        return block;
    }

    UIElement SetRow(string title, string value, Action open, bool divider)
    {
        var button = RowButton();
        var grid = new Grid { ColumnSpacing = 12, MinHeight = 36 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = title, Style = (Style)Res("Emphasis") });
        words.Children.Add(Caption(value));
        grid.Children.Add(words);
        var chevron = new FontIcon { Glyph = "", FontSize = 12, Style = Styled("SecondaryIcon"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(chevron, 1);
        grid.Children.Add(chevron);
        button.Content = grid;
        AutomationProperties.SetName(button, title + ": " + value);
        button.Click += (_, _) => open();
        return Divided(button, divider);
    }

    // The addresses another VPN has to leave alone, folded on Overview.
    UIElement OtherVpn()
    {
        var list = new StackPanel { Spacing = 8 };
        list.Children.Add(Secondary("Добавьте их в исключения другого VPN, если он включён вместе с Waypoint."));
        for (int i = 0; i < ClientPresentation.AddressLabels.Length; i++)
        {
            string value = shown.Addresses[i];
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var name = Secondary(ClientPresentation.AddressLabels[i]);
            name.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(name);
            var text = new TextBlock { Text = value.Length == 0 ? "Нет данных" : value, IsTextSelectionEnabled = true, VerticalAlignment = VerticalAlignment.Center,
                FontFamily = new FontFamily("Consolas") };
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            var copy = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, IsEnabled = value.Length != 0 };
            ToolTipService.SetToolTip(copy, "Скопировать");
            AutomationProperties.SetName(copy, "Скопировать: " + ClientPresentation.AddressLabels[i]);
            copy.Click += (_, _) => { var package = new DataPackage(); package.SetText(value); Clipboard.SetContent(package); };
            Grid.SetColumn(copy, 2);
            row.Children.Add(copy);
            list.Children.Add(row);
        }
        return new Expander { Header = "Для другого VPN", Content = list, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 8, 0, 0) };
    }

    // Services: the status, the required ones, and the ones by choice with a
    // switch; each line says its rule without the tunnel and opens its details.
    UIElement ServicesPage()
    {
        var m = model;
        var page = Page();
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(PageTitle("Сервисы"));
        if (m.Offered.Length != 0 && m.Registered)
        {
            var add = new Button { Content = "Добавить", IsEnabled = !current.ChoicePending };
            add.Click += (_, _) => _ = AddService();
            Grid.SetColumn(add, 1);
            head.Children.Add(add);
        }
        page.Children.Add(head);
        if (!m.Registered || m.Required.Length + m.Chosen.Length + m.Offered.Length == 0)
        {
            page.Children.Add(Secondary(shown.ServicesLine));
            return page;
        }
        page.Children.Add(StatusSection("Обязательные", m.Status));
        page.Children.Add(ServiceList(m.Required));
        page.Children.Add(Label("По выбору · " + m.ChosenCount));
        if (m.Chosen.Length == 0) page.Children.Add(Secondary("Ничего не выбрано. «Добавить» — из выданных администратором."));
        else page.Children.Add(ServiceList(m.Chosen));
        if (current.ChoicePending) page.Children.Add(Secondary("Выбор применяется на сервере…"));
        return page;
    }

    UIElement ServiceList(ServiceLine[] lines)
    {
        var card = Card();
        var list = new StackPanel();
        for (int i = 0; i < lines.Length; i++) list.Children.Add(ServiceRow(lines[i], i < lines.Length - 1));
        card.Child = list;
        return card;
    }

    UIElement ServiceRow(ServiceLine line, bool divider)
    {
        var grid = new Grid { ColumnSpacing = 12, MinHeight = 52, Padding = new Thickness(8, 4, 12, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var details = RowButton();
        details.Padding = new Thickness(8, 6, 8, 6);
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(new TextBlock { Text = line.Label, Style = (Style)Res("Emphasis") });
        var note = Caption(line.Failed ? line.Problem : line.Rule);
        if (line.Failed) note.Style = Styled("DangerCaption");
        words.Children.Add(note);
        if (line.Failed) words.Children.Add(Caption(line.Rule));
        details.Content = words;
        AutomationProperties.SetName(details, line.Label + ", " + (line.Failed ? line.Problem + ", " : "") + line.Rule + ". Подробности");
        details.Click += (_, _) => Details(line, details);
        grid.Children.Add(details);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        if (line.Required) controls.Children.Add(Caption("всегда"));
        else
        {
            if (line.ChooseClosed)
            {
                var closed = new CheckBox { Content = "Закрывать без туннеля", IsChecked = line.Closed, IsEnabled = !current.ChoicePending, MinWidth = 0 };
                closed.Click += (_, _) => Choose(line.Id, null, closed.IsChecked == true);
                controls.Children.Add(closed);
            }
            var on = new ToggleSwitch { IsOn = line.On, OnContent = "", OffContent = "", MinWidth = 0, IsEnabled = !current.ChoicePending };
            AutomationProperties.SetName(on, line.Label + ", " + line.Rule);
            on.Toggled += (_, _) => { if (on.IsOn != line.On) Choose(line.Id, on.IsOn, null); };
            controls.Children.Add(on);
        }
        Grid.SetColumn(controls, 1);
        grid.Children.Add(controls);
        return Divided(grid, divider);
    }

    // The details of a service, at its line: why it fails, its rule, when it
    // was checked, and "check now".
    void Details(ServiceLine line, FrameworkElement at)
    {
        // A flyout does not inherit the theme the person chose for the window.
        var panel = new StackPanel { Spacing = 8, MaxWidth = 340, RequestedTheme = Root.ActualTheme };
        panel.Children.Add(new TextBlock { Text = line.Label, Style = (Style)Res("BodyStrongTextBlockStyle") });
        if (line.Failed) panel.Children.Add(new TextBlock { Text = line.Problem + ".", Style = Styled("DangerBody") });
        panel.Children.Add(Pair("Правило", (line.Required ? "обязательный" : "по выбору") + (line.Closed ? ", закрытый" : "")));
        panel.Children.Add(Pair("Без туннеля", line.RuleInFull));
        panel.Children.Add(Pair("Проверено", DateTime.Now.ToString("HH:mm")));
        var check = new Button { Content = "Проверить сейчас", IsEnabled = model.CanCheck };
        check.Click += (_, _) => _ = Command("check");
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(check);
        if (model.CheckLine.Length != 0) { var wait = Secondary(model.CheckLine); wait.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(wait); }
        panel.Children.Add(row);
        var report = new HyperlinkButton { Content = "Сообщить о проблеме…", Padding = new Thickness(0) };
        report.Click += (_, _) => OnReport();
        panel.Children.Add(report);
        new Flyout { Content = panel, Placement = FlyoutPlacementMode.Bottom }.ShowAt(at);
    }

    // "Add service": search among the services the administrator offered,
    // pick one, and its rule without the tunnel where that is the person's.
    async Task AddService()
    {
        ServiceLine picked = null;
        ServiceLine[] listed = model.Offered;
        var search = new AutoSuggestBox { PlaceholderText = "Найти сервис", QueryIcon = new SymbolIcon(Symbol.Find) };
        AutomationProperties.SetName(search, "Найти сервис");
        var found = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 280 };
        AutomationProperties.SetName(found, "Выданные сервисы");
        var count = Caption("");
        var rule = new RadioButtons { Header = "Без туннеля", SelectedIndex = 0, Visibility = Visibility.Collapsed };
        rule.Items.Add("Напрямую");
        rule.Items.Add("Закрыт");
        void Fill()
        {
            listed = WindowModel.Search(model.Offered, search.Text);
            found.ItemsSource = listed.Select(l => l.Label + " · " + l.Rule).ToList();
            count.Text = "Найдено " + listed.Length + " из " + model.Offered.Length + ".";
        }
        Fill();
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Добавить сервис", PrimaryButtonText = "Добавить", CloseButtonText = "Отмена",
            DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false, RequestedTheme = Root.ActualTheme };
        search.TextChanged += (_, args) => { if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput) Fill(); };
        found.SelectionChanged += (_, _) =>
        {
            picked = found.SelectedIndex >= 0 && found.SelectedIndex < listed.Length ? listed[found.SelectedIndex] : null;
            dialog.IsPrimaryButtonEnabled = picked != null;
            dialog.PrimaryButtonText = picked == null ? "Добавить" : "Добавить " + picked.Label;
            rule.Visibility = Shown(picked != null && picked.ChooseClosed);
            if (picked != null) rule.SelectedIndex = picked.Closed ? 1 : 0;
        };
        var body = new StackPanel { Spacing = 10, MinWidth = 380 };
        body.Children.Add(Secondary("Из " + model.Offered.Length + " " + WindowModel.Plural(model.Offered.Length, "выданного", "выданных", "выданных") + " администратором."));
        body.Children.Add(search);
        body.Children.Add(count);
        body.Children.Add(found);
        body.Children.Add(rule);
        dialog.Content = body;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || picked == null) return;
        Choose(picked.Id, true, picked.ChooseClosed ? rule.SelectedIndex == 1 : (bool?)null);
    }

    void Choose(string id, bool? on, bool? closed)
    {
        if (shown == null || shown.Choosing) return;
        ClientPresentation.Chosen(shown.Services, id, on, closed, out var chosenOn, out var chosenClosed);
        drawn = "";
        _ = Command("choose", chosenOn: chosenOn, chosenClosed: chosenClosed);
    }

    // Own sites and addresses: one field, checked here as the router checks
    // it, and the list with a way to take each away.
    UIElement OwnPage()
    {
        var page = Page();
        var own = current.Own;
        page.Children.Add(PageTitle("Свои сайты и адреса"));
        if (own == null) { page.Children.Add(Secondary("Администратор не разрешил добавлять свои адреса.")); return page; }
        page.Children.Add(Secondary("Идут через туннель только на этом компьютере. Администратор разрешил до " + own.Limit + " адресов на портах " +
            string.Join(" и ", own.Ports) + "."));
        int count = own.Domains.Length + own.Networks.Length;
        var field = new Grid { ColumnSpacing = 8 };
        field.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        field.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var input = new TextBox { PlaceholderText = "Сайт или IP-адрес", IsEnabled = count < own.Limit && !own.Pending };
        AutomationProperties.SetName(input, "Сайт или IP-адрес");
        var add = new Button { Content = "Добавить", IsEnabled = input.IsEnabled, Style = (Style)Res("AccentButtonStyle") };
        Grid.SetColumn(add, 1);
        field.Children.Add(input);
        field.Children.Add(add);
        page.Children.Add(field);
        var problem = Caption(shown.OwnProblem);
        problem.Style = Styled("DangerCaption");
        problem.Visibility = Shown(shown.OwnProblem.Length != 0);
        page.Children.Add(problem);
        void Add()
        {
            string value = WindowModel.OwnInput(input.Text, current, out string refusal);
            if (value == null) { problem.Text = refusal; problem.Visibility = Visibility.Visible; return; }
            input.Text = "";
            SendOwn(value, null);
        }
        add.Click += (_, _) => Add();
        input.KeyDown += (_, args) => { if (args.Key == Windows.System.VirtualKey.Enter) Add(); };
        if (count > 0)
        {
            var card = Card();
            var list = new StackPanel();
            var items = own.Domains.Select(d => (shown: d, kind: "с поддоменами", sent: d))
                .Concat(own.Networks.Select(n => (shown: n.EndsWith("/32", StringComparison.Ordinal) ? n[..^3] : n, kind: n.EndsWith("/32", StringComparison.Ordinal) ? "адрес" : "сеть", sent: n))).ToList();
            for (int i = 0; i < items.Count; i++)
            {
                var item = items[i];
                var row = new Grid { ColumnSpacing = 8, MinHeight = 44, Padding = new Thickness(16, 4, 8, 4) };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var words = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
                words.Children.Add(new TextBlock { Text = item.shown, IsTextSelectionEnabled = true });
                var kind = Caption(item.kind);
                kind.VerticalAlignment = VerticalAlignment.Center;
                words.Children.Add(kind);
                row.Children.Add(words);
                var remove = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, IsEnabled = !own.Pending };
                ToolTipService.SetToolTip(remove, "Убрать");
                AutomationProperties.SetName(remove, "Убрать " + item.shown);
                remove.Click += (_, _) => SendOwn(null, item.sent);
                Grid.SetColumn(remove, 1);
                row.Children.Add(remove);
                list.Children.Add(Divided(row, i < items.Count - 1));
            }
            card.Child = list;
            page.Children.Add(card);
        }
        page.Children.Add(Caption(count + " из " + own.Limit + ". При " + own.Limit + " поле станет недоступно, пока не уберёте один из адресов. Без туннеля — напрямую." +
            (own.Pending ? " Список отправляется на сервер." : "")));
        return page;
    }

    void SendOwn(string add, string remove)
    {
        if (!ClientPresentation.OwnChanged(current, add, remove, out var domains, out var networks)) return;
        drawn = "";
        _ = Command("own", domains: domains, networks: networks);
    }

    // Reports: the person's and the automatic ones in one list; a new one,
    // and a conversation, in the report dialog.
    UIElement ReportsPage()
    {
        var page = Page();
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(PageTitle("Обращения"));
        var fresh = new Button { Content = "Новое обращение", Style = (Style)Res("AccentButtonStyle") };
        fresh.Click += (_, _) => OnReport();
        Grid.SetColumn(fresh, 1);
        head.Children.Add(fresh);
        page.Children.Add(head);
        if (reports.All.Count == 0) { page.Children.Add(Secondary("Обращений пока нет.")); return page; }
        var card = Card();
        var list = new StackPanel();
        for (int i = 0; i < reports.All.Count; i++)
        {
            var report = reports.All[i];
            int unread = reports.UnreadOf(report);
            var button = RowButton();
            var words = new StackPanel { Spacing = 2 };
            words.Children.Add(new TextBlock { Text = report.Title.Length == 0 ? ReportKinds.Label(report.Kind) : report.Title, Style = (Style)Res("Emphasis"), TextTrimming = TextTrimming.CharacterEllipsis });
            words.Children.Add(Caption(ReportKinds.Label(report.Kind) + " · " + report.SentAt.ToLocalTime().ToString("d MMM") +
                (unread == 0 ? "" : " · " + unread + " " + WindowModel.Plural(unread, "новый ответ", "новых ответа", "новых ответов"))));
            button.Content = words;
            button.Click += (_, _) => _ = new ReportDialog(this, reports, StateReport(), current.State, true).ShowAsync();
            list.Children.Add(Divided(button, i < reports.All.Count - 1));
        }
        card.Child = list;
        page.Children.Add(card);
        return page;
    }

    // Settings, the same on Windows and macOS, in this order: sign-in,
    // theme, updates, failure reports, names in browsers, reset.
    UIElement SettingsPage()
    {
        var page = Page();
        page.Children.Add(PageTitle("Параметры"));
        var card = Card();
        var list = new StackPanel();
        var signIn = Switch("Открывать при входе в Windows", Program.StartAtSignIn);
        signIn.Toggled += (_, _) => Program.StartAtSignIn = signIn.IsOn;
        list.Children.Add(Setting("Открывать при входе в Windows", "Значок появится в трее сам.", signIn, true));

        var themes = new ComboBox { SelectedIndex = -1, MinWidth = 160 };
        themes.Items.Add("Как в системе");
        themes.Items.Add("Светлая");
        themes.Items.Add("Тёмная");
        themes.SelectedIndex = theme == "light" ? 1 : theme == "dark" ? 2 : 0;
        AutomationProperties.SetName(themes, "Тема");
        themes.SelectionChanged += (_, _) => SetTheme(themes.SelectedIndex == 1 ? "light" : themes.SelectedIndex == 2 ? "dark" : "system");
        list.Children.Add(Setting("Тема", null, themes, true));

        var updates = Switch("Ставить обновления сами", current.Update?.Auto ?? true);
        updates.Toggled += (_, _) => _ = Command(updates.IsOn ? "updates_auto_on" : "updates_auto_off");
        list.Children.Add(Setting("Ставить обновления сами", "Когда туннель не нужен: ночью или при выходе из Waypoint. Только файл, проверенный ключом проекта.", updates, true));

        var send = Switch("Отправлять отчёты о сбоях автоматически", Consent() == true);
        send.Toggled += (_, _) => _ = Command(send.IsOn ? "reports_send" : "reports_skip");
        var reportsText = new StackPanel { Spacing = 2 };
        reportsText.Children.Add(Caption("Коды ошибок, версии и журнал сбоев. Адреса, имена сайтов и сетей остаются на этом компьютере."));
        reportsText.Children.Add(WhatIsSentLink());
        list.Children.Add(Setting("Отправлять отчёты о сбоях автоматически", reportsText, send, true));

        var browsers = Plain(BrowserNames.Told() ? "Вернуть…" : "Задать…", OnBrowsers);
        list.Children.Add(Setting("DNS в браузерах", "Edge и Chrome спрашивают имена сами, в обход туннеля. Waypoint может задать им системный DNS.", browsers, true));

        var reset = Plain("Сбросить…", OnReset);
        list.Children.Add(Setting("Сбросить Waypoint на этом компьютере", "Удалит профиль VPN, блокировку, имена сервисов и регистрацию; скажет, что удалено.", reset, false));
        card.Child = list;
        page.Children.Add(card);
        page.Children.Add(Caption("Waypoint " + Own.Major + "." + Own.Minor + "." + Math.Max(Own.Build, 0) + " · " +
            System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant()));
        return page;
    }

    static bool? Consent()
    {
        try { return new FailureQueue("IKEv2ManagerClient").Consent; }
        catch (Exception) { return null; }
    }

    UIElement Setting(string title, object detail, FrameworkElement control, bool divider)
    {
        var grid = new Grid { ColumnSpacing = 16, MinHeight = 56, Padding = new Thickness(16, 10, 16, 10) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
        if (detail is string text) words.Children.Add(Caption(text));
        else if (detail is UIElement element) words.Children.Add(element);
        grid.Children.Add(words);
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return Divided(grid, divider);
    }

    HyperlinkButton WhatIsSentLink()
    {
        var what = new HyperlinkButton { Content = "Что уходит", Padding = new Thickness(0) };
        what.Click += (_, _) => _ = WhatIsSent();
        return what;
    }

    // What an automatic report carries, shown whole: the one waiting, or an example.
    async Task WhatIsSent()
    {
        Dictionary<string, object> entry;
        try { entry = new FailureQueue("IKEv2ManagerClient").Pending().LastOrDefault(); } catch (Exception) { entry = null; }
        entry ??= new Dictionary<string, object> { { "code", "tick_stalled" }, { "phase", "tick" }, { "version", FailureQueue.Version() },
            { "first", FailureQueue.Stamp(DateTime.UtcNow) }, { "last", FailureQueue.Stamp(DateTime.UtcNow) }, { "count", 1 },
            { "detail", "a step ran longer than 180 s; the service restarts" }, { "faults", new object[0] } };
        string body = FailureReporter.Body(entry, "случайный ID устройства", entry["code"] + "|" + entry["phase"] + "|" + entry["version"]);
        var serializer = new JavaScriptSerializer();
        var fields = serializer.Deserialize<Dictionary<string, object>>(body);
        string text = "{\r\n" + string.Join(",\r\n", fields.Select(pair => "  " + serializer.Serialize(pair.Key) + ": " + serializer.Serialize(pair.Value))) + "\r\n}";
        await new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Что уходит в отчёте о сбое", CloseButtonText = "Закрыть", RequestedTheme = Root.ActualTheme,
            Content = new ScrollViewer { MaxHeight = 420, Content = new TextBlock { Text = text, FontFamily = new FontFamily("Consolas"), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } } }.ShowAsync();
    }

    // First run, after the registration and once after an update from an
    // earlier release: three decisions, and "Done" only after the answer
    // about reports, which is one for the device.
    bool ShowWelcome()
    {
        bool registered = loaded && shown != null && shown.Registered;
        bool answered;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(Program.SettingsKey);
            answered = key?.GetValue("Welcomed") is int value && value == 1;
        }
        catch (Exception) { answered = true; }
        bool due = registered && !welcomeDone && !answered;
        Welcome.Visibility = Shown(due);
        Nav.Visibility = Shown(!due);
        if (!due || WelcomeBody.Content != null) return due;
        bool? consent = Consent();
        var page = Page();
        page.Children.Add(new TextBlock { Text = "Почти готово", FontSize = 28, FontWeight = Microsoft.UI.Text.FontWeights.Light });
        page.Children.Add(Secondary("Waypoint зарегистрирован на этом компьютере. Всё это меняется в Параметрах."));
        var card = Card();
        var list = new StackPanel();
        var signIn = Switch("Открывать при входе в Windows", true);
        list.Children.Add(Setting("Открывать при входе в Windows", "Значок появится в трее сам.", signIn, true));
        var updates = Switch("Ставить обновления сами", true);
        list.Children.Add(Setting("Ставить обновления сами", "Когда туннель не нужен; только проверенный файл.", updates, consent == null));
        RadioButtons choice = null;
        if (consent == null)
        {
            choice = new RadioButtons { SelectedIndex = -1 };
            choice.Items.Add("Отправлять разработчику автоматически");
            choice.Items.Add("Не отправлять");
            AutomationProperties.SetName(choice, "Отчёты о сбоях");
            var block = new StackPanel { Spacing = 6, Padding = new Thickness(16, 10, 16, 12) };
            block.Children.Add(new TextBlock { Text = "Отчёты о сбоях" });
            block.Children.Add(Caption("Коды ошибок, версии и журнал сбоев. Адреса, имена сайтов и сетей остаются на этом компьютере."));
            block.Children.Add(WhatIsSentLink());
            block.Children.Add(choice);
            list.Children.Add(block);
        }
        card.Child = list;
        page.Children.Add(card);
        var done = new Button { Content = "Готово", Style = (Style)Res("AccentButtonStyle"), IsEnabled = choice == null, MinWidth = 120 };
        var hint = Caption(choice == null ? "" : "после ответа про отчёты");
        hint.VerticalAlignment = VerticalAlignment.Center;
        if (choice != null) choice.SelectionChanged += (_, _) => { done.IsEnabled = choice.SelectedIndex >= 0; hint.Visibility = Shown(!done.IsEnabled); };
        done.Click += async (_, _) =>
        {
            Program.StartAtSignIn = signIn.IsOn;
            await Command(updates.IsOn ? "updates_auto_on" : "updates_auto_off");
            if (choice != null) await Command(choice.SelectedIndex == 0 ? "reports_send" : "reports_skip");
            try { using var key = Registry.CurrentUser.CreateSubKey(Program.SettingsKey); key.SetValue("Welcomed", 1, RegistryValueKind.DWord); } catch (Exception) { }
            welcomeDone = true;
            WelcomeBody.Content = null;
            drawn = "";
            Draw();
            TrayTip.IsOpen = true;
        };
        var foot = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        foot.Children.Add(done);
        foot.Children.Add(hint);
        page.Children.Add(foot);
        WelcomeBody.Content = page;
        return true;
    }

    // ---- Pieces -----------------------------------------------------------

    static object Res(string key) => Application.Current.Resources[key];
    static StackPanel Page() => new() { Spacing = 12 };
    static TextBlock PageTitle(string text) => new() { Text = text, Style = (Style)Res("TitleTextBlockStyle") };
    static TextBlock Label(string text) => new() { Text = text, Style = (Style)Res("SectionLabel"), Margin = new Thickness(0, 12, 0, 0) };
    static TextBlock Secondary(string text) => new() { Text = text ?? "", Style = (Style)Res("SecondaryBody") };
    static TextBlock Caption(string text) => new() { Text = text ?? "", Style = (Style)Res("SecondaryCaption") };
    static Style Styled(string key) => (Style)Res(key);
    static Border Card() => new() { Style = (Style)Res("ListCard") };
    static Visibility Shown(bool shown) => shown ? Visibility.Visible : Visibility.Collapsed;

    static ToggleSwitch Switch(string name, bool on)
    {
        var toggle = new ToggleSwitch { IsOn = on, OnContent = "", OffContent = "", MinWidth = 0 };
        AutomationProperties.SetName(toggle, name);
        return toggle;
    }

    // A whole row that opens something: flat, the width of the card.
    static Button RowButton() => new()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
        Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(16, 10, 12, 10),
    };

    static UIElement Pair(string name, string value)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(Caption(name));
        var text = new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    // A row of a list card stands on a hairline, not in a card of its own.
    static UIElement Divided(UIElement row, bool divider)
    {
        if (!divider) return row;
        var stack = new StackPanel();
        stack.Children.Add(row);
        stack.Children.Add(new Border { Style = Styled("Hairline"), Margin = new Thickness(16, 0, 0, 0) });
        return stack;
    }

    static Button Accent(string text, Action click)
    {
        var button = new Button { Content = text, Style = (Style)Res("AccentButtonStyle") };
        button.Click += (_, _) => click();
        return button;
    }

    static Button Plain(string text, Action click)
    {
        var button = new Button { Content = text };
        button.Click += (_, _) => click();
        return button;
    }

    // The state's colour from the theme in force. The norm is said in ink;
    // colour only when something is off or under way.
    Brush ToneBrush(Tone tone)
    {
        string key = tone == Tone.Working ? "ToneWorking" : "ToneAttention";
        var themes = (ResourceDictionary)Application.Current.Resources.ThemeDictionaries[Root.ActualTheme == ElementTheme.Dark ? "Dark" : "Light"];
        return new SolidColorBrush((Color)themes[key]);
    }

    static string Glyph(Tone tone) => tone switch
    {
        Tone.Open => "", Tone.Working => "", Tone.Attention => "", _ => "",
    };

    // ---- Commands ---------------------------------------------------------

    void OnTrayChoice(string action)
    {
        switch (action)
        {
            case "open": ShowWindow(); break;
            case "quit": Quit(); break;
            case "connect": case "disconnect": _ = Command(action); break;
            case "update": if (model?.UpdateAction == "Обновить") _ = Command("update_now"); else OnDownload(); break;
            default:
                if (action != null && action.StartsWith("service:", StringComparison.Ordinal))
                {
                    string id = action.Substring(8);
                    var row = shown?.Services.FirstOrDefault(s => s.Id == id);
                    if (row != null) Choose(id, !row.On, null);
                }
                break;
        }
    }

    async Task Command(string operation, string endpoint = null, string invitation = null, string[] chosenOn = null, string[] chosenClosed = null,
        string[] domains = null, string[] networks = null)
    {
        if (busy) return;
        busy = true;
        try
        {
            string result = await Task.Run(() => ClientCommands.Send(operation, endpoint, invitation, on: chosenOn, closed: chosenClosed,
                domains: domains, networks: networks));
            if (result == "accepted" && operation == "begin")
                await Task.Run(() => ClientCommands.Send("continue"));
            else if (result != "accepted" && result != "busy" && operation != "check")
                await Say(operation == "choose" ? "Сервисы" : operation == "own" ? "Свои сайты и адреса" : "Waypoint",
                    result == "administrator_required" ? "Требуются права администратора." :
                    operation == "choose" ? "Этот выбор сейчас недоступен: набор изменился. Посмотрите на список ещё раз." :
                    operation == "own" ? "Список не принят: проверьте, что это сайт или публичный адрес и что предел не превышен." : "Действие отклонено.");
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

    // A stopped service is started; the service control manager does it at
    // the request of the service's own binary.
    async Task StartService(bool restart)
    {
        int? code = await Elevated("--start", TimeSpan.FromSeconds(60));
        if (code == null) await Say("Служба", "Нужны права администратора.");
        else if (code != 0) await Say("Служба", (restart ? "Служба не перезапустилась." : "Служба не запустилась.") + " Отправьте отчёт: в нём будет причина.");
        Refresh();
    }

    async void OnRegister()
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
                quitting = true;
                Close();
            }
            catch (System.ComponentModel.Win32Exception) { await Say("Регистрация", "Для регистрации нужны права администратора."); }
            return;
        }
        var input = new PasswordBox { PlaceholderText = "https://…" };
        AutomationProperties.SetName(input, "Ссылка приглашения");
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

    // Without a key to check it, or after a failed check: the release page.
    async void OnDownload()
    {
        string version = current.Update != null && current.Update.Version.Length != 0 ? current.Update.Version : current.Release;
        if (!ClientView.Newer(version, Own)) return;
        try { Process.Start(new ProcessStartInfo(Downloads + version + "/WaypointSetup.exe") { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { await Say("Обновление", "Не удалось открыть браузер."); }
    }

    async void OnBrowsers()
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
        drawn = "";
        Refresh();
    }

    // The reset always comes to an end and says what it took away; what it
    // could not, with one way on: repeat it.
    async void OnReset()
    {
        if (!await Ask("Сброс Waypoint", "Сбросить Waypoint на этом компьютере?\n\nБудут удалены: VPN-подключение, блокировки, DNS-записи сервисов, политики браузеров и регистрация устройства. " +
            "Программа останется; чтобы вернуть доступ, понадобится новая ссылка от администратора.", "Сбросить")) return;
        // As long as the reset may take: up to a minute for the service to
        // stop, then ending it, the removal and the start again.
        int? code = await Elevated("--reset", TimeSpan.FromSeconds(300));
        if (code == null) { await Say("Сброс Waypoint", "Сброс не запущен: нужны права администратора."); return; }
        RemovalResult result = null;
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Waypoint");
            result = RemovalResult.Parse(key?.GetValue("LastReset") as string);
        }
        catch (Exception) { }
        string text = code == -1 ? "Сброс ещё идёт. Подождите минуту." : WindowModel.ResetSummary(result);
        drawn = "";
        if (code != 0 && code != -1 && result != null && !result.Complete)
        {
            if (await Ask("Сброс Waypoint", text, "Повторить")) { OnReset(); return; }
        }
        else await Say("Сброс Waypoint", text);
        Refresh();
    }

    void OnReport() => _ = new ReportDialog(this, reports, StateReport(), current.State, false).ShowAsync();

    // The state report, one field to a line, as the person sees and sends it.
    string StateReport()
    {
        var serializer = new JavaScriptSerializer();
        var fields = serializer.Deserialize<Dictionary<string, object>>(current.Report());
        return "{\r\n" + string.Join(",\r\n", fields.Select(pair => "  " + serializer.Serialize(pair.Key) + ": " + serializer.Serialize(pair.Value))) + "\r\n}";
    }

    // ---- Look -------------------------------------------------------------

    void SetTheme(string chosen)
    {
        theme = chosen;
        try { using var key = Registry.CurrentUser.CreateSubKey(Program.SettingsKey); key.SetValue("Theme", theme); }
        catch (UnauthorizedAccessException) { }
        ApplyTheme();
    }

    void ApplyTheme()
    {
        Root.RequestedTheme = theme == "light" ? ElementTheme.Light : theme == "dark" ? ElementTheme.Dark : ElementTheme.Default;
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
