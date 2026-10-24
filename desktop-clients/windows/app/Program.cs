using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Waypoint;

// One window per user session: a second start shows the one that runs, which
// may be hidden in the notification area. Started with --register, as an
// administrator, it opens the registration at once.
public static class Program
{
    public const string MutexName = @"Local\Waypoint.Window";
    public const string ShowEventName = MutexName + ".Show";

    public static bool Register { get; private set; }
    // Started at sign-in: the icon in the notification area, no window.
    public static bool Background { get; private set; }
    public static EventWaitHandle ShowRequests { get; private set; }

    [STAThread]
    public static int Main(string[] args)
    {
        Register = args.Contains("--register");
        Background = args.Contains("--background");
        using var mutex = new Mutex(false, MutexName, out _);
        if (!Own(mutex, TimeSpan.Zero))
        {
            // The elevated window for a registration takes the place of the
            // plain one, which closes as it starts this one.
            if (Register) { if (!Own(mutex, TimeSpan.FromSeconds(10))) return 0; }
            else
            {
                try { EventWaitHandle.OpenExisting(ShowEventName).Set(); } catch (WaitHandleCannotBeOpenedException) { }
                return 0;
            }
        }
        ShowRequests = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(parameters =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        mutex.ReleaseMutex();
        return 0;
    }

    // A window that ended without letting go still lets the next one in.
    static bool Own(Mutex mutex, TimeSpan wait)
    {
        try { return mutex.WaitOne(wait); }
        catch (AbandonedMutexException) { return true; }
    }

    [DllImport("user32.dll")]
    internal static extern bool SetForegroundWindow(IntPtr window);
}
