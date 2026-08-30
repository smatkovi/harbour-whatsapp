/* harbour-whatsapp voicecall plugin - MIT License */
#include "whatsappbackendbridge.h"

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QUrl>
#include <QDebug>

static const char *kPluginHeader = "X-WhatsApp-Voicecall-Plugin";

WhatsAppBackendBridge::WhatsAppBackendBridge(QObject *parent)
    : QObject(parent), m_port(0), m_seq(0), m_hasCall(false)
{
    m_retry.setSingleShot(true);
    connect(&m_retry, SIGNAL(timeout()), this, SLOT(probe()));
    // While a call exists, refresh once a second (duration, speaker, mute)
    m_tick.setSingleShot(true);
    m_tick.setInterval(1000);
    connect(&m_tick, SIGNAL(timeout()), this, SLOT(fetchState()));
}

void WhatsAppBackendBridge::start()
{
    probe();
}

QNetworkRequest WhatsAppBackendBridge::makeRequest(const QString &path, int port) const
{
    if (port == 0) {
        port = m_port;
    }
    QNetworkRequest req(QUrl(QStringLiteral("http://127.0.0.1:%1%2").arg(port).arg(path)));
    // The backend uses this header to know a system call UI is present:
    // it then leaves ringing and audio routing to voicecall-manager
    req.setRawHeader(kPluginHeader, "1");
    return req;
}

QList<int> WhatsAppBackendBridge::candidatePorts() const
{
    QList<int> ports;
    QFile f(QDir::homePath() + QStringLiteral("/.local/share/harbour/harbour-whatsapp/backend.port"));
    if (f.open(QIODevice::ReadOnly)) {
        int p = QString::fromLatin1(f.readAll()).trimmed().toInt();
        if (p > 0) {
            ports << p;
        }
    }
    for (int p = 8085; p <= 8089; ++p) {
        if (!ports.contains(p)) {
            ports << p;
        }
    }
    return ports;
}

void WhatsAppBackendBridge::probe()
{
    m_candidates = candidatePorts();
    tryNextCandidate();
}

void WhatsAppBackendBridge::tryNextCandidate()
{
    if (m_candidates.isEmpty()) {
        // No backend right now (app closed, no daemon): look again later
        m_retry.start(5000);
        return;
    }
    const int port = m_candidates.takeFirst();
    QNetworkReply *reply = m_nam.get(makeRequest(QStringLiteral("/status"), port));
    QTimer *guard = new QTimer(reply);
    guard->setSingleShot(true);
    connect(guard, SIGNAL(timeout()), reply, SLOT(abort()));
    guard->start(1500);
    connect(reply, &QNetworkReply::finished, this, [this, reply, port]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            tryNextCandidate();
            return;
        }
        qWarning() << "[WA-VOICECALL] backend found on port" << port;
        m_port = port;
        m_seq = 0;
        fetchState();
        longPoll();
    });
}

void WhatsAppBackendBridge::longPoll()
{
    if (m_port == 0) {
        return;
    }
    const int port = m_port;
    QNetworkReply *reply = m_nam.get(makeRequest(QStringLiteral("/events?since=%1").arg(m_seq)));
    connect(reply, &QNetworkReply::finished, this, [this, reply, port]() {
        reply->deleteLater();
        if (port != m_port) {
            return; // superseded by a re-probe
        }
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "[WA-VOICECALL] backend lost:" << reply->errorString();
            m_port = 0;
            m_tick.stop();
            emit backendLost();
            m_retry.start(3000);
            return;
        }
        const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
        const qint64 seq = static_cast<qint64>(o.value(QStringLiteral("seq")).toDouble());
        if (seq != m_seq) {
            m_seq = seq;
            fetchState();
        }
        // Re-arm immediately; the backend holds the request up to 25 s
        QTimer::singleShot(0, this, SLOT(longPoll()));
    });
}

void WhatsAppBackendBridge::fetchState()
{
    if (m_port == 0) {
        return;
    }
    QNetworkReply *reply = m_nam.get(makeRequest(QStringLiteral("/call/state")));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            return;
        }
        const QJsonObject st = QJsonDocument::fromJson(reply->readAll()).object();
        m_hasCall = st.value(QStringLiteral("active")).toBool();
        emit callStateChanged(st);
        if (m_hasCall) {
            m_tick.start();
        } else {
            m_tick.stop();
        }
    });
}

void WhatsAppBackendBridge::request(const QString &path)
{
    if (m_port == 0) {
        qWarning() << "[WA-VOICECALL] request without backend:" << path;
        return;
    }
    QNetworkReply *reply = m_nam.get(makeRequest(path));
    connect(reply, &QNetworkReply::finished, this, [this, reply, path]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "[WA-VOICECALL]" << path << "failed:" << reply->errorString();
        }
        fetchState();
    });
}
