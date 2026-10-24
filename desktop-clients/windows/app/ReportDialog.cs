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

// The state report, what is in it shown first, saved where the person says;
// and a problem report to the developer: the person's words, an address for a
// reply if they give one, pictures pasted with Ctrl+V or picked from files,
// and the state report if they tick it.
sealed class ReportDialog
{
    // The service takes PNG and JPEG; five of up to 5 MB each.
    const int MaxPictures = 5, MaxPicture = 5 * 1024 * 1024;

    readonly MainWindow owner;
    readonly string json, state;
    readonly List<byte[]> pictures = new();
    readonly StackPanel shots = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    readonly TextBlock result = new() { TextWrapping = TextWrapping.Wrap };

    public ReportDialog(MainWindow owner, string json, string state)
    {
        this.owner = owner;
        this.json = json;
        this.state = state;
    }

    public async Task ShowAsync()
    {
        var root = (FrameworkElement)owner.Content;
        var report = new TextBox { Text = json, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
            FontFamily = new FontFamily("Consolas"), Height = 220 };
        ScrollViewer.SetHorizontalScrollBarVisibility(report, ScrollBarVisibility.Auto);
        var save = new Button { Content = "Сохранить…" };
        save.Click += async (_, _) => await Save();

        var description = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 90, PlaceholderText = "Что случилось" };
        description.Paste += async (_, args) => { if (await PastePicture()) args.Handled = true; };
        var contact = new TextBox { PlaceholderText = "name@example.com" };
        var attach = new CheckBox { Content = "Приложить отчёт выше", IsChecked = true };
        var add = new Button { Content = "Добавить картинку…" };
        add.Click += async (_, _) => await PickPicture();
        var send = new Button { Content = "Отправить", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        send.Click += async (_, _) =>
        {
            string words = description.Text.Trim(), address = contact.Text.Trim();
            if (words.Length == 0) { result.Text = "Сначала опишите проблему."; return; }
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
            send.IsEnabled = false;
            result.Text = "Отправка…";
            string outcome;
            bool done = false;
            try
            {
                await Task.Run(() => new ProblemReporter().Send(words, address, context, files));
                outcome = "Отчёт отправлен.";
                done = true;
            }
            catch (ProblemReportException error)
            {
                outcome = error.Kind == "unavailable" ? "Сервис отчётов сейчас не принимает отчёты Waypoint." :
                    error.Kind == "busy" ? "Сервис отчётов занят; отправьте снова через несколько минут." :
                    error.Kind == "unreachable" ? "Сервис отчётов недоступен. Проверьте интернет и отправьте снова." :
                    "Сервис отклонил отчёт: " + error.Message;
            }
            catch (Exception) { outcome = "Отчёт не отправлен."; }
            result.Text = outcome;
            send.IsEnabled = true;
            if (done) { description.Text = ""; contact.Text = ""; pictures.Clear(); DrawShots(); }
        };

        var content = new StackPanel { Spacing = 10, Width = 640, Children = {
            report, save,
            new TextBlock { Text = "Сообщить о проблеме разработчику", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(0, 8, 0, 0) },
            description,
            new TextBlock { Text = "Скриншот можно вставить через Ctrl+V в поле выше.", Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] },
            new ScrollViewer { Content = shots, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled },
            new StackPanel { Spacing = 4, Children = { new TextBlock { Text = "Почта для ответа (необязательно)" }, contact } },
            new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { attach, add, send } },
            result } };
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Отчёт", CloseButtonText = "Закрыть", RequestedTheme = root.ActualTheme,
            Content = new ScrollViewer { Content = content, MaxHeight = 640 } };
        dialog.Resources["ContentDialogMaxWidth"] = 720.0;
        await dialog.ShowAsync();
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
