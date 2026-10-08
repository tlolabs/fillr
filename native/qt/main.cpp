#include "MainWindow.h"

#include <QApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QMessageBox>
#include <QTimer>

int main(int argc, char **argv) {
    for (int index = 1; index < argc; ++index) {
        if (QString::fromLocal8Bit(argv[index]) == QLatin1String("--version")) {
            fprintf(stdout, "%s\n", FILLR_VERSION);
            return 0;
        }
    }
    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("FILLR"));
    app.setOrganizationName(QStringLiteral("TLOLabs"));
    app.setApplicationVersion(QStringLiteral(FILLR_VERSION));
    app.setWindowIcon(QIcon(QStringLiteral(":/icons/fillr.png")));
#ifdef Q_OS_MACOS
    const QString instanceName = QStringLiteral("com.tlolabs.fillr.qt.internal");
#else
    const QString instanceName = QStringLiteral("com.tlolabs.fillr.qt");
#endif
    QLocalSocket existing;
    existing.connectToServer(instanceName);
    if (existing.waitForConnected(250)) {
        existing.write("activate"); existing.waitForBytesWritten(250);
        return 0;
    }
    QLocalServer server;
    if (!server.listen(instanceName)) {
        QLocalServer::removeServer(instanceName);
        if (!server.listen(instanceName)) {
            QMessageBox::critical(nullptr, QObject::tr("FILLR"), QObject::tr("Could not establish the single-instance channel."));
            return 1;
        }
    }
    MainWindow window;
    QObject::connect(&server, &QLocalServer::newConnection, &window, [&server, &window] {
        while (auto *client = server.nextPendingConnection()) {
            QObject::connect(client, &QLocalSocket::disconnected, client, &QObject::deleteLater);
            client->disconnectFromServer();
        }
        window.showNormal(); window.raise(); window.activateWindow();
    });
    window.show();
    return app.exec();
}
