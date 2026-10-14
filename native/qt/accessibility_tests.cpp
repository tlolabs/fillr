#include "SettingsDialog.h"

#include <QAccessible>
#include <QComboBox>
#include <QDialogButtonBox>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
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

    void errorLabelIsPlainTextAndResistsHtmlInjection() {
        const QJsonObject policy{{QStringLiteral("enabled"), true}};
        const QJsonObject sort{{QStringLiteral("folder_count"), 14}, {QStringLiteral("folder_prefix"), QStringLiteral("Comp")}, {QStringLiteral("total_ms"), 8470000}};
        SettingsDialog dialog(policy, sort, QStringLiteral("system"));
        auto *errorLabel = dialog.findChild<QLabel *>(QString());
        // Find the error label by its accessible name
        for (auto *label : dialog.findChildren<QLabel *>()) {
            if (label->accessibleName() == QStringLiteral("Settings error")) {
                errorLabel = label;
                break;
            }
        }
        QVERIFY(errorLabel);
        QCOMPARE(errorLabel->textFormat(), Qt::PlainText);

        const QString hostileHtml = QStringLiteral("<script>alert(1)</script><img src=\"http://example.com/evil.png\" /><b>Error text</b>");
        errorLabel->setText(hostileHtml);
        QCOMPARE(errorLabel->textFormat(), Qt::PlainText);
        QCOMPARE(errorLabel->text(), hostileHtml);
    }

    void validationFailureFocusTransitionAndErrorAssociation() {
        const QJsonObject policy{{QStringLiteral("enabled"), true}};
        const QJsonObject sort{{QStringLiteral("folder_count"), 14}, {QStringLiteral("folder_prefix"), QStringLiteral("Comp")}, {QStringLiteral("total_ms"), 8470000}};
        SettingsDialog dialog(policy, sort, QStringLiteral("system"));
        auto *prefix = dialog.findChild<QLineEdit *>(QStringLiteral("folderPrefix"));
        QVERIFY(prefix);
        prefix->setText(QStringLiteral("/invalid/path"));

        auto *buttons = dialog.findChild<QDialogButtonBox *>();
        QVERIFY(buttons);
        buttons->button(QDialogButtonBox::Save)->click();

        QCOMPARE(dialog.result(), 0);
        QCOMPARE(dialog.focusWidget(), prefix);

        QLabel *errorLabel = nullptr;
        for (auto *label : dialog.findChildren<QLabel *>()) {
            if (label->accessibleName() == QStringLiteral("Settings error")) {
                errorLabel = label;
                break;
            }
        }
        QVERIFY(errorLabel);
        QVERIFY(!errorLabel->text().isEmpty());
    }
};

QTEST_MAIN(AccessibilityTests)
#include "accessibility_tests.moc"
