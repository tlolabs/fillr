#include "MainWindow.h"

#include "Engine.h"
#include "SettingsDialog.h"
#include "UpdateService.h"

#include <QAction>
#include <QAccessible>
#include <QApplication>
#include <QCheckBox>
#include <QCloseEvent>
#include <QDesktopServices>
#include <QDialog>
#include <QDir>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QFileDialog>
#include <QFont>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QLabel>
#include <QMenuBar>
#include <QMessageBox>
#include <QMimeData>
#include <QPlainTextEdit>
#include <QProcess>
#include <QProgressBar>
#include <QPushButton>
#include <QScrollArea>
#include <QStatusBar>
#include <QStyle>
#include <QStyleHints>
#include <QSystemTrayIcon>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>
#include <algorithm>

#ifdef Q_OS_LINUX
#include "LinuxNotification.h"
#endif

namespace {
QLabel *makeLabel(const QString &value, QWidget *parent, bool wrap = true) {
    auto *label = new QLabel(value, parent); label->setWordWrap(wrap); label->setTextInteractionFlags(Qt::TextSelectableByMouse | Qt::TextSelectableByKeyboard); return label;
}
void setAccessibleLabel(QLabel *label, const QString &name, const QString &value) {
    const QString accessible = name + QStringLiteral(": ") + value;
    if (label->text() == value && label->accessibleName() == accessible) return;
    label->setText(value);
    label->setAccessibleName(accessible);
    QAccessibleEvent announcement(label, QAccessible::NameChanged);
    QAccessible::updateAccessibility(&announcement);
}
}

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent), updates_(new UpdateService(this)), policy_(settings_.policy()), sort_(settings_.sort()), appearance_(settings_.appearance()),
      worker_(new EngineWorker) {
#ifdef Q_OS_MACOS
    setWindowTitle(tr("FILLR — Internal Qt Reference"));
#else
    setWindowTitle(tr("FILLR"));
#endif
    resize(800, 800); setMinimumSize(440, 400); setAcceptDrops(true);
    auto *fileMenu = menuBar()->addMenu(tr("&File"));
    auto *openAction = fileMenu->addAction(tr("Choose Download Folder…"), QKeySequence::Open, this, &MainWindow::chooseFolder);
    openAction->setStatusTip(tr("Choose the folder where CNN footage arrives"));
    auto *openOutputAction = fileMenu->addAction(tr("Open Last Export"), this, [this] { if (!output_.isEmpty()) QDesktopServices::openUrl(QUrl::fromLocalFile(output_)); });
    fileMenu->addSeparator(); fileMenu->addAction(tr("Quit"), QKeySequence::Quit, qApp, &QApplication::quit);
    auto *editMenu = menuBar()->addMenu(tr("&Edit"));
    settingsAction_ = editMenu->addAction(tr("Settings…"), QKeySequence(Qt::CTRL | Qt::Key_Comma), this, &MainWindow::editSettings);
    settingsAction_->setMenuRole(QAction::PreferencesRole);
    auto *viewMenu = menuBar()->addMenu(tr("&View"));
    refreshAction_ = viewMenu->addAction(tr("Refresh"), QKeySequence(Qt::Key_F5), this, &MainWindow::refresh);
    viewMenu->addAction(tr("Show / Hide Overlay"), this, &MainWindow::toggleOverlay);
    auto *helpMenu = menuBar()->addMenu(tr("&Help"));
    helpMenu->addAction(tr("About FILLR"), this, [this] {
        QMessageBox::about(this, tr("About FILLR"), tr("FILLR %1\nCNN footage collection and Comp folder preparation.").arg(qApp->applicationVersion()));
    });

    auto *scroll = new QScrollArea(this); scroll->setWidgetResizable(true); setCentralWidget(scroll);
    auto *body = new QWidget(scroll); auto *layout = new QVBoxLayout(body);
    layout->setContentsMargins(24, 24, 24, 24); layout->setSpacing(14);
    auto *heading = makeLabel(tr("FILLR"), body); QFont headingFont = heading->font(); headingFont.setBold(true); headingFont.setPointSize(headingFont.pointSize() + 5); heading->setFont(headingFont); layout->addWidget(heading);
    auto *version = makeLabel(tr("Version %1").arg(qApp->applicationVersion()), body);
#ifdef Q_OS_MACOS
    version->setText(version->text() + tr(" · INTERNAL ONLY · production updates disabled"));
#endif
    layout->addWidget(version);
    auto *buttons = new QHBoxLayout;
    chooseButton_ = new QPushButton(tr("Choose CNN Download Folder…"), body); connect(chooseButton_, &QPushButton::clicked, this, &MainWindow::chooseFolder); buttons->addWidget(chooseButton_);
    settingsButton_ = new QPushButton(tr("Settings…"), body); connect(settingsButton_, &QPushButton::clicked, this, &MainWindow::editSettings); buttons->addWidget(settingsButton_);
    refreshButton_ = new QPushButton(tr("Refresh"), body); connect(refreshButton_, &QPushButton::clicked, this, &MainWindow::refresh); buttons->addWidget(refreshButton_);
    auto *overlayButton = new QPushButton(tr("Show / Hide Overlay"), body); connect(overlayButton, &QPushButton::clicked, this, &MainWindow::toggleOverlay); buttons->addWidget(overlayButton);
    buttons->addStretch(); layout->addLayout(buttons);
    folderLabel_ = makeLabel(tr("Choose the folder where CNN MPG files arrive"), body); setAccessibleLabel(folderLabel_, tr("Selected download folder"), folderLabel_->text()); layout->addWidget(folderLabel_);
    readyLabel_ = makeLabel({}, body); setAccessibleLabel(readyLabel_, tr("Readiness"), tr("Not ready to build")); layout->addWidget(readyLabel_);
    statusLabel_ = makeLabel(tr("Choose a download folder"), body); setAccessibleLabel(statusLabel_, tr("Current status"), statusLabel_->text()); layout->addWidget(statusLabel_);
    auto *metrics = new QHBoxLayout;
    auto *remainingColumn = new QVBoxLayout; remainingColumn->addWidget(makeLabel(tr("Footage remaining"), body));
    remainingLabel_ = makeLabel(clock(static_cast<qulonglong>(sort_.value(QStringLiteral("total_ms")).toDouble(8470000))), body);
    QFont large = remainingLabel_->font(); large.setPointSize(large.pointSize() + 20); remainingLabel_->setFont(large); setAccessibleLabel(remainingLabel_, tr("Footage remaining"), remainingLabel_->text()); remainingColumn->addWidget(remainingLabel_);
    metrics->addLayout(remainingColumn);
    auto *availableColumn = new QVBoxLayout; availableColumn->addWidget(makeLabel(tr("Unique footage"), body));
    availableLabel_ = makeLabel(tr("0:00"), body); setAccessibleLabel(availableLabel_, tr("Unique footage available"), availableLabel_->text()); availableColumn->addWidget(availableLabel_);
    countsLabel_ = makeLabel(tr("0 usable clips"), body); availableColumn->addWidget(countsLabel_); metrics->addLayout(availableColumn); metrics->addStretch(); layout->addLayout(metrics);
    progress_ = new QProgressBar(body); progress_->setAccessibleName(tr("Footage collected")); progress_->setRange(0, 1000); progress_->setValue(0); layout->addWidget(progress_);
    busyProgress_ = new QProgressBar(body); busyProgress_->setAccessibleName(tr("Operation in progress")); busyProgress_->setRange(0, 0); busyProgress_->hide(); layout->addWidget(busyProgress_);
    auto *buildButtons = new QHBoxLayout;
    buildButton_ = new QPushButton(tr("Build Folders"), body); buildButton_->setEnabled(false);
    connect(buildButton_, &QPushButton::clicked, this, [this] {
        setBusy(true);
        setAccessibleLabel(statusLabel_, tr("Current status"), tr("Building Comp folders…"));
        statusBar()->showMessage(statusLabel_->text());
        emit requestBuild();
    }); buildButtons->addWidget(buildButton_);
    openOutputButton_ = new QPushButton(tr("Open Last Export"), body); openOutputButton_->setEnabled(false);
    connect(openOutputButton_, &QPushButton::clicked, openOutputAction, &QAction::trigger); buildButtons->addWidget(openOutputButton_); buildButtons->addStretch(); layout->addLayout(buildButtons);
    layout->addWidget(makeLabel(tr("Folder preview"), body));
    preview_ = new QPlainTextEdit(body); preview_->setReadOnly(true); preview_->setPlainText(tr("The %1-folder layout will appear when enough footage is ready.").arg(sort_.value(QStringLiteral("folder_count")).toInt(14)));
    preview_->setAccessibleName(tr("Folder preview")); preview_->setMinimumHeight(120); layout->addWidget(preview_);
    notesLabel_ = makeLabel({}, body); notesLabel_->setAccessibleName(tr("Scan details")); layout->addWidget(notesLabel_);
    if (updates_->supported()) {
        auto *updateRow = new QHBoxLayout;
        checkUpdateButton_ = new QPushButton(tr("Check for Updates…"), body);
        connect(checkUpdateButton_, &QPushButton::clicked, this, [this] { if (!busy_ && !updates_->busy()) updates_->check(true); });
        updateRow->addWidget(checkUpdateButton_);
        automaticCheck_ = new QCheckBox(tr("Automatically check for updates"), body);
        automaticCheck_->setChecked(updates_->automatic());
        connect(automaticCheck_, &QCheckBox::toggled, this, [this](bool enabled) { updates_->setAutomatic(enabled); });
        updateRow->addWidget(automaticCheck_); updateRow->addStretch(); layout->addLayout(updateRow);
        connect(updates_, &UpdateService::automaticChanged, this, [this](bool enabled) { automaticCheck_->blockSignals(true); automaticCheck_->setChecked(enabled); automaticCheck_->blockSignals(false); });
        connect(updates_, &UpdateService::checkResult, this, [this](bool manual, const QJsonObject &result) {
            if (!result.value(QStringLiteral("available")).toBool()) { if (manual) showError(tr("No newer compatible stable update is available.")); return; }
            if (!manual) { showError(tr("A stable FILLR update is available. Choose Check for Updates to install it.")); return; }
            const QString version = result.value(QStringLiteral("version")).toString();
            const QString notes = result.value(QStringLiteral("notes_url")).toString();
            if (QMessageBox::question(this, tr("Update FILLR"), tr("Update FILLR to %1?\nThe signed package will be authenticated before installation. Media and settings are retained.\nRelease notes: %2").arg(version, notes)) == QMessageBox::Yes) {
                updateBlocking_ = true; setBusy(true); setAccessibleLabel(statusLabel_, tr("Current status"), tr("Downloading, verifying and installing update…")); updates_->install(version);
            }
        });
        connect(updates_, &UpdateService::installResult, this, [this](const QString &message) {
            updateBlocking_ = false; setBusy(false);
            const auto choice = QMessageBox::question(this, tr("Update installed"), message + tr("\nQuit FILLR now?"));
            if (choice == QMessageBox::Yes) {
#ifdef Q_OS_LINUX
                const QString image = qEnvironmentVariable("APPIMAGE");
                if (!image.isEmpty()) QProcess::startDetached(image, {});
#endif
                close();
            }
        });
        connect(updates_, &UpdateService::failed, this, [this](const QString &message) {
            if (updateBlocking_) { updateBlocking_ = false; setBusy(false); }
            showError(message);
        });
        updateTimer_ = new QTimer(this); updateTimer_->setInterval(60 * 60 * 1000);
        connect(updateTimer_, &QTimer::timeout, this, [this] { updates_->check(false); });
        updateTimer_->start();
        QTimer::singleShot(0, this, [this] { updates_->check(false); });
    }
    errorLabel_ = makeLabel({}, body); errorLabel_->setAccessibleName(tr("Error")); layout->addWidget(errorLabel_);
    layout->addStretch(); scroll->setWidget(body);
    statusBar()->showMessage(tr("Choose a download folder"));
    tray_ = new QSystemTrayIcon(QIcon::fromTheme(QStringLiteral("dialog-information")), this);
    if (QSystemTrayIcon::isSystemTrayAvailable()) tray_->show();

    worker_->moveToThread(&engineThread_);
    connect(&engineThread_, &QThread::finished, worker_, &QObject::deleteLater);
    connect(this, &MainWindow::requestOpen, worker_, &EngineWorker::open, Qt::QueuedConnection);
    connect(this, &MainWindow::requestSettings, worker_, &EngineWorker::applySettings, Qt::QueuedConnection);
    connect(this, &MainWindow::requestPoll, worker_, &EngineWorker::poll, Qt::QueuedConnection);
    connect(this, &MainWindow::requestRefresh, worker_, &EngineWorker::refresh, Qt::QueuedConnection);
    connect(this, &MainWindow::requestBuild, worker_, &EngineWorker::build, Qt::QueuedConnection);
    connect(worker_, &EngineWorker::opened, this, [this](const QString &folder) {
        opening_ = false;
        folder_ = folder; setAccessibleLabel(folderLabel_, tr("Selected download folder"), folder); ready_ = false; output_.clear();
        QString error; if (!settings_.saveFolder(folder, &error)) showError(error);
        setBusy(false);
    });
    connect(worker_, &EngineWorker::snapshotReady, this, &MainWindow::updateSnapshot);
    connect(worker_, &EngineWorker::buildFinished, this, &MainWindow::buildFinished);
    connect(worker_, &EngineWorker::failed, this, [this](const QString &message) {
        if (opening_) { opening_ = false; setBusy(false); }
        showError(message);
    });
    engineThread_.start();
    pollTimer_ = new QTimer(this); pollTimer_->setInterval(1000);
    connect(pollTimer_, &QTimer::timeout, this, [this] { if (!busy_ && !folder_.isEmpty() && !pollPending_) { pollPending_ = true; emit requestPoll(); } });
    pollTimer_->start();
    applyAppearance();
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this, [this] { if (appearance_ == QLatin1String("system")) applyAppearance(); });
#endif
    const QString savedFolder = settings_.folder(); if (!savedFolder.isEmpty()) QTimer::singleShot(0, this, [this, savedFolder] { openFolder(savedFolder); });
}

