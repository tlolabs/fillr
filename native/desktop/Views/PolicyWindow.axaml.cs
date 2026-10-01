using Avalonia.Controls;
using Avalonia.Interactivity;
namespace FILLR;

public partial class PolicyWindow : Window
{
    internal Action<MediaPolicy> SavePolicy { get; init; } = _ => throw new InvalidOperationException("No preferences store is available.");
    public PolicyWindow() => InitializeComponent();
    private void Cancel_Click(object? sender, RoutedEventArgs e) => Close(null);
    private void Save_Click(object? sender, RoutedEventArgs e)
    {
        var model = (PolicyEditor)DataContext!;
        try { SavePolicy(model.Result()); Close(); } catch (Exception error) { model.Error = error.Message; }
    }
}
