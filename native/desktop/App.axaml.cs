using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
namespace FILLR;

public partial class App : Application
{
    internal static void ActivateExisting() => Avalonia.Threading.Dispatcher.UIThread.Post(() =>
    {
        if (Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop && desktop.MainWindow is { } window)
        {
            window.Show();
            if (window.WindowState == Avalonia.Controls.WindowState.Minimized) window.WindowState = Avalonia.Controls.WindowState.Normal;
            window.Activate();
        }
    });
    public override void Initialize() { Name = AppIdentity.Title; AvaloniaXamlLoader.Load(this); }
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            desktop.MainWindow = new MainWindow();
        base.OnFrameworkInitializationCompleted();
    }
}
