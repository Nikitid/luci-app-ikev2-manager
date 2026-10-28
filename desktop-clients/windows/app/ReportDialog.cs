using System.Text;
using IkeV2Manager.Client;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Waypoint;

// Reports to the developer, in two parts. A new one: the state report, what
// is in it shown first, saved where the person says; the kind of the report,
// the person's words, an address for a reply if they give one, pictures
// pasted with Ctrl+V or picked from files, and the state report if they tick
// it. And the reports sent from here, each with its conversation with support
// and a field to answer.
sealed class ReportDialog
{
    // The service takes PNG and JPEG; five of up to 5 MB each.
    const int MaxPictures = 5, MaxPicture = 5 * 1024 * 1024;

    readonly MainWindow owner;
    readonly Reports reports;
    readonly string json, state;
    readonly bool startOnMine;
    readonly List<byte[]> pictures = new();
    readonly StackPanel shots = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    readonly TextBlock result = new() { TextWrapping = TextWrapping.Wrap };
    readonly ContentControl page = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    SelectorBarItem mineItem;
    UIElement fresh;

    public ReportDialog(MainWindow owner, Reports reports, string json, string state, bool startOnMine)
    {
        this.owner = owner;
        this.reports = reports;
        this.json = json;
        this.state = state;
        this.startOnMine = startOnMine;
    }

    static Style Resource(string name) => (Style)Application.Current.Resources[name];
    static Brush Soft => (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];

