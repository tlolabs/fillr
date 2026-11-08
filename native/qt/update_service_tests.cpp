#include "UpdateService.h"
#include <QSignalSpy>
#include <QTest>

class UpdateServiceTests final : public QObject {
    Q_OBJECT
private slots:
    void installationRemainsBusyUntilCompletion() {
        UpdateService service;
        QSignalSpy failure(&service, &UpdateService::failed);
        // An empty descriptor is rejected before any real installation on every OS.
        service.stageDownload({});
        QVERIFY(service.busy());
        QTRY_COMPARE(failure.count(), 1);
        QVERIFY(!service.busy());
    }
    void ownerMayBeDestroyedBeforeCompletion() {
        auto *service = new UpdateService;
        service->stageDownload({});
        delete service;
        // Process worker completion after the Qt receiver has been destroyed.
        QTest::qWait(100);
    }
};
QTEST_GUILESS_MAIN(UpdateServiceTests)
#include "update_service_tests.moc"
