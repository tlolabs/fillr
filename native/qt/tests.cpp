#include "SettingsDialog.h"
#include "Settings.h"

#include <QComboBox>
#include <QDialogButtonBox>
#include <QDir>
#include <QFile>
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

    void rejectsControlCharactersInFolderPrefix() {
        for (const auto control : {ushort(0x7f), ushort(0x85), ushort(0x9f)}) {
            SettingsDialog dialog(SettingsStore::defaultPolicy(), SettingsStore::defaultSort(), QStringLiteral("system"));
            auto *prefix = dialog.findChild<QLineEdit *>(QStringLiteral("folderPrefix"));
            prefix->setText(QStringLiteral("Scene") + QChar(control) + QStringLiteral("Name"));
            dialog.findChild<QDialogButtonBox *>()->button(QDialogButtonBox::Save)->click();
            QCOMPARE(dialog.result(), 0);
        }
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

    void acceptsPositiveDecimalsAndRatiosWithSpaces() {
        SettingsDialog dialog(SettingsStore::defaultPolicy(), SettingsStore::defaultSort(), QStringLiteral("system"));
        auto *rate = dialog.findChild<QLineEdit *>(QStringLiteral("frameRate"));
        auto *aspect = dialog.findChild<QLineEdit *>(QStringLiteral("aspectRatio"));
        QVERIFY(rate);
        QVERIFY(aspect);
        rate->setText(QStringLiteral("25.0"));
        aspect->setText(QStringLiteral("16 / 9"));
        dialog.findChild<QDialogButtonBox *>()->button(QDialogButtonBox::Save)->click();
        QCOMPARE(dialog.result(), QDialog::Accepted);
        QCOMPARE(dialog.policy().value(QStringLiteral("frame_rate")).toString(), QStringLiteral("25.0"));
        QCOMPARE(dialog.policy().value(QStringLiteral("display_aspect_ratio")).toString(), QStringLiteral("16 / 9"));
    }

    void blankMediaListsMeanAllowAny() {
        auto policy = SettingsStore::defaultPolicy();
        for (const auto &key : {QStringLiteral("allowed_extensions"), QStringLiteral("allowed_containers"), QStringLiteral("allowed_codecs")})
            policy.insert(key, QJsonArray{QStringLiteral(" \t ")});
        SettingsDialog dialog(policy, SettingsStore::defaultSort(), QStringLiteral("system"));
        dialog.findChild<QDialogButtonBox *>()->button(QDialogButtonBox::Save)->click();
        QCOMPARE(dialog.result(), QDialog::Accepted);
        for (const auto &key : {QStringLiteral("allowed_extensions"), QStringLiteral("allowed_containers"), QStringLiteral("allowed_codecs")})
            QVERIFY2(dialog.policy().value(key).toArray().isEmpty(), qPrintable(key));
    }

    void mediaListsTrimEntriesAndIgnoreEmptyParts() {
        auto policy = SettingsStore::defaultPolicy();
        policy.insert(QStringLiteral("allowed_extensions"), QJsonArray{QStringLiteral(" mpg , , mp4, \t ")});
        SettingsDialog dialog(policy, SettingsStore::defaultSort(), QStringLiteral("system"));
        dialog.findChild<QDialogButtonBox *>()->button(QDialogButtonBox::Save)->click();
        QCOMPARE(dialog.result(), QDialog::Accepted);
        QCOMPARE(dialog.policy().value(QStringLiteral("allowed_extensions")).toArray(),
            (QJsonArray{QStringLiteral("mpg"), QStringLiteral("mp4")}));
    }

    void rejectsInvalidRatioOrNonPositiveNumber() {
        for (const auto &badValue : {QStringLiteral("0"), QStringLiteral("0.0"), QStringLiteral("-25"), QStringLiteral("0/1"), QStringLiteral("16:0")}) {
            SettingsDialog dialog(SettingsStore::defaultPolicy(), SettingsStore::defaultSort(), QStringLiteral("system"));
            auto *rate = dialog.findChild<QLineEdit *>(QStringLiteral("frameRate"));
            QVERIFY(rate);
            rate->setText(badValue);
            dialog.findChild<QDialogButtonBox *>()->button(QDialogButtonBox::Save)->click();
            QCOMPARE(dialog.result(), 0);
            bool communicated = false;
            for (const auto *label : dialog.findChildren<QLabel *>())
                if (label->text().contains(QStringLiteral("positive numbers or ratios"))) communicated = true;
            QVERIFY2(communicated, qPrintable(QStringLiteral("Expected error for: ") + badValue));
        }
    }

    void acceptsDecimalFormsSupportedByEngine() {
        for (const auto &value : {QStringLiteral("25."), QStringLiteral(".5"), QStringLiteral("1. / .5")}) {
            SettingsDialog dialog(SettingsStore::defaultPolicy(), SettingsStore::defaultSort(), QStringLiteral("system"));
            dialog.findChild<QLineEdit *>(QStringLiteral("frameRate"))->setText(value);
            dialog.findChild<QDialogButtonBox *>()->button(QDialogButtonBox::Save)->click();
            QCOMPARE(dialog.result(), QDialog::Accepted);
        }
    }

    void rejectsNonFiniteOrUnderflowingRatios() {
        const QString large = QStringLiteral("1") + QString(308, QLatin1Char('0'));
        const QString small = QStringLiteral("0.") + QString(307, QLatin1Char('0')) + QLatin1Char('1');
        const QStringList invalid{QString(400, QLatin1Char('9')), QStringLiteral("0.") + QString(400, QLatin1Char('0')) + QLatin1Char('1'),
            large + QLatin1Char('/') + small, small + QLatin1Char('/') + large};
        for (const auto &value : invalid) {
            SettingsDialog dialog(SettingsStore::defaultPolicy(), SettingsStore::defaultSort(), QStringLiteral("system"));
            dialog.findChild<QLineEdit *>(QStringLiteral("aspectRatio"))->setText(value);
            dialog.findChild<QDialogButtonBox *>()->button(QDialogButtonBox::Save)->click();
            QCOMPARE(dialog.result(), 0);
        }
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

    void persistsCombinedConfigurationAtomically() {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        SettingsStore store(directory.path());
        QString error;
        QJsonObject sort = SettingsStore::defaultSort();
        sort.insert(QStringLiteral("folder_count"), 6);
        QJsonObject policy = SettingsStore::defaultPolicy();
        policy.insert(QStringLiteral("delete_rejected"), false);

        QVERIFY2(store.saveConfiguration(policy, sort, QStringLiteral("light"), &error), qPrintable(error));

        SettingsStore reader(directory.path());
        QCOMPARE(reader.sort().value(QStringLiteral("folder_count")).toInt(), 6);
        QCOMPARE(reader.policy().value(QStringLiteral("delete_rejected")).toBool(), false);
        QCOMPARE(reader.appearance(), QStringLiteral("light"));
    }

    void restoresConfigurationWhenAppearanceCannotBeSaved() {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        SettingsStore store(directory.path());
        QString error;
        const auto originalPolicy = SettingsStore::defaultPolicy();
        const auto originalSort = SettingsStore::defaultSort();
        QVERIFY(store.savePolicy(originalPolicy, &error));
        QVERIFY(store.saveSort(originalSort, &error));
        // A directory at the final destination makes QSaveFile fail after the
        // two JSON settings have already been replaced.
        QVERIFY(QDir().mkdir(directory.path() + QStringLiteral("/appearance")));
        auto changedPolicy = originalPolicy;
        changedPolicy.insert(QStringLiteral("enabled"), false);
        auto changedSort = originalSort;
        changedSort.insert(QStringLiteral("folder_count"), 3);

        QVERIFY(!store.saveConfiguration(changedPolicy, changedSort, QStringLiteral("dark"), &error));
        QVERIFY(!error.isEmpty());
        QCOMPARE(store.policy(), originalPolicy);
        QCOMPARE(store.sort(), originalSort);
        QVERIFY(QFile::exists(directory.path() + QStringLiteral("/media-policy.json")));
        QVERIFY(QFile::exists(directory.path() + QStringLiteral("/sort-settings.json")));
    }

    void rollbackPreservesEmptyFilesAndRemovesNewFiles() {
        for (const bool hadEmptyFiles : {false, true}) {
            QTemporaryDir directory;
            QVERIFY(directory.isValid());
            const QStringList names{QStringLiteral("media-policy.json"), QStringLiteral("sort-settings.json")};
            if (hadEmptyFiles) {
                for (const auto &name : names) {
                    QFile file(directory.path() + QLatin1Char('/') + name);
                    QVERIFY(file.open(QIODevice::WriteOnly));
                }
            }
            QVERIFY(QDir().mkdir(directory.path() + QStringLiteral("/appearance")));
            SettingsStore store(directory.path());
            QString error;
            QVERIFY(!store.saveConfiguration(SettingsStore::defaultPolicy(), SettingsStore::defaultSort(), QStringLiteral("dark"), &error));
            for (const auto &name : names) {
                QFile file(directory.path() + QLatin1Char('/') + name);
                QCOMPARE(file.exists(), hadEmptyFiles);
                if (hadEmptyFiles) QCOMPARE(file.size(), qint64(0));
            }
        }
    }
};

QTEST_MAIN(SettingsDialogTests)
#include "tests.moc"