MainWindow::~MainWindow() {
    pollTimer_->stop(); engineThread_.quit(); engineThread_.wait();
}

void MainWindow::setBusy(bool busy) {
    busy_ = busy; busyProgress_->setVisible(busy);
    chooseButton_->setEnabled(!busy); settingsButton_->setEnabled(!busy); settingsAction_->setEnabled(!busy);
    refreshButton_->setEnabled(!busy && !folder_.isEmpty()); refreshAction_->setEnabled(!busy && !folder_.isEmpty());
    buildButton_->setEnabled(!busy && ready_); openOutputButton_->setEnabled(!busy && !output_.isEmpty());
    if (checkUpdateButton_) checkUpdateButton_->setEnabled(!busy);
    if (automaticCheck_) automaticCheck_->setEnabled(!busy);
}

void MainWindow::chooseFolder() {
    const QString folder = QFileDialog::getExistingDirectory(this, tr("Choose CNN download folder"), folder_);
    if (!folder.isEmpty()) openFolder(folder);
}

void MainWindow::openFolder(const QString &folder) {
    if (busy_) return;
    if (!QDir(folder).exists()) { showError(tr("The selected folder no longer exists. Choose an existing download folder.")); return; }
    errorLabel_->clear(); opening_ = true; setBusy(true); emit requestOpen(folder, policy_, sort_);
}

