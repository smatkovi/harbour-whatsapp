/*
 * harbour-whatsapp voicecall plugin - MIT License
 *
 * Bridge to the harbour-whatsapp backend. The backend runs inside a sailjail
 * (as the app's child or as the systemd daemon) and cannot talk to arbitrary
 * D-Bus names, so the plugin - which runs unsandboxed inside voicecall-manager
 * - is the one that reaches out: it long-polls the backend's /events channel
 * on loopback, fetches /call/state on every change and drives the call with
 * the same /call/* endpoints the app's own call page uses.
 */
#ifndef WHATSAPPBACKENDBRIDGE_H
#define WHATSAPPBACKENDBRIDGE_H

#include <QObject>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QTimer>
#include <QList>

class QNetworkReply;

class WhatsAppBackendBridge : public QObject
{
    Q_OBJECT
public:
    explicit WhatsAppBackendBridge(QObject *parent = 0);

    void start();
    // Fire-and-forget GET against the backend, e.g. "/call/accept".
    void request(const QString &path);
    bool connected() const { return m_port > 0; }

Q_SIGNALS:
    void callStateChanged(const QJsonObject &state);
    void backendLost();

private Q_SLOTS:
    void probe();
    void tryNextCandidate();
    void longPoll();
    void fetchState();

private:
    QNetworkRequest makeRequest(const QString &path, int port = 0) const;
    QList<int> candidatePorts() const;

    int m_port;
    QList<int> m_candidates;
    qint64 m_seq;
    bool m_hasCall;
    QNetworkAccessManager m_nam;
    QTimer m_retry;
    QTimer m_tick;
};

#endif // WHATSAPPBACKENDBRIDGE_H
