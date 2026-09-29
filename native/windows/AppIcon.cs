using Microsoft.UI.Xaml;

namespace FILLR;

internal static class AppIcon
{
    internal static void Apply(Window window)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Assets", "FILLR.ico");
        window.AppWindow.SetIcon(path);
    }
}
