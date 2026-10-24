using Microsoft.UI.Xaml;

namespace Waypoint;

public partial class App : Application
{
    MainWindow window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        if (!Program.Background) window.Activate();
    }
}
