#include "Engine.h"

#include "fillr.h"

#include <QJsonDocument>
#include <QJsonParseError>
#include <QByteArray>

EngineWorker::~EngineWorker() {
    if (engine_) fillr_destroy(engine_);
}

QString EngineWorker::lastError() const {
    char *error = fillr_last_error();
    if (!error) return QStringLiteral("The processing engine returned an unknown error.");
    const QString message = QString::fromUtf8(error);
    fillr_free_string(error);
    return message;
}

QJsonObject EngineWorker::takeJson(char *value) const {
    if (!value) return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), lastError()}};
    const QByteArray bytes(value);
    fillr_free_string(value);
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(bytes, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject())
        return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), QStringLiteral("The engine returned invalid data.")}};
    return document.object();
}

void EngineWorker::open(const QString &folder, const QJsonObject &policy, const QJsonObject &sort) {
    if (fillr_api_version() != 1) { emit failed(QStringLiteral("The installed processing engine is incompatible with this version of FILLR.")); return; }
    const QByteArray pathBytes = folder.toUtf8();
    const QByteArray policyBytes = QJsonDocument(policy).toJson(QJsonDocument::Compact);
    const QByteArray sortBytes = QJsonDocument(sort).toJson(QJsonDocument::Compact);
    void *next = fillr_create_with_settings_owned(pathBytes.constData(), policyBytes.constData(), sortBytes.constData());
    if (!next) { emit failed(lastError()); return; }
    if (engine_) fillr_destroy(engine_);
    engine_ = next;
    emit opened(folder);
    poll();
}

void EngineWorker::applySettings(const QJsonObject &policy, const QJsonObject &sort) {
    if (!engine_) return;
    const QByteArray policyBytes = QJsonDocument(policy).toJson(QJsonDocument::Compact);
    const QByteArray sortBytes = QJsonDocument(sort).toJson(QJsonDocument::Compact);
    if (fillr_set_media_policy(engine_, policyBytes.constData()) != 1 ||
        fillr_set_sort_settings(engine_, sortBytes.constData()) != 1) {
        emit failed(lastError());
        return;
    }
    poll();
}

void EngineWorker::poll() {
    if (!engine_) return;
    const QJsonObject result = takeJson(fillr_snapshot(engine_));
    if (result.value(QStringLiteral("ok")).toBool(true)) emit snapshotReady(result);
    else emit failed(result.value(QStringLiteral("error")).toString());
}

void EngineWorker::refresh() {
    if (!engine_) return;
    fillr_refresh(engine_);
    poll();
}

void EngineWorker::build() {
    if (!engine_) { emit failed(QStringLiteral("Choose a download folder before building.")); return; }
    emit buildFinished(takeJson(fillr_build(engine_)));
    poll();
}
