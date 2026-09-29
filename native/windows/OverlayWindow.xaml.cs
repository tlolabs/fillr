using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace FILLR;

public sealed partial class OverlayWindow : Window
{
    public OverlayWindow()
    {
        InitializeComponent();
        AppIcon.Apply(this);
        AppWindow.SetPresenter(AppWindowPresenterKind.CompactOverlay);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(310, 150));
    }

    public void Update(ulong remaining, bool ready)
    {
        OverlayStatus.Text = ready ? "Ready to build" : "Footage remaining";
        OverlayTime.Text = MainWindow.ClockText(remaining);
        OverlayProgress.Value = 8_470_000 - Math.Min(remaining, 8_470_000UL);
    }
}
