#pragma once

#include "Settings.h"

#include <QJsonObject>
#include <QMainWindow>
#include <QThread>

class EngineWorker;
class QAction;
class QLabel;
class QPlainTextEdit;
class QProgressBar;
class QPushButton;
class QSystemTrayIcon;
class QTimer;
class QDialog;
class QCheckBox;
class UpdateService;

class MainWindow final : public QMainWindow {
    Q_OBJECT
public:
    explicit MainWindow(QWidget *parent = nullptr);
    ~MainWindow() override;

signals:
    void requestOpen(const QString &folder, const QJsonObject &policy, const QJsonObject &sort);
    void requestSettings(const QJsonObject &policy, const QJsonObject &sort);
    void requestPoll();
    void requestRefresh();
    void requestBuild();

protected:
    void closeEvent(QCloseEvent *event) override;
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dropEvent(QDropEvent *event) override;

private slots:
    void chooseFolder();
    void openFolder(const QString &folder);
    void editSettings();
    void updateSnapshot(const QJsonObject &snapshot);
    void buildFinished(const QJsonObject &result);
    void showError(const QString &message);
    void toggleOverlay();
    void refresh();

private:
    SettingsStore settings_;
    UpdateService *updates_;
    QJsonObject policy_;
    QJsonObject sort_;
    QString appearance_;
    QThread engineThread_;
    EngineWorker *worker_;
    QTimer *pollTimer_;
    QSystemTrayIcon *tray_;
    QLabel *folderLabel_;
    QLabel *statusLabel_;
    QLabel *remainingLabel_;
    QLabel *availableLabel_;
    QLabel *countsLabel_;
    QLabel *notesLabel_;
    QLabel *errorLabel_;
    QLabel *readyLabel_;
    QProgressBar *progress_;
    QProgressBar *busyProgress_;
    QPlainTextEdit *preview_;
    QPushButton *buildButton_;
    QPushButton *openOutputButton_;
    QPushButton *refreshButton_;
    QPushButton *chooseButton_;
    QPushButton *settingsButton_;
    QPushButton *checkUpdateButton_ = nullptr;
    QCheckBox *automaticCheck_ = nullptr;
    QTimer *updateTimer_ = nullptr;
    QAction *settingsAction_;
    QAction *refreshAction_;
    QDialog *overlay_ = nullptr;
    QLabel *overlayStatus_ = nullptr;
    QLabel *overlayRemaining_ = nullptr;
    QProgressBar *overlayProgress_ = nullptr;
    QString folder_;
    QString output_;
    bool ready_ = false;
    bool busy_ = false;
    bool updateBlocking_ = false;
    bool opening_ = false;
    bool pollPending_ = false;
    void setBusy(bool busy);
    void applyAppearance();
    static QString clock(qulonglong milliseconds);
};
