#include "UpdateService.h"
#include "WindowsInstaller.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QProcess>
#include <QThread>

UpdateService::UpdateService(QObject *parent) : QObject(parent), process_(new QProcess(this)) {
#ifdef Q_OS_MACOS
    automatic_ = false;
#else
    QFile file(statePath());
    if (file.open(QIODevice::ReadOnly)) {
        const QJsonDocument state = QJsonDocument::fromJson(file.readAll());
        automatic_ = state.isObject() && !state.object().value(QStringLiteral("disabled")).toBool();
    }
#endif
    connect(process_, &QProcess::finished, this, [this](int exitCode, QProcess::ExitStatus exitStatus) {
        const QString command = command_;
        command_.clear();
        const QByteArray output = process_->readAllStandardOutput();
        const QString error = QString::fromUtf8(process_->readAllStandardError()).trimmed();
        const QJsonDocument document = QJsonDocument::fromJson(output);
        if (exitStatus != QProcess::NormalExit || exitCode != 0 || !document.isObject()) {
            if (command == QLatin1String("enable") || command == QLatin1String("disable")) emit automaticChanged(automatic_);
            emit failed(error.isEmpty() ? tr("The update helper failed. Reopen FILLR and try again.") : error);
            return;
        }
        const QJsonObject result = document.object();
        if (command == QLatin1String("enable") || command == QLatin1String("disable")) {
            automatic_ = pendingAutomatic_; emit automaticChanged(automatic_); return;
        }
        if (command == QLatin1String("check") || command == QLatin1String("check-auto")) {
            emit checkResult(command == QLatin1String("check"), result); return;
        }
        if (command == QLatin1String("install-appimage")) {
            if (result.value(QStringLiteral("status")).toString() != QLatin1String("installed")) {
                emit failed(tr("The updater did not confirm installation.")); return;
            }
            emit installResult(tr("Quit and reopen this AppImage to use the new version. Recovery copy: %1").arg(result.value(QStringLiteral("backup")).toString()));
            return;
        }
#ifdef Q_OS_WIN
        if (command == QLatin1String("download")) {
            auto *thread = QThread::create([this, result] {
                QString failure;
                const bool installed = stageWindowsUpdate(result, &failure);
                QMetaObject::invokeMethod(this, [this, installed, failure] {
                    if (!installed) emit failed(failure);
                    else emit installResult(tr("Windows will complete registration when FILLR closes. Reopen FILLR from Start to use the new version."));
                }, Qt::QueuedConnection);
            });
            connect(thread, &QThread::finished, thread, &QObject::deleteLater);
            thread->start();
        }
#endif
    });
    connect(process_, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart && (command_ == QLatin1String("enable") || command_ == QLatin1String("disable"))) emit automaticChanged(automatic_);
    });
}

bool UpdateService::supported() const {
#ifdef Q_OS_MACOS
    return false;
#else
    return true;
#endif
}

bool UpdateService::busy() const { return process_->state() != QProcess::NotRunning; }

QString UpdateService::statePath() {
#ifdef Q_OS_WIN
    const QString root = qEnvironmentVariable("LOCALAPPDATA", QDir::homePath() + QStringLiteral("/AppData/Local"));
#else
    const QString root = qEnvironmentVariable("XDG_CACHE_HOME", QDir::homePath() + QStringLiteral("/.cache"));
#endif
    return root + QStringLiteral("/fillr/updates/state.json");
}

void UpdateService::run(const QString &command, const QString &version) {
    if (!supported() || busy()) return;
    command_ = command;
#ifdef Q_OS_WIN
    const QString program = QCoreApplication::applicationDirPath() + QStringLiteral("/fillr-update.exe");
#else
    const QString program = QCoreApplication::applicationDirPath() + QStringLiteral("/fillr-update");
#endif
    QStringList args{command}; if (!version.isEmpty()) args.append(version);
    process_->setProgram(program); process_->setArguments(args); process_->start();
}

void UpdateService::check(bool manual) { if (manual || automatic_) run(manual ? QStringLiteral("check") : QStringLiteral("check-auto")); }
void UpdateService::setAutomatic(bool enabled) {
    if (busy()) {
        emit automaticChanged(automatic_);
        emit failed(tr("An update check is still running. Try changing this setting again in a moment."));
        return;
    }
    pendingAutomatic_ = enabled;
    run(enabled ? QStringLiteral("enable") : QStringLiteral("disable"));
}
void UpdateService::install(const QString &version) {
#ifdef Q_OS_WIN
    run(QStringLiteral("download"), version);
#elif defined(Q_OS_LINUX)
    run(QStringLiteral("install-appimage"), version);
#else
    Q_UNUSED(version);
#endif
}
