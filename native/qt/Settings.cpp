#include "Settings.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <QStandardPaths>

SettingsStore::SettingsStore() : root_(rootPath()) {}
SettingsStore::SettingsStore(const QString &root) : root_(root) {}

QString SettingsStore::rootPath() {
#ifdef Q_OS_MACOS
    return QDir::homePath() + QStringLiteral("/Library/Application Support/TLOLabs/FILLR-Qt-Internal");
#elif defined(Q_OS_WIN)
    return qEnvironmentVariable("LOCALAPPDATA", QDir::homePath() + QStringLiteral("/AppData/Local")) + QStringLiteral("/FILLR");
#else
    return qEnvironmentVariable("XDG_CONFIG_HOME", QDir::homePath() + QStringLiteral("/.config")) + QStringLiteral("/fillr");
#endif
}

QJsonObject SettingsStore::defaultPolicy() {
    return {
        {QStringLiteral("enabled"), true}, {QStringLiteral("delete_rejected"), true},
        {QStringLiteral("allowed_extensions"), QJsonArray{QStringLiteral("mpg")}},
        {QStringLiteral("allowed_containers"), QJsonArray{QStringLiteral("mpeg")}},
        {QStringLiteral("allowed_codecs"), QJsonArray{QStringLiteral("mpeg2video")}},
        {QStringLiteral("required_width"), 1920}, {QStringLiteral("required_height"), 1080},
        {QStringLiteral("television_standard"), QStringLiteral("ntsc")},
        {QStringLiteral("frame_rate"), QStringLiteral("30000/1001")},
        {QStringLiteral("scan_type"), QStringLiteral("interlaced")},
        {QStringLiteral("orientation"), QStringLiteral("horizontal")},
        {QStringLiteral("display_aspect_ratio"), QStringLiteral("16:9")}
    };
}

QJsonObject SettingsStore::defaultSort() {
    return {{QStringLiteral("folder_count"), 14}, {QStringLiteral("folder_prefix"), QStringLiteral("Comp")}, {QStringLiteral("total_ms"), 8470000}};
}

QJsonObject SettingsStore::readObject(const QString &name, const QJsonObject &fallback) const {
    QFile file(root_ + QLatin1Char('/') + name);
    if (!file.open(QIODevice::ReadOnly)) return fallback;
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll());
    return document.isObject() ? document.object() : fallback;
}

QString SettingsStore::folder() const {
#ifdef Q_OS_WIN
    const QString filename = QStringLiteral("folder.txt");
    const QString legacy = qEnvironmentVariable("LOCALAPPDATA") + QStringLiteral("/ChabotBackgrounder/folder.txt");
#else
    const QString filename = QStringLiteral("folder");
#ifdef Q_OS_MACOS
    const QString legacy;
#else
    const QString legacy = QDir::homePath() + QStringLiteral("/.config/chabot-backgrounder/folder");
#endif
#endif
    QFile file(root_ + QLatin1Char('/') + filename);
    if (!file.exists() && !legacy.isEmpty()) file.setFileName(legacy);
    if (!file.open(QIODevice::ReadOnly)) return {};
    return QString::fromUtf8(file.readAll()).trimmed();
}

QJsonObject SettingsStore::policy() const { return readObject(QStringLiteral("media-policy.json"), defaultPolicy()); }
QJsonObject SettingsStore::sort() const { return readObject(QStringLiteral("sort-settings.json"), defaultSort()); }
QString SettingsStore::appearance() const {
    QFile file(root_ + QStringLiteral("/appearance"));
    if (!file.open(QIODevice::ReadOnly)) return QStringLiteral("system");
    const QString value = QString::fromUtf8(file.readAll()).trimmed();
    return value == QLatin1String("light") || value == QLatin1String("dark") ? value : QStringLiteral("system");
}

bool SettingsStore::writeFile(const QString &path, const QByteArray &bytes, QString *error) {
    if (!QDir().mkpath(QFileInfo(path).absolutePath())) {
        if (error) *error = QStringLiteral("Could not create the settings folder.");
        return false;
    }
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size() || !file.commit()) {
        if (error) *error = QStringLiteral("Could not save settings: %1").arg(file.errorString());
        return false;
    }
    return true;
}

bool SettingsStore::saveFolder(const QString &folder, QString *error) const {
#ifdef Q_OS_WIN
    const QString name = QStringLiteral("folder.txt");
#else
    const QString name = QStringLiteral("folder");
#endif
    return writeFile(root_ + QLatin1Char('/') + name, folder.toUtf8(), error);
}
bool SettingsStore::savePolicy(const QJsonObject &value, QString *error) const {
    return writeFile(root_ + QStringLiteral("/media-policy.json"), QJsonDocument(value).toJson(), error);
}
bool SettingsStore::saveSort(const QJsonObject &value, QString *error) const {
    return writeFile(root_ + QStringLiteral("/sort-settings.json"), QJsonDocument(value).toJson(), error);
}
bool SettingsStore::saveAppearance(const QString &value, QString *error) const {
    return writeFile(root_ + QStringLiteral("/appearance"), value.toUtf8(), error);
}
