#include "SettingsDialog.h"

#include <QAccessible>
#include <QComboBox>
#include <QtTest>

class AccessibilityTests final : public QObject {
    Q_OBJECT
private slots:
    void settingsControlsHaveNames() {
        const QJsonObject policy{{QStringLiteral("enabled"), true}};
        const QJsonObject sort{{QStringLiteral("folder_count"), 14}, {QStringLiteral("folder_prefix"), QStringLiteral("Comp")}, {QStringLiteral("total_ms"), 8470000}};
        SettingsDialog dialog(policy, sort, QStringLiteral("system"));
        for (const QString &name : {QStringLiteral("standard"), QStringLiteral("scan"), QStringLiteral("orientation"), QStringLiteral("appearance")}) {
            auto *control = dialog.findChild<QComboBox *>(name);
            QVERIFY(control);
            auto *accessibility = QAccessible::queryAccessibleInterface(control);
            QVERIFY(accessibility);
            QVERIFY(!accessibility->text(QAccessible::Name).isEmpty());
        }
    }
};

QTEST_MAIN(AccessibilityTests)
#include "accessibility_tests.moc"
