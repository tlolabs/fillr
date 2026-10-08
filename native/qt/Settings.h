#pragma once

#include <QJsonObject>
#include <QString>

class SettingsStore final {
public:
    SettingsStore();
    explicit SettingsStore(const QString &root);
    QString folder() const;
    QJsonObject policy() const;
    QJsonObject sort() const;
    QString appearance() const;
    bool saveFolder(const QString &folder, QString *error) const;
    bool savePolicy(const QJsonObject &policy, QString *error) const;
    bool saveSort(const QJsonObject &sort, QString *error) const;
    bool saveAppearance(const QString &appearance, QString *error) const;
    static QJsonObject defaultPolicy();
    static QJsonObject defaultSort();
    static QString rootPath();

private:
    QString root_;
    static bool writeFile(const QString &path, const QByteArray &bytes, QString *error);
    QJsonObject readObject(const QString &name, const QJsonObject &fallback) const;
};
