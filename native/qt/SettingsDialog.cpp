#include "SettingsDialog.h"

#include <QCheckBox>
#include <QAccessible>
#include <QComboBox>
#include <QDialogButtonBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QLabel>
#include <QLineEdit>
#include <QRegularExpression>
#include <QRegularExpressionValidator>
#include <QScrollArea>
#include <QSpinBox>
#include <QVBoxLayout>
#include <limits>

namespace {
QString join(const QJsonValue &value) {
    QStringList result;
    for (const auto &item : value.toArray()) result.append(item.toString());
    return result.join(QStringLiteral(", "));
}
QJsonArray split(const QString &value) {
    QJsonArray result;
    for (const QString &part : value.split(QLatin1Char(','), Qt::SkipEmptyParts)) result.append(part.trimmed());
    return result;
}
QString optionalText(const QJsonValue &value) { return value.isNull() || value.isUndefined() ? QString() : value.toString(); }
QString optionalNumber(const QJsonValue &value) { return value.isNull() || value.isUndefined() ? QString() : QString::number(value.toInt()); }
QJsonValue positiveNumber(const QString &value) { return value.trimmed().isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(value.toInt()); }
QJsonValue nullableText(const QString &value) { return value.trimmed().isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(value.trimmed()); }
}

SettingsDialog::SettingsDialog(const QJsonObject &policy, const QJsonObject &sort, const QString &appearance, QWidget *parent)
    : QDialog(parent) {
    setWindowTitle(tr("Settings"));
    resize(570, 710);
    setMinimumSize(380, 410);
    auto *root = new QVBoxLayout(this);
    auto *scroll = new QScrollArea(this);
    scroll->setWidgetResizable(true);
    auto *body = new QWidget(scroll);
    auto *layout = new QVBoxLayout(body);
    auto *heading = new QLabel(tr("Sorting"), body);
    QFont headingFont = heading->font(); headingFont.setBold(true); headingFont.setPointSize(headingFont.pointSize() + 2);
    heading->setFont(headingFont);
    layout->addWidget(heading);
    auto *sorting = new QFormLayout;
    folderCount_ = new QSpinBox(body); folderCount_->setRange(1, 100); folderCount_->setValue(sort.value(QStringLiteral("folder_count")).toInt(14));
    folderPrefix_ = new QLineEdit(sort.value(QStringLiteral("folder_prefix")).toString(QStringLiteral("Comp")), body);
    folderCount_->setObjectName(QStringLiteral("folderCount"));
    folderPrefix_->setObjectName(QStringLiteral("folderPrefix"));
    folderPrefix_->setMaxLength(80);
    const auto totalSeconds = static_cast<qulonglong>(sort.value(QStringLiteral("total_ms")).toDouble(8470000)) / 1000;
    hours_ = new QLineEdit(QString::number(totalSeconds / 3600), body);
    hours_->setObjectName(QStringLiteral("hours"));
    hours_->setValidator(new QRegularExpressionValidator(QRegularExpression(QStringLiteral("[0-9]{1,12}")), hours_));
    minutes_ = new QSpinBox(body); minutes_->setRange(0, 59); minutes_->setValue((totalSeconds / 60) % 60);
    seconds_ = new QSpinBox(body); seconds_->setRange(0, 59); seconds_->setValue(totalSeconds % 60);
    sorting->addRow(tr("Number of folders (1–100)"), folderCount_);
    sorting->addRow(tr("Folder name prefix"), folderPrefix_);
    sorting->addRow(tr("Hours"), hours_);
    sorting->addRow(tr("Minutes"), minutes_);
    sorting->addRow(tr("Seconds"), seconds_);
    layout->addLayout(sorting);
    auto *mediaHeading = new QLabel(tr("Media Preferences"), body); mediaHeading->setFont(headingFont); layout->addWidget(mediaHeading);
    auto *explanation = new QLabel(tr("NTSC 1080i is the default. FILLR waits for a final filename and ten unchanged seconds before deleting rejected media."), body);
    explanation->setWordWrap(true); layout->addWidget(explanation);
    filter_ = new QCheckBox(tr("Filter media"), body); filter_->setChecked(policy.value(QStringLiteral("enabled")).toBool(true)); layout->addWidget(filter_);
    deleteRejected_ = new QCheckBox(tr("Delete rejected completed downloads"), body);
    deleteRejected_->setChecked(policy.value(QStringLiteral("delete_rejected")).toBool(true)); layout->addWidget(deleteRejected_);
    auto *media = new QFormLayout;
    extensions_ = new QLineEdit(join(policy.value(QStringLiteral("allowed_extensions"))), body);
    containers_ = new QLineEdit(join(policy.value(QStringLiteral("allowed_containers"))), body);
    codecs_ = new QLineEdit(join(policy.value(QStringLiteral("allowed_codecs"))), body);
    width_ = new QLineEdit(optionalNumber(policy.value(QStringLiteral("required_width"))), body);
    height_ = new QLineEdit(optionalNumber(policy.value(QStringLiteral("required_height"))), body);
    rate_ = new QLineEdit(optionalText(policy.value(QStringLiteral("frame_rate"))), body);
    aspect_ = new QLineEdit(optionalText(policy.value(QStringLiteral("display_aspect_ratio"))), body);
    standard_ = new QComboBox(body); standard_->addItems({QStringLiteral("any"), QStringLiteral("ntsc"), QStringLiteral("pal")});
    scan_ = new QComboBox(body); scan_->addItems({QStringLiteral("any"), QStringLiteral("interlaced"), QStringLiteral("progressive")});
    orientation_ = new QComboBox(body); orientation_->addItems({QStringLiteral("any"), QStringLiteral("horizontal"), QStringLiteral("vertical")});
    standard_->setCurrentText(policy.value(QStringLiteral("television_standard")).toString(QStringLiteral("ntsc")));
    scan_->setCurrentText(policy.value(QStringLiteral("scan_type")).toString(QStringLiteral("interlaced")));
    orientation_->setCurrentText(policy.value(QStringLiteral("orientation")).toString(QStringLiteral("horizontal")));
    standard_->setAccessibleName(tr("TV standard"));
    standard_->setAccessibleDescription(tr("TV standard for accepted media"));
    standard_->setToolTip(tr("TV standard for accepted media"));
    scan_->setAccessibleName(tr("Scan type"));
    scan_->setAccessibleDescription(tr("Required scan type for accepted media"));
    scan_->setToolTip(tr("Required scan type for accepted media"));
    orientation_->setAccessibleName(tr("Orientation"));
    orientation_->setAccessibleDescription(tr("Required video orientation"));
    orientation_->setToolTip(tr("Required video orientation"));
    standard_->setObjectName(QStringLiteral("standard"));
    scan_->setObjectName(QStringLiteral("scan"));
    orientation_->setObjectName(QStringLiteral("orientation"));
    media->addRow(tr("Allowed extensions (comma separated; blank = any)"), extensions_);
    media->addRow(tr("Allowed containers"), containers_);
    media->addRow(tr("Allowed video codecs"), codecs_);
    media->addRow(tr("Required width (blank = any)"), width_);
    media->addRow(tr("Required height (blank = any)"), height_);
    media->addRow(tr("Frame rate (blank = any)"), rate_);
    media->addRow(tr("Display aspect ratio (blank = any)"), aspect_);
    media->addRow(tr("TV standard"), standard_);
    media->addRow(tr("Scan type"), scan_);
    media->addRow(tr("Orientation"), orientation_);
    layout->addLayout(media);
    auto *appearanceHeading = new QLabel(tr("Appearance"), body); appearanceHeading->setFont(headingFont); layout->addWidget(appearanceHeading);
    auto *appearanceLayout = new QFormLayout;
    appearance_ = new QComboBox(body); appearance_->addItems({tr("System"), tr("Light"), tr("Dark")});
    appearance_->setAccessibleName(tr("Appearance theme"));
    appearance_->setAccessibleDescription(tr("Choose System, Light or Dark appearance"));
    appearance_->setToolTip(tr("Choose System, Light or Dark appearance"));
    appearance_->setObjectName(QStringLiteral("appearance"));
    appearance_->setCurrentIndex(appearance == QLatin1String("light") ? 1 : appearance == QLatin1String("dark") ? 2 : 0);
    appearanceLayout->addRow(tr("Theme"), appearance_); layout->addLayout(appearanceLayout);
    layout->addStretch();
    body->setLayout(layout); scroll->setWidget(body); root->addWidget(scroll);
    error_ = new QLabel(this); error_->setWordWrap(true); error_->setAccessibleName(tr("Settings error")); root->addWidget(error_);
    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Save | QDialogButtonBox::Cancel, this);
    connect(buttons, &QDialogButtonBox::accepted, this, &SettingsDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, this, &SettingsDialog::reject);
    root->addWidget(buttons);
}

