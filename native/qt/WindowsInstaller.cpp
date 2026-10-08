#include "WindowsInstaller.h"

#ifdef Q_OS_WIN
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QUrl>
#include <QStringList>

#include <appxpackaging.h>
#include <shlwapi.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Management.Deployment.h>

namespace {
QString takeComString(LPWSTR value) {
    const QString result = QString::fromWCharArray(value);
    CoTaskMemFree(value);
    return result;
}

void verifyPackageIdentity(IStream *stream, const QJsonObject &download) {
    winrt::com_ptr<IAppxFactory> factory;
    winrt::check_hresult(CoCreateInstance(CLSID_AppxFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(factory.put())));
    winrt::com_ptr<IAppxPackageReader> package;
    winrt::check_hresult(factory->CreatePackageReader(stream, package.put()));
    winrt::com_ptr<IAppxManifestReader> manifest;
    winrt::check_hresult(package->GetManifest(manifest.put()));
    winrt::com_ptr<IAppxManifestPackageId> identity;
    winrt::check_hresult(manifest->GetPackageId(identity.put()));
    LPWSTR name = nullptr;
    LPWSTR publisher = nullptr;
    UINT64 version = 0;
    APPX_PACKAGE_ARCHITECTURE architecture;
    winrt::check_hresult(identity->GetName(&name));
    const QString packageName = takeComString(name);
    winrt::check_hresult(identity->GetPublisher(&publisher));
    const QString packagePublisher = takeComString(publisher);
    winrt::check_hresult(identity->GetVersion(&version));
    winrt::check_hresult(identity->GetArchitecture(&architecture));
    const QStringList parts = download.value(QStringLiteral("version")).toString().split(QLatin1Char('.'));
    if (parts.size() != 3) throw winrt::hresult_error(E_INVALIDARG);
    UINT64 expectedVersion = 0;
    for (const QString &part : parts) {
        bool ok = false;
        const uint number = part.toUInt(&ok);
        if (!ok || number > 65535) throw winrt::hresult_error(E_INVALIDARG);
        expectedVersion = (expectedVersion << 16) | number;
    }
    expectedVersion <<= 16;
#ifdef _M_ARM64
    constexpr auto expectedArchitecture = APPX_PACKAGE_ARCHITECTURE_ARM64;
#else
    constexpr auto expectedArchitecture = APPX_PACKAGE_ARCHITECTURE_X64;
#endif
    if (packageName != QLatin1String("TLOLabs.FILLR") ||
        packagePublisher != download.value(QStringLiteral("identity")).toString() ||
        version != expectedVersion || architecture != expectedArchitecture)
        throw winrt::hresult_error(E_INVALIDARG);
}
}

bool stageWindowsUpdate(const QJsonObject &download, QString *error) {
    const QString path = download.value(QStringLiteral("path")).toString();
    const QString expectedHash = download.value(QStringLiteral("sha256")).toString();
    const QString publisher = download.value(QStringLiteral("identity")).toString();
    if (!QDir::isAbsolutePath(path) || !path.endsWith(QLatin1String(".msix"), Qt::CaseInsensitive) ||
        publisher.isEmpty() || publisher == QLatin1String("UNCONFIGURED") || expectedHash.size() != 64) {
        if (error) *error = QStringLiteral("The downloaded update package has an invalid identity or path.");
        return false;
    }
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) { if (error) *error = file.errorString(); return false; }
    QCryptographicHash hash(QCryptographicHash::Sha256);
    if (!hash.addData(&file) || QString::fromLatin1(hash.result().toHex()) != expectedHash) {
        if (error) *error = QStringLiteral("The update changed after download.");
        return false;
    }
    file.close();
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        winrt::com_ptr<IStream> packageStream;
        winrt::check_hresult(SHCreateStreamOnFileEx(path.toStdWString().c_str(), STGM_READ | STGM_SHARE_DENY_WRITE,
            FILE_ATTRIBUTE_NORMAL, FALSE, nullptr, packageStream.put()));
        verifyPackageIdentity(packageStream.get(), download);
        QFile lockedFile(path);
        QCryptographicHash lockedHash(QCryptographicHash::Sha256);
        if (!lockedFile.open(QIODevice::ReadOnly) || !lockedHash.addData(&lockedFile) ||
            QString::fromLatin1(lockedHash.result().toHex()) != expectedHash)
            throw winrt::hresult_error(E_FAIL);
        lockedFile.close();
        const auto uri = winrt::Windows::Foundation::Uri(QUrl::fromLocalFile(path).toString().toStdWString());
        winrt::Windows::Management::Deployment::PackageManager manager;
        const auto staged = manager.StagePackageAsync(uri, nullptr, winrt::Windows::Management::Deployment::DeploymentOptions::None).get();
        if (staged.ExtendedErrorCode().value < 0) throw winrt::hresult_error(staged.ExtendedErrorCode());
        winrt::Windows::Management::Deployment::AddPackageOptions options;
        options.DeferRegistrationWhenPackagesAreInUse(true);
        const auto added = manager.AddPackageByUriAsync(uri, options).get();
        if (added.ExtendedErrorCode().value < 0) throw winrt::hresult_error(added.ExtendedErrorCode());
    } catch (const winrt::hresult_error &failure) {
        if (error) *error = QStringLiteral("The update package identity or Windows signature check failed: %1").arg(QString::fromStdWString(failure.message().c_str()));
        return false;
    }
    const QFileInfo info(path);
    const QString cache = qEnvironmentVariable("LOCALAPPDATA") + QStringLiteral("/fillr/updates");
    if (info.dir().dirName().startsWith(QLatin1String("download-")) &&
        QDir::cleanPath(info.dir().absolutePath() + QStringLiteral("/..")) == QDir::cleanPath(cache)) {
        QFile::remove(path);
        QDir().rmdir(info.dir().absolutePath());
    }
    return true;
}
#else
bool stageWindowsUpdate(const QJsonObject &, QString *error) {
    if (error) *error = QStringLiteral("Windows package installation is unavailable on this platform.");
    return false;
}
#endif
