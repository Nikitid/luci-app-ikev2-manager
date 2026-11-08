using System.Runtime.InteropServices;
using IkeV2Manager.Client;

namespace Waypoint;

// The notification area icon: one-colour Waypoint mark in four states - open,
// off, connecting, attention - dark on a light taskbar and white on a dark
// one. A click opens the window; its menu is the system's (TrackPopupMenuEx):
// the state, the switch, the services by choice with a tick, the update, the
// window and the exit. WinUI has no tray control, so this is Shell_NotifyIcon
// on a hidden window.
sealed class Tray : IDisposable
{
    const int WM_USER = 0x0400, CallbackMessage = WM_USER + 1, WM_LBUTTONUP = 0x0202, WM_LBUTTONDBLCLK = 0x0203, WM_RBUTTONUP = 0x0205,
              WM_CONTEXTMENU = 0x007B, NIN_SELECT = 0x0400, NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4,
              NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_SHOWTIP = 0x80, NOTIFYICON_VERSION_4 = 4,
              TPM_RETURNCMD = 0x100, TPM_RIGHTBUTTON = 2, MF_STRING = 0, MF_SEPARATOR = 0x800, MF_GRAYED = 1, MF_CHECKED = 8;

    readonly Action open;
    readonly Action<string> choose;
    readonly WindowProcedure procedure;
    readonly uint taskbarCreated;
    readonly Dictionary<string, IntPtr> icons = new();
    IntPtr window, icon;
    string tip = "Waypoint", state = "off";
    bool light = true;
    TrayItem[] items = new TrayItem[0];

    public bool Visible { get; private set; }

    delegate IntPtr WindowProcedure(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    public Tray(Action open, Action<string> choose)
    {
        this.open = open;
        this.choose = choose;
        procedure = Procedure;
        taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
    }

    public void Show()
    {
        if (window == IntPtr.Zero)
        {
            var instance = GetModuleHandleW(null);
            const string name = "Waypoint.Tray";
            var windowClass = new WindowClass
            {
                Size = (uint)Marshal.SizeOf<WindowClass>(),
                Procedure = Marshal.GetFunctionPointerForDelegate(procedure),
                Instance = instance,
                ClassName = Marshal.StringToHGlobalUni(name),
            };
            RegisterClassExW(ref windowClass);
            window = CreateWindowExW(0, name, "Waypoint", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
            icon = Icon();
        }
        Add();
    }

    // The icon of the state for the taskbar's light or dark, at the size the
    // system asks for the notification area.
    IntPtr Icon()
    {
        string name = "tray-" + (light ? "light" : "dark") + "-" + state + ".ico";
        if (icons.TryGetValue(name, out var known)) return known;
        int size = GetSystemMetrics(49); // SM_CXSMICON
        var loaded = LoadImageW(IntPtr.Zero, Path.Combine(AppContext.BaseDirectory, "Assets", "tray", name), 1, size, size, 0x10);
        if (loaded == IntPtr.Zero) loaded = LoadImageW(IntPtr.Zero, Path.Combine(AppContext.BaseDirectory, "Assets", "Waypoint.ico"), 1, size, size, 0x10);
        icons[name] = loaded;
        return loaded;
    }

    public void Taskbar(bool isLight)
    {
        if (isLight == light) return;
        light = isLight;
        Repaint();
    }

    void Repaint()
    {
        icon = Icon();
        if (window == IntPtr.Zero) return;
        var data = Data();
        data.Flags = NIF_ICON | NIF_TIP | NIF_SHOWTIP;
        data.Icon = icon;
        data.Tip = tip;
        Shell_NotifyIconW(NIM_MODIFY, ref data);
    }

    // What the icon says on hover, which of the four it shows ("open",
    // "off", "connecting", "attention") and what its menu offers.
    public void Update(string text, string kind, TrayItem[] menu)
    {
        items = menu ?? new TrayItem[0];
        string next = text.Length > 127 ? text[..127] : text;
        if (next == tip && kind == state) return;
        tip = next; state = kind;
        Repaint();
    }

    void Add()
    {
        var data = Data();
        data.Flags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
        data.CallbackMessage = CallbackMessage;
        data.Icon = icon;
        data.Tip = tip;
        Visible = Shell_NotifyIconW(NIM_ADD, ref data);
        data.Version = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, ref data);
    }

    NotifyIconData Data() => new() { Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = window, Id = 1 };

    IntPtr Procedure(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == taskbarCreated)
        {
            // Explorer restarted: the icon has to be added again.
            Add();
            return IntPtr.Zero;
        }
        if (message == CallbackMessage)
        {
            int kind = (int)(lParam.ToInt64() & 0xFFFF);
            if (kind is WM_LBUTTONUP or WM_LBUTTONDBLCLK or NIN_SELECT) open();
            else if (kind is WM_RBUTTONUP or WM_CONTEXTMENU) Menu();
            return IntPtr.Zero;
        }
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    void Menu()
    {
        var menu = CreatePopupMenu();
        foreach (var item in items)
        {
            if (item.Separator) { AppendMenuW(menu, MF_SEPARATOR, 0, null); continue; }
            uint flags = MF_STRING | (item.Enabled ? 0u : MF_GRAYED) | (item.Checked ? MF_CHECKED : 0u);
            AppendMenuW(menu, flags, (nuint)item.Id, item.Text);
        }
        if (items.Length == 0) AppendMenuW(menu, MF_STRING, 1, "Открыть Waypoint");
        GetCursorPos(out var point);
        SetForegroundWindow(window);
        int choice = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.X, point.Y, window, IntPtr.Zero);
        DestroyMenu(menu);
        if (choice == 0) return;
        var picked = items.FirstOrDefault(i => i.Id == choice && !i.Separator);
        if (picked?.Action != null) choose(picked.Action);
        else if (items.Length == 0) open();
    }

    public void Dispose()
    {
        if (window == IntPtr.Zero) return;
        var data = Data();
        Shell_NotifyIconW(NIM_DELETE, ref data);
        DestroyWindow(window);
        window = IntPtr.Zero;
        Visible = false;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct WindowClass
    {
        public uint Size, Style;
        public IntPtr Procedure;
        public int ClassExtra, WindowExtra;
        public IntPtr Instance, Icon, Cursor, Background, MenuName, ClassName, SmallIcon;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NotifyIconData
    {
        public uint Size;
        public IntPtr Window;
        public uint Id, Flags, CallbackMessage;
        public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid Item;
        public IntPtr BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Point { public int X, Y; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern bool Shell_NotifyIconW(int message, ref NotifyIconData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassExW(ref WindowClass windowClass);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(int exStyle, string className, string name, int style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessageW(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImageW(IntPtr instance, string name, uint type, int width, int height, uint load);
    [DllImport("user32.dll")] static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool AppendMenuW(IntPtr menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")] static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr window, IntPtr parameters);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
}