void MainWindow::editSettings() {
    if (busy_) return;
    SettingsDialog dialog(policy_, sort_, appearance_, this);
    if (dialog.exec() != QDialog::Accepted) return;
    QString error;
    if (!settings_.savePolicy(dialog.policy(), &error) || !settings_.saveSort(dialog.sort(), &error) || !settings_.saveAppearance(dialog.appearance(), &error)) { showError(error); return; }
    policy_ = dialog.policy(); sort_ = dialog.sort(); appearance_ = dialog.appearance(); applyAppearance();
    emit requestSettings(policy_, sort_);
}

void MainWindow::updateSnapshot(const QJsonObject &snapshot) {
    pollPending_ = false;
    if (opening_) return;
    const bool wasReady = ready_;
    ready_ = snapshot.value(QStringLiteral("status")).toString() == QLatin1String("ready");
    const QString status = snapshot.value(QStringLiteral("message")).toString();
    setAccessibleLabel(statusLabel_, tr("Current status"), status);
    statusBar()->showMessage(status);
    setAccessibleLabel(readyLabel_, tr("Readiness"), ready_ ? tr("Ready to build") : tr("Not ready to build"));
    const qulonglong available = static_cast<qulonglong>(snapshot.value(QStringLiteral("available_ms")).toDouble());
    const qulonglong remaining = static_cast<qulonglong>(snapshot.value(QStringLiteral("remaining_ms")).toDouble());
    const qulonglong target = static_cast<qulonglong>(sort_.value(QStringLiteral("total_ms")).toDouble(8470000));
    setAccessibleLabel(remainingLabel_, tr("Footage remaining"), clock(remaining));
    setAccessibleLabel(availableLabel_, tr("Unique footage available"), clock(available));
    progress_->setValue(target ? static_cast<int>(1000.0 * static_cast<double>(std::min(available, target)) / static_cast<double>(target)) : 0);
    const int clips = snapshot.value(QStringLiteral("clips")).toArray().size();
    const int pending = snapshot.value(QStringLiteral("pending")).toArray().size();
    countsLabel_->setText(tr("%1 usable clips · %2 pending").arg(clips).arg(pending));
    setAccessibleLabel(notesLabel_, tr("Scan details"), tr("%1 excluded files · %2 rejected deleted · %3 exact duplicates deleted")
        .arg(snapshot.value(QStringLiteral("excluded")).toArray().size())
        .arg(snapshot.value(QStringLiteral("rejection_log")).toArray().size())
        .arg(snapshot.value(QStringLiteral("duplicate_log")).toArray().size()));
    QStringList lines;
    for (const auto &value : snapshot.value(QStringLiteral("plan")).toObject().value(QStringLiteral("assignments")).toArray()) {
        const auto assignment = value.toObject();
        lines.append(tr("%1 %2: %3 · %4 clips").arg(sort_.value(QStringLiteral("folder_prefix")).toString(QStringLiteral("Comp")))
            .arg(assignment.value(QStringLiteral("comp")).toInt()).arg(clock(static_cast<qulonglong>(assignment.value(QStringLiteral("duration_ms")).toDouble())))
            .arg(assignment.value(QStringLiteral("filenames")).toArray().size()));
    }
    preview_->setPlainText(lines.isEmpty() ? tr("The %1-folder layout will appear when enough footage is ready.").arg(sort_.value(QStringLiteral("folder_count")).toInt(14)) : lines.join(QLatin1Char('\n')));
    if (overlay_) { overlayStatus_->setText(ready_ ? tr("Ready to build") : tr("Footage remaining")); overlayRemaining_->setText(clock(remaining)); overlayProgress_->setValue(progress_->value()); }
    setBusy(busy_);
    if (ready_ && !wasReady) {
        const QString title = tr("FILLR is ready");
        const QString detail = tr("Footage is ready for %1 folders.").arg(sort_.value(QStringLiteral("folder_count")).toInt(14));
#ifdef Q_OS_LINUX
        showLinuxReadyNotification(title, detail);
#else
        if (tray_->isVisible()) tray_->showMessage(title, detail);
#endif
    }
}

