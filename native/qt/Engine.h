#pragma once

#include <QJsonObject>
#include <QObject>
#include <QString>

class EngineWorker final : public QObject {
    Q_OBJECT
public:
    ~EngineWorker() override;

public slots:
    void open(const QString &folder, const QJsonObject &policy, const QJsonObject &sort);
    void applySettings(const QJsonObject &policy, const QJsonObject &sort);
    void poll();
    void refresh();
    void build();

signals:
    void opened(const QString &folder);
    void snapshotReady(const QJsonObject &snapshot);
    void buildFinished(const QJsonObject &result);
    void failed(const QString &message);

private:
    void *engine_ = nullptr;
    QString lastError() const;
    QJsonObject takeJson(char *value) const;
};
