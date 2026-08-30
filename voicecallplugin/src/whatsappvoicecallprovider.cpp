/* harbour-whatsapp voicecall plugin - MIT License */
#include "whatsappvoicecallprovider.h"
#include "whatsappvoicecallhandler.h"
#include "whatsappbackendbridge.h"

#include <QTimer>
#include <QDebug>

WhatsAppVoiceCallProvider::WhatsAppVoiceCallProvider(VoiceCallManagerInterface *manager,
                                                     WhatsAppBackendBridge *bridge, QObject *parent)
    : AbstractVoiceCallProvider(parent)
    , m_manager(manager)
    , m_bridge(bridge)
    , m_handler(0)
    , m_speaker(false)
    , m_muted(false)
{
    connect(m_bridge, SIGNAL(callStateChanged(QJsonObject)), this, SLOT(onCallState(QJsonObject)));
    connect(m_bridge, SIGNAL(backendLost()), this, SLOT(onBackendLost()));
    // Speaker and mute buttons of the system UI end up as manager state;
    // mirror them to the backend so the app's own call page agrees
    connect(m_manager, SIGNAL(audioModeChanged()), this, SLOT(onAudioModeChanged()));
    connect(m_manager, SIGNAL(microphoneMutedChanged()), this, SLOT(onMicrophoneMutedChanged()));
}

QString WhatsAppVoiceCallProvider::providerId() const { return QStringLiteral("harbour-whatsapp"); }
QString WhatsAppVoiceCallProvider::providerType() const { return QStringLiteral("voip"); }
QString WhatsAppVoiceCallProvider::errorString() const { return QString(); }

QList<AbstractVoiceCallHandler *> WhatsAppVoiceCallProvider::voiceCalls() const
{
    QList<AbstractVoiceCallHandler *> list;
    if (m_handler) {
        list << m_handler;
    }
    return list;
}

bool WhatsAppVoiceCallProvider::dial(const QString &msisdn)
{
    QString digits;
    foreach (QChar c, msisdn) {
        if (c.isDigit()) {
            digits += c;
        }
    }
    if (digits.isEmpty()) {
        return false;
    }
    m_bridge->request(QStringLiteral("/call/start?jid=") + digits);
    return true;
}

static AbstractVoiceCallHandler::VoiceCallStatus statusFor(const QString &phase, bool outgoing)
{
    if (phase == QLatin1String("ringing")) {
        return outgoing ? AbstractVoiceCallHandler::STATUS_ALERTING : AbstractVoiceCallHandler::STATUS_INCOMING;
    }
    if (phase == QLatin1String("calling")) {
        return AbstractVoiceCallHandler::STATUS_DIALING;
    }
    if (phase == QLatin1String("connecting")) {
        return outgoing ? AbstractVoiceCallHandler::STATUS_ALERTING : AbstractVoiceCallHandler::STATUS_ACTIVE;
    }
    if (phase == QLatin1String("active")) {
        return AbstractVoiceCallHandler::STATUS_ACTIVE;
    }
    if (phase == QLatin1String("waiting")) {
        return AbstractVoiceCallHandler::STATUS_WAITING;
    }
    return AbstractVoiceCallHandler::STATUS_DISCONNECTED;
}

void WhatsAppVoiceCallProvider::onCallState(const QJsonObject &st)
{
    const bool active = st.value(QStringLiteral("active")).toBool();
    const QString id = st.value(QStringLiteral("id")).toString();
    const bool outgoing = st.value(QStringLiteral("outgoing")).toBool();
    QString line = st.value(QStringLiteral("name")).toString();
    if (line.isEmpty()) {
        line = QStringLiteral("+") + st.value(QStringLiteral("peer")).toString();
    }

    if (!active || id.isEmpty()) {
        if (m_handler) {
            m_handler->setStatus(AbstractVoiceCallHandler::STATUS_DISCONNECTED);
            QTimer::singleShot(1500, this, SLOT(removeHandler()));
        }
        return;
    }

    if (m_handler && m_handler->callId() != id) {
        // A new call replaced the old one without an "ended" in between
        m_handler->setStatus(AbstractVoiceCallHandler::STATUS_DISCONNECTED);
        removeHandler();
    }
    if (!m_handler) {
        m_handler = new WhatsAppVoiceCallHandler(m_manager->generateHandlerId(), id, line, !outgoing, this, m_bridge);
        qWarning() << "[WA-VOICECALL] call" << id << (outgoing ? "outgoing to" : "incoming from") << line;
        m_speaker = st.value(QStringLiteral("speaker")).toBool();
        m_muted = st.value(QStringLiteral("muted")).toBool();
        emit voiceCallAdded(m_handler);
        emit voiceCallsChanged();
        // Tell the backend the call reached the call engine, so it does not
        // fall back to its own ringing notification
        m_bridge->request(QStringLiteral("/call/uiack?id=") + id);
    }
    m_handler->setLineId(line);
    m_handler->setStatus(statusFor(st.value(QStringLiteral("phase")).toString(), outgoing));

    // App-side toggles -> manager (the system UI then shows the same state)
    const bool speaker = st.value(QStringLiteral("speaker")).toBool();
    if (speaker != m_speaker) {
        m_speaker = speaker;
        m_manager->setAudioMode(speaker ? QStringLiteral("ihf") : QStringLiteral("earpiece"));
    }
    const bool muted = st.value(QStringLiteral("muted")).toBool();
    if (muted != m_muted) {
        m_muted = muted;
        m_manager->setMuteMicrophone(muted);
    }
}

void WhatsAppVoiceCallProvider::onAudioModeChanged()
{
    if (!m_handler) {
        return;
    }
    const bool speaker = m_manager->audioMode() == QLatin1String("ihf");
    if (speaker != m_speaker) {
        m_speaker = speaker;
        m_bridge->request(QStringLiteral("/call/speaker?on=") + (speaker ? QStringLiteral("1") : QStringLiteral("0")));
    }
}

void WhatsAppVoiceCallProvider::onMicrophoneMutedChanged()
{
    if (!m_handler) {
        return;
    }
    const bool muted = m_manager->isMicrophoneMuted();
    if (muted != m_muted) {
        m_muted = muted;
        m_bridge->request(QStringLiteral("/call/mute?on=") + (muted ? QStringLiteral("1") : QStringLiteral("0")));
    }
}

void WhatsAppVoiceCallProvider::onBackendLost()
{
    if (m_handler) {
        m_handler->setStatus(AbstractVoiceCallHandler::STATUS_DISCONNECTED);
        removeHandler();
    }
}

void WhatsAppVoiceCallProvider::removeHandler()
{
    if (!m_handler) {
        return;
    }
    WhatsAppVoiceCallHandler *h = m_handler;
    m_handler = 0;
    emit voiceCallRemoved(h->handlerId());
    emit voiceCallsChanged();
    h->deleteLater();
}