QJsonObject SettingsDialog::policy() const {
    return {{QStringLiteral("enabled"), filter_->isChecked()}, {QStringLiteral("delete_rejected"), deleteRejected_->isChecked()},
        {QStringLiteral("allowed_extensions"), split(extensions_->text())}, {QStringLiteral("allowed_containers"), split(containers_->text())},
        {QStringLiteral("allowed_codecs"), split(codecs_->text())}, {QStringLiteral("required_width"), positiveNumber(width_->text())},
        {QStringLiteral("required_height"), positiveNumber(height_->text())}, {QStringLiteral("frame_rate"), nullableText(rate_->text())},
        {QStringLiteral("display_aspect_ratio"), nullableText(aspect_->text())}, {QStringLiteral("television_standard"), standard_->currentText()},
        {QStringLiteral("scan_type"), scan_->currentText()}, {QStringLiteral("orientation"), orientation_->currentText()}};
}

QJsonObject SettingsDialog::sort() const {
    const qulonglong hours = hours_->text().toULongLong();
    const qulonglong totalSeconds = hours * 3600 + static_cast<qulonglong>(minutes_->value()) * 60 + seconds_->value();
    return {{QStringLiteral("folder_count"), folderCount_->value()}, {QStringLiteral("folder_prefix"), folderPrefix_->text().trimmed()},
        {QStringLiteral("total_ms"), static_cast<qint64>(totalSeconds * 1000)}};
}