void MainWindow::buildFinished(const QJsonObject &result) {
    setBusy(false);
    if (!result.value(QStringLiteral("ok")).toBool()) { showError(result.value(QStringLiteral("error")).toString(tr("The export failed."))); return; }
    output_ = result.value(QStringLiteral("result")).toObject().value(QStringLiteral("output_folder")).toString();
    openOutputButton_->setEnabled(!output_.isEmpty());
    setAccessibleLabel(statusLabel_, tr("Current status"), tr("Comp folders created in %1").arg(output_));
    statusBar()->showMessage(statusLabel_->text());
}

void MainWindow::showError(const QString &message) {
    pollPending_ = false;
    setAccessibleLabel(errorLabel_, tr("Error"), message);
    statusBar()->showMessage(message);
}

void MainWindow::refresh() { if (!busy_ && !folder_.isEmpty()) emit requestRefresh(); }

void MainWindow::toggleOverlay() {
    if (overlay_) { overlay_->close(); return; }
    overlay_ = new QDialog(this, Qt::Tool | Qt::WindowStaysOnTopHint);
    overlay_->setWindowTitle(tr("FILLR Progress")); overlay_->resize(310, 170); overlay_->setMinimumSize(240, 150);
    auto *layout = new QVBoxLayout(overlay_);
    overlayStatus_ = makeLabel(ready_ ? tr("Ready to build") : tr("Footage remaining"), overlay_); layout->addWidget(overlayStatus_);
    overlayRemaining_ = makeLabel(remainingLabel_->text(), overlay_); QFont font = overlayRemaining_->font(); font.setPointSize(font.pointSize() + 16); overlayRemaining_->setFont(font); layout->addWidget(overlayRemaining_);
    overlayProgress_ = new QProgressBar(overlay_); overlayProgress_->setRange(0, 1000); overlayProgress_->setValue(progress_->value()); overlayProgress_->setAccessibleName(tr("Footage collected")); layout->addWidget(overlayProgress_);
    connect(overlay_, &QDialog::finished, this, [this] { overlay_->deleteLater(); overlay_ = nullptr; }); overlay_->show();
}

