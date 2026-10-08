using Avalonia.Controls;
using Avalonia.Interactivity;
namespace FILLR;

public partial class PolicyWindow : Window
{
    internal Action<MediaPolicy> SavePolicy { get; init; } = _ => throw new InvalidOperationException("No preferences store is available.");
    internal Action<MediaPolicy, SortSettings>? SaveSettings { get; init; }
    public PolicyWindow() => InitializeComponent();
    private void Cancel_Click(object? sender, RoutedEventArgs e) => Close(null);
    private void Save_Click(object? sender, RoutedEventArgs e)
    {
        var model = (PolicyEditor)DataContext!;
        try {
            if (SaveSettings is { } save) save(model.Result(), model.ResultSort());
            else SavePolicy(model.Result());
            Close();
        } catch (Exception error) { model.Error = error.Message; }
    }
}