    public async Task ShowAsync()
    {
        var root = (FrameworkElement)owner.Content;
        fresh = NewReport();
        var newItem = new SelectorBarItem { Text = "Новое обращение" };
        mineItem = new SelectorBarItem { Text = MineTitle() };
        var bar = new SelectorBar { Items = { newItem, mineItem } };
        bar.SelectionChanged += (_, _) =>
        {
            if (bar.SelectedItem == mineItem) { page.Content = List(); reports.LookAround(Refreshed); }
            else page.Content = fresh;
        };
        bar.SelectedItem = startOnMine ? mineItem : newItem;
        page.Content = startOnMine ? List() : fresh;
        if (startOnMine) reports.LookAround(Refreshed);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Отчёт", CloseButtonText = "Закрыть", RequestedTheme = root.ActualTheme,
            Content = new StackPanel { Width = 640, Spacing = 10, Children = { bar, new ScrollViewer { Content = page, MaxHeight = 600 } } } };
        dialog.Resources["ContentDialogMaxWidth"] = 720.0;
        await dialog.ShowAsync();
    }

    string MineTitle() => reports.Unread > 0 ? "Мои обращения (" + reports.Unread + ")" : "Мои обращения";

    // The service answered: the list or the open conversation shows it.
    void Refreshed()
    {
        mineItem.Text = MineTitle();
        if (page.Content is FrameworkElement shown && shown.Tag is SentReport open) page.Content = Conversation(open);
        else if (page.Content != fresh) page.Content = List();
    }

    UIElement NewReport()
    {
        var report = new TextBox { Text = json, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
            FontFamily = new FontFamily("Consolas"), Height = 200 };
        ScrollViewer.SetHorizontalScrollBarVisibility(report, ScrollBarVisibility.Auto);
        var save = new Button { Content = "Сохранить…" };
        save.Click += async (_, _) => await Save();

        var kind = new ComboBox { MinWidth = 160 };
        foreach (var pair in ReportKinds.All) kind.Items.Add(new ComboBoxItem { Content = pair[1], Tag = pair[0] });
        kind.SelectedIndex = 0;
        var description = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 90, PlaceholderText = "Что случилось, что предлагаете или о чём спрашиваете" };
        description.Paste += async (_, args) => { if (await PastePicture()) args.Handled = true; };
        var contact = new TextBox { PlaceholderText = "name@example.com" };
        var attach = new CheckBox { Content = "Приложить отчёт выше", IsChecked = true };
        var add = new Button { Content = "Добавить картинку…" };
        add.Click += async (_, _) => await PickPicture();
        var send = new Button { Content = "Отправить", Style = Resource("AccentButtonStyle") };
        send.Click += async (_, _) =>
        {
            string words = description.Text.Trim(), address = contact.Text.Trim();
            if (words.Length == 0) { result.Text = "Сначала напишите, о чём обращение."; return; }
            if (address.Length > 0 && !System.Text.RegularExpressions.Regex.IsMatch(address, "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]+$"))
            { result.Text = "Введите адрес вида name@example.com или оставьте поле пустым."; return; }
            var own = typeof(ReportDialog).Assembly.GetName().Version;
            var context = new Dictionary<string, string> {
                { "app_version", own.Major + "." + own.Minor + "." + Math.Max(own.Build, 0) },
                { "os_version", BrowserNames.WindowsVersion() },
                { "architecture", System.Runtime.InteropServices.RuntimeInformation.OSArchitecture.ToString() },
                { "language", System.Globalization.CultureInfo.CurrentUICulture.Name },
                { "failure_code", state ?? "" } };
            var files = new List<ReportFile>();
            for (int i = 0; i < pictures.Count; i++)
            {
                bool jpeg = pictures[i][0] == 0xff;
                files.Add(new ReportFile("picture-" + (i + 1) + (jpeg ? ".jpg" : ".png"), jpeg ? "image/jpeg" : "image/png", pictures[i]));
            }
            if (attach.IsChecked == true) files.Add(new ReportFile("waypoint-state.json", "application/json", new UTF8Encoding(false).GetBytes(json)));
            string chosen = (string)((ComboBoxItem)kind.SelectedItem).Tag;
            send.IsEnabled = false;
            result.Text = "Отправка…";
            try
            {
                var sent = await Task.Run(() => new ProblemReporter().Send(words, chosen, ReporterIdentity.Id(), address, context, files));
                reports.Keep(sent);
                result.Text = "Отправлено. Ответ поддержки появится во вкладке «Мои обращения».";
                description.Text = ""; contact.Text = ""; pictures.Clear(); DrawShots();
            }
            catch (Exception error) { result.Text = Reports.Words(error); }
            send.IsEnabled = true;
        };

        return new StackPanel { Spacing = 10, Children = {
            report, save,
            new TextBlock { Text = "Написать разработчику", Style = Resource("Emphasis"), Margin = new Thickness(0, 8, 0, 0) },
            kind,
            description,
            new TextBlock { Text = "Скриншот можно вставить через Ctrl+V в поле выше.", Style = Resource("CaptionTextBlockStyle"), Foreground = Soft },
            new ScrollViewer { Content = shots, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled },
            new StackPanel { Spacing = 4, Children = { new TextBlock { Text = "Почта для ответа (необязательно)" }, contact } },
            new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { attach, add, send } },
            result } };
    }

    // The reports sent from here, newest first; one opens its conversation.
    UIElement List()
    {
        var list = new StackPanel { Spacing = 4 };
        if (reports.All.Count == 0)
            list.Children.Add(new TextBlock { Text = "Отсюда ещё ничего не отправляли.", Foreground = Soft, Margin = new Thickness(0, 12, 0, 12) });
        foreach (var report in reports.All)
        {
            var conversation = reports.Conversation(report);
            int unread = reports.UnreadOf(report);
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new StackPanel { Children = {
                new TextBlock { Text = report.Title.Length == 0 ? ReportKinds.Label(report.Kind) : report.Title, TextTrimming = TextTrimming.CharacterEllipsis },
                new TextBlock { Text = ReportKinds.Label(report.Kind) + " · " + report.SentAt.ToLocalTime().ToString("d MMM yyyy") +
                    (conversation == null ? "" : " · " + conversation.StateLabel), Style = Resource("CaptionTextBlockStyle"), Foreground = Soft } } });
            if (unread > 0)
            {
                var badge = new InfoBadge { Value = unread, VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(badge, 1);
                row.Children.Add(badge);
            }
            var open = new Button { Content = row, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            open.Click += (_, _) => { result.Text = ""; page.Content = Conversation(report); };
            list.Children.Add(open);
        }
        return list;
    }

    // One report: what was said, and a field to answer support.
    UIElement Conversation(SentReport report)
    {
        reports.MarkRead(report);
        mineItem.Text = MineTitle();
        var conversation = reports.Conversation(report);
        var back = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 } };
        ToolTipService.SetToolTip(back, "К списку");
        back.Click += (_, _) => page.Content = List();
        var header = new Grid { ColumnSpacing = 10 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(back);
        var title = new TextBlock { Text = ReportKinds.Label(report.Kind) + " · " + report.Title, Style = Resource("Emphasis"),
            TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(title, 1);
        header.Children.Add(title);
        var standing = new TextBlock { Text = conversation?.StateLabel ?? "", Foreground = Soft, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(standing, 2);
        header.Children.Add(standing);

        var messages = new StackPanel { Spacing = 8 };
        var replies = conversation?.Replies ?? new List<ReportReply>();
        if (replies.Count == 0) messages.Children.Add(new TextBlock { Text = conversation == null ? "Загрузка…" : "Ответов пока нет.", Foreground = Soft });
        foreach (var reply in replies)
        {
            bool support = reply.From == "support";
            messages.Children.Add(new Border {
                HorizontalAlignment = support ? HorizontalAlignment.Left : HorizontalAlignment.Right, MaxWidth = 500,
                Padding = new Thickness(10, 8, 10, 8), CornerRadius = new CornerRadius(8),
                Background = (Brush)Application.Current.Resources[support ? "CardBackgroundFillColorSecondaryBrush" : "AccentFillColorTertiaryBrush"],
                Child = new StackPanel { Spacing = 2, Children = {
                    new TextBlock { Text = support ? "Поддержка" : "Вы", Style = Resource("CaptionTextBlockStyle"), Foreground = Soft },
                    new TextBlock { Text = reply.Body, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
                    new TextBlock { Text = reply.CreatedAt?.ToLocalTime().ToString("d MMM yyyy, HH:mm") ?? "", Style = Resource("CaptionTextBlockStyle"), Foreground = Soft } } } });
        }
        var answer = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 70, PlaceholderText = "Ответ поддержке", MaxLength = 5000 };
        var respond = new Button { Content = "Ответить", Style = Resource("AccentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Right };
        respond.Click += async (_, _) =>
        {
            string text = answer.Text.Trim();
            if (text.Length == 0) { result.Text = "Сначала напишите ответ."; return; }
            respond.IsEnabled = false;
            result.Text = "Отправка…";
            try
            {
                await Task.Run(() => new ProblemReporter().Reply(report, text));
                result.Text = "";
                await reports.LookAt(report);
                page.Content = Conversation(report);
            }
            catch (Exception error) { result.Text = Reports.Words(error); respond.IsEnabled = true; }
        };
        return new StackPanel { Spacing = 10, Tag = report, Children = { header,
            new ScrollViewer { Content = messages, MaxHeight = 320 }, answer, respond, result } };
    }

    async Task Save()
    {
        var picker = new FileSavePicker { SuggestedFileName = "ikev2-client-report" };
        picker.FileTypeChoices.Add("JSON", new List<string> { ".json" });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
        var file = await picker.PickSaveFileAsync();
        if (file == null) return;
        try { await FileIO.WriteBytesAsync(file, new UTF8Encoding(false).GetBytes(json)); result.Text = "Отчёт сохранён."; }
        catch (Exception) { result.Text = "Не удалось сохранить отчёт."; }
    }

    async Task<bool> PastePicture()
    {
        var clipboard = Clipboard.GetContent();
        if (!clipboard.Contains(StandardDataFormats.Bitmap)) return false;
        using var stream = await (await clipboard.GetBitmapAsync()).OpenReadAsync();
        // Pasted pictures come as bitmaps; they travel as PNG.
        var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
        using var png = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateForTranscodingAsync(png, decoder);
        await encoder.FlushAsync();
        var bytes = new byte[png.Size];
        using (var reader = new Windows.Storage.Streams.DataReader(png.GetInputStreamAt(0)))
        {
            await reader.LoadAsync((uint)png.Size);
            reader.ReadBytes(bytes);
        }
        AddPicture(bytes);
        return true;
    }

    async Task PickPicture()
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".png");
        picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".jpeg");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
        var file = await picker.PickSingleFileAsync();
        if (file == null) return;
        try
        {
            var properties = await file.GetBasicPropertiesAsync();
            if (properties.Size > MaxPicture) { result.Text = "Картинку больше 5 МБ приложить нельзя."; return; }
            AddPicture(File.ReadAllBytes(file.Path));
        }
        catch (IOException) { result.Text = "Файл не удалось прочитать."; }
        catch (UnauthorizedAccessException) { result.Text = "Нет доступа к файлу."; }
    }

    void AddPicture(byte[] data)
    {
        bool png = data.Length > 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4e && data[3] == 0x47;
        bool jpeg = data.Length > 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff;
        if (!png && !jpeg) { result.Text = "Приложить можно только картинки PNG и JPEG."; return; }
        if (pictures.Count >= MaxPictures) { result.Text = "Можно приложить не больше пяти картинок."; return; }
        if (data.Length > MaxPicture) { result.Text = "Картинку больше 5 МБ приложить нельзя."; return; }
        result.Text = "";
        pictures.Add(data);
        DrawShots();
    }

    void DrawShots()
    {
        shots.Children.Clear();
        for (int i = 0; i < pictures.Count; i++)
        {
            int index = i;
            var image = new BitmapImage();
            using (var stream = new MemoryStream(pictures[i])) image.SetSource(stream.AsRandomAccessStream());
            var remove = new Button { Content = "×", Padding = new Thickness(6, 0, 6, 2), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
            remove.Click += (_, _) => { pictures.RemoveAt(index); DrawShots(); };
            shots.Children.Add(new Grid { Width = 96, Height = 64, Children = { new Image { Source = image, Stretch = Stretch.UniformToFill }, remove } });
        }
    }
}