void MainWindow::applyAppearance() {
    static const QString platformStyle = qApp->style()->objectName();
    const bool dark = appearance_ == QLatin1String("dark");
    const QString wantedStyle = dark ? QStringLiteral("Fusion") : platformStyle;
    if (qApp->style()->objectName().compare(wantedStyle, Qt::CaseInsensitive) != 0)
        qApp->setStyle(wantedStyle);
    if (appearance_ == QLatin1String("system")) {
        qApp->setStyleSheet({});
        qApp->setPalette(QPalette());
        return;
    }
    QPalette palette = qApp->style()->standardPalette();
    const QColor window = dark ? QColor(QStringLiteral("#303030")) : QColor(QStringLiteral("#f7f7f7"));
    const QColor base = dark ? QColor(QStringLiteral("#222222")) : QColor(Qt::white);
    const QColor text = dark ? QColor(Qt::white) : QColor(Qt::black);
    palette.setColor(QPalette::Window, window); palette.setColor(QPalette::Base, base);
    palette.setColor(QPalette::Button, window); palette.setColor(QPalette::WindowText, text);
    palette.setColor(QPalette::Text, text); palette.setColor(QPalette::ButtonText, text);
    palette.setColor(QPalette::Highlight, dark ? QColor(QStringLiteral("#6a9fff")) : QColor(QStringLiteral("#1457b3")));
    palette.setColor(QPalette::HighlightedText, dark ? Qt::black : Qt::white);
    qApp->setPalette(palette);
    // The native macOS Qt style paints some control labels with its own color,
    // ignoring ButtonText from the application palette in forced Dark mode.
    qApp->setStyleSheet(dark ? QStringLiteral(
        "QPushButton, QComboBox, QSpinBox { color: white; } "
        "QPushButton:disabled, QComboBox:disabled, QSpinBox:disabled { color: #ababab; }") : QString());
}

QString MainWindow::clock(qulonglong milliseconds) {
    const qulonglong seconds = milliseconds / 1000 + (milliseconds % 1000 ? 1 : 0);
    return QStringLiteral("%1:%2").arg(seconds / 60).arg(seconds % 60, 2, 10, QLatin1Char('0'));
}

void MainWindow::closeEvent(QCloseEvent *event) {
    if (busy_) { event->ignore(); showError(tr("Wait for the current operation to finish before closing FILLR.")); return; }
    QMainWindow::closeEvent(event);
}

void MainWindow::dragEnterEvent(QDragEnterEvent *event) {
    if (!busy_ && event->mimeData()->hasUrls() && event->mimeData()->urls().size() == 1 && event->mimeData()->urls().first().isLocalFile()) event->acceptProposedAction();
}

void MainWindow::dropEvent(QDropEvent *event) {
    const QString path = event->mimeData()->urls().first().toLocalFile();
    if (QDir(path).exists()) { openFolder(path); event->acceptProposedAction(); }
}
