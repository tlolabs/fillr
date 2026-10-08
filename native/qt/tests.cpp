#include "SettingsDialog.h"
#include "Settings.h"

#include <QComboBox>
#include <QDialogButtonBox>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QTemporaryDir>
#include <QtTest>

class SettingsDialogTests final : public QObject {
    Q_OBJECT
private slots:
    void defaults() {
        SettingsDialog dialog(SettingsStore::defaultPolicy(), SettingsStore::defaultSort(), QStringLiteral("system"));
        QCOMPARE(dialog.appearance(), QStringLiteral("system"));
        QCOMPARE(dialog.sort().value(QStringLiteral("folder_count")).toInt(), 14);
        QCOMPARE(dialog.sort().value(QStringLiteral("total_ms")).toInt(), 8470000);
    }

    void rejectsUnsafeFolderPrefix() {
        SettingsDialog dialog(SettingsStore::defaultPolicy(), SettingsStore::defaultSort(), QStringLiteral("system"));
        auto *prefix = dialog.findChild<QLineEdit *>(QStringLiteral("folderPrefix"));
        QVERIFY(prefix);
        prefix->setText(QStringLiteral("../bad"));
        auto *buttons = dialog.findChild<QDialogButtonBox *>();
        QVERIFY(buttons);
        buttons->button(QDialogButtonBox::Save)->click();
        QCOMPARE(dialog.result(), 0);
        bool communicated = false;
        for (const auto *label : dialog.findChildren<QLabel *>())
            if (label->text().contains(QStringLiteral("safe name"))) communicated = true;
        QVERIFY(communicated);
    }

    void savesConfiguredValues() {
        SettingsDialog dialog(SettingsStore::defaultPolicy(), SettingsStore::defaultSort(), QStringLiteral("system"));
        dialog.findChild<QLineEdit *>(QStringLiteral("folderPrefix"))->setText(QStringLiteral("Scene"));
        dialog.findChild<QLineEdit *>(QStringLiteral("hours"))->setText(QStringLiteral("3"));
        dialog.findChild<QComboBox *>(QStringLiteral("appearance"))->setCurrentIndex(2);
        dialog.findChild<QDialogButtonBox *>()->button(QDialogButtonBox::Save)->click();
        QCOMPARE(dialog.result(), QDialog::Accepted);
        QCOMPARE(dialog.sort().value(QStringLiteral("folder_prefix")).toString(), QStringLiteral("Scene"));
        QCOMPARE(dialog.appearance(), QStringLiteral("dark"));
    }

    void persistsPreferencesAcrossStoreInstances() {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        SettingsStore first(directory.path());
        QString error;
        QJsonObject sort = SettingsStore::defaultSort();
        sort.insert(QStringLiteral("folder_count"), 8);
        QJsonObject policy = SettingsStore::defaultPolicy();
        policy.insert(QStringLiteral("enabled"), false);
        QVERIFY2(first.saveFolder(QStringLiteral("/tmp/news"), &error), qPrintable(error));
        QVERIFY2(first.saveSort(sort, &error), qPrintable(error));
        QVERIFY2(first.savePolicy(policy, &error), qPrintable(error));
        QVERIFY2(first.saveAppearance(QStringLiteral("dark"), &error), qPrintable(error));
        SettingsStore next(directory.path());
        QCOMPARE(next.folder(), QStringLiteral("/tmp/news"));
        QCOMPARE(next.sort().value(QStringLiteral("folder_count")).toInt(), 8);
        QCOMPARE(next.policy().value(QStringLiteral("enabled")).toBool(), false);
        QCOMPARE(next.appearance(), QStringLiteral("dark"));
        QVERIFY2(next.saveAppearance(QStringLiteral("light"), &error), qPrintable(error));
        QCOMPARE(SettingsStore(directory.path()).appearance(), QStringLiteral("light"));
        QVERIFY2(next.saveAppearance(QStringLiteral("system"), &error), qPrintable(error));
        QCOMPARE(SettingsStore(directory.path()).appearance(), QStringLiteral("system"));
    }
};

QTEST_MAIN(SettingsDialogTests)
#include "tests.moc"
