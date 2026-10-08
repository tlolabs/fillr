#pragma once

#include <QJsonObject>
#include <QObject>

class QProcess;

class UpdateService final : public QObject {
    Q_OBJECT
public:
    explicit UpdateService(QObject *parent = nullptr);
    bool supported() const;
    bool automatic() const { return automatic_; }
    bool busy() const;
    void check(bool manual);
    void setAutomatic(bool enabled);
    void install(const QString &version);

signals:
    void checkResult(bool manual, const QJsonObject &result);
    void installResult(const QString &message);
    void automaticChanged(bool automatic);
    void failed(const QString &message);

private:
    QProcess *process_;
    QString command_;
    bool automatic_ = true;
    bool pendingAutomatic_ = false;
    void run(const QString &command, const QString &version = {});
    static QString statePath();
};
