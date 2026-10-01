using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
namespace FILLR;

// One watcher per settings identity. A second launch only activates the first;
// no paths, commands or user data are accepted over the same-user pipe.
internal sealed class InstanceLease : IDisposable
{
    private readonly FileStream? lease;
    private readonly CancellationTokenSource stopped = new();
    private readonly Task? listener;
    public bool Acquired => lease != null;
    public InstanceLease(string root, Action? activate = null)
    {
        Directory.CreateDirectory(root);
        var name = "fillr-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(root)))[..24];
        try { lease = new FileStream(Path.Combine(root, "instance.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException)
        {
            try { using var pipe = new NamedPipeClientStream(".", name, PipeDirection.Out, PipeOptions.CurrentUserOnly); pipe.Connect(1500); pipe.WriteByte(1); }
            catch (Exception ex) when (ex is IOException or TimeoutException) { Console.Error.WriteLine("FILLR is already running: " + ex.Message); }
            return;
        }
        listener = Listen(name, activate);
    }
    private async Task Listen(string name, Action? activate)
    {
        try
        {
            while (!stopped.IsCancellationRequested)
            {
                using var pipe = new NamedPipeServerStream(name, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(stopped.Token).ConfigureAwait(false);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stopped.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(2));
                var buffer = new byte[1];
                try { if (await pipe.ReadAsync(buffer, timeout.Token).ConfigureAwait(false) == 1 && buffer[0] == 1) activate?.Invoke(); }
                catch (OperationCanceledException) when (!stopped.IsCancellationRequested) { }
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException ex) { Console.Error.WriteLine("Window activation unavailable: " + ex.Message); }
    }
    public void Dispose()
    {
        stopped.Cancel();
        listener?.GetAwaiter().GetResult();
        stopped.Dispose();
        lease?.Dispose();
    }
}
