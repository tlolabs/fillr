#include <libnotify/notify.h>

#include "LinuxNotification.h"

#include <QByteArray>

void showLinuxReadyNotification(const QString &title, const QString &detail) {
    if (!notify_init("FILLR")) return;
    const QByteArray titleBytes = title.toUtf8();
    const QByteArray detailBytes = detail.toUtf8();
    NotifyNotification *notification = notify_notification_new(titleBytes.constData(), detailBytes.constData(), "com.tlolabs.fillr");
    if (!notification) return;
    notify_notification_show(notification, nullptr);
    g_object_unref(notification);
}
