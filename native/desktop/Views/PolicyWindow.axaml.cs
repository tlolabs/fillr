using Avalonia.Controls;
using Avalonia.Interactivity;
namespace FILLR;

public partial class PolicyWindow : Window
{
    public PolicyWindow() => InitializeComponent();
    private void Cancel_Click(object? sender, RoutedEventArgs e) => Close(null);
    private void Save_Click(object? sender, RoutedEventArgs e)
    {
        var model = (PolicyEditor)DataContext!;
        try { Close(model.Result()); } catch (ArgumentException error) { model.Error = error.Message; }
    }
}
