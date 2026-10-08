#pragma once

#include <QDialog>
#include <QJsonObject>

class QCheckBox;
class QComboBox;
class QLineEdit;
class QSpinBox;
class QLabel;

class SettingsDialog final : public QDialog {
    Q_OBJECT
public:
    SettingsDialog(const QJsonObject &policy, const QJsonObject &sort, const QString &appearance, QWidget *parent = nullptr);
    QJsonObject policy() const;
    QJsonObject sort() const;
    QString appearance() const;

protected:
    void accept() override;

private:
    QSpinBox *folderCount_;
    QLineEdit *folderPrefix_;
    QLineEdit *hours_;
    QSpinBox *minutes_;
    QSpinBox *seconds_;
    QCheckBox *filter_;
    QCheckBox *deleteRejected_;
    QLineEdit *extensions_;
    QLineEdit *containers_;
    QLineEdit *codecs_;
    QLineEdit *width_;
    QLineEdit *height_;
    QLineEdit *rate_;
    QLineEdit *aspect_;
    QComboBox *standard_;
    QComboBox *scan_;
    QComboBox *orientation_;
    QComboBox *appearance_;
    QLabel *error_;
};
