using System.Runtime.InteropServices;
namespace FILLR;

internal static partial class DesktopNotifications
{
    public static void Ready()
    {
        try
        {
#if WINDOWS
            var xml = new Windows.Data.Xml.Dom.XmlDocument();
            xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>Chabot News footage is ready</text><text>You can stop downloading and build the 14 Comp folders.</text></binding></visual></toast>");
            Windows.UI.Notifications.ToastNotificationManager.CreateToastNotifier().Show(new Windows.UI.Notifications.ToastNotification(xml));
#else
            if (OperatingSystem.IsLinux() && NotifyInit("FILLR") != 0)
            {
                nint notification = NotifyNew("Chabot News footage is ready", "You can stop downloading and build the 14 Comp folders.", "edu.chabot.news.backgrounder");
                if (notification != 0) { try { NotifyShow(notification, 0); } finally { Unref(notification); } }
            }
#endif
        }
        catch (Exception ex) { Console.Error.WriteLine("Desktop notification unavailable; Ready remains visible in FILLR: " + ex.Message); }
    }
    [LibraryImport("libnotify.so.4", EntryPoint = "notify_init", StringMarshalling = StringMarshalling.Utf8)] private static partial int NotifyInit(string app);
    [LibraryImport("libnotify.so.4", EntryPoint = "notify_notification_new", StringMarshalling = StringMarshalling.Utf8)] private static partial nint NotifyNew(string title, string body, string icon);
    [LibraryImport("libnotify.so.4", EntryPoint = "notify_notification_show")] private static partial int NotifyShow(nint value, nint error);
    [LibraryImport("libgobject-2.0.so.0", EntryPoint = "g_object_unref")] private static partial void Unref(nint value);
}
