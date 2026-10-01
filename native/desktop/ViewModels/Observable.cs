using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;
namespace FILLR;

internal class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    { if (EqualityComparer<T>.Default.Equals(field, value)) return false; field = value; Changed(name); return true; }
}
internal sealed class UiCommand(Func<Task> action, Func<bool>? enabled = null) : ICommand
{
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => enabled?.Invoke() ?? true;
    public async void Execute(object? parameter) => await ExecuteAsync();
    public Task ExecuteAsync() => CanExecute(null) ? action() : Task.CompletedTask;
    public void Refresh() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