QString SettingsDialog::appearance() const {
    return appearance_->currentIndex() == 1 ? QStringLiteral("light") : appearance_->currentIndex() == 2 ? QStringLiteral("dark") : QStringLiteral("system");
}

void SettingsDialog::accept() {
    const QString prefix = folderPrefix_->text().trimmed();
    if (prefix.isEmpty() || prefix.toUtf8().size() > 80 || prefix == QLatin1String(".") || prefix == QLatin1String("..") || prefix.endsWith(QLatin1Char('.')) ||
        prefix.contains(QRegularExpression(QStringLiteral("[\\x00-\\x1f/\\\\:<>\"|?*]")))) {
        error_->setText(tr("Folder prefix must be a safe name of 1 to 80 characters.")); folderPrefix_->setFocus(); return;
    }
    bool hoursOk = false;
    const qulonglong hours = hours_->text().toULongLong(&hoursOk);
    if (!hoursOk || hours > (static_cast<qulonglong>(std::numeric_limits<qint64>::max()) / 1000 - 3599) / 3600 ||
        (hours == 0 && minutes_->value() == 0 && seconds_->value() == 0)) {
        error_->setText(tr("Enter a positive total time in hours, minutes and seconds.")); hours_->setFocus(); return;
    }
    for (QLineEdit *field : {width_, height_}) {
        bool ok = false; const int number = field->text().toInt(&ok);
        if (!field->text().trimmed().isEmpty() && (!ok || number <= 0)) {
            error_->setText(tr("Width and height must be positive whole numbers or blank.")); field->setFocus(); return;
        }
    }
    const QRegularExpression ratio(QStringLiteral("^(?:0*[1-9][0-9]*|[0-9]*\\.[0-9]*[1-9][0-9]*)(?:[/:](?:0*[1-9][0-9]*|[0-9]*\\.[0-9]*[1-9][0-9]*))?$"));
    for (QLineEdit *field : {rate_, aspect_}) {
        if (!field->text().trimmed().isEmpty() && !ratio.match(field->text().trimmed()).hasMatch()) {
            error_->setText(tr("Frame rate and aspect ratio must be positive numbers or ratios, such as 30000/1001 and 16:9.")); field->setFocus(); return;
        }
    }
    QDialog::accept();
}
