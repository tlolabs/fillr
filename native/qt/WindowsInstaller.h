#pragma once
#include <QJsonObject>
#include <QString>

bool stageWindowsUpdate(const QJsonObject &download, QString *error);
