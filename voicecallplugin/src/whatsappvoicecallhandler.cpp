/* harbour-whatsapp voicecall plugin - MIT License */
#include "whatsappvoicecallhandler.h"
#include "whatsappvoicecallprovider.h"
#include "whatsappbackendbridge.h"

#include <QDebug>

WhatsAppVoiceCallHandler::WhatsAppVoiceCallHandler(const QString &handlerId, const QString &callId,
                                                   const QString &lineId, bool incoming,
                                                   WhatsAppVoiceCallProvider *provider,
                                                   WhatsAppBackendBridge *bridge)
    : AbstractVoiceCallHandler(provider)
    , m_handlerId(handlerId)
    , m_callId(callId)
    , m_lineId(lineId)
    , m_incoming(incoming)
    , m_provider(provider)
    , m_bridge(bridge)
    , m_status(incoming ? STATUS_INCOMING : STATUS_DIALING)
    , m_duration(0)
{
    m_durationTimer.setInterval(1000);
    connect(&m_durationTimer, SIGNAL(timeout()), this, SLOT(onDurationTick()));
}

AbstractVoiceCallProvider *WhatsAppVoiceCallHandler::provider() const { return m_provider; }
QString WhatsAppVoiceCallHandler::handlerId() const { return m_handlerId; }
QString WhatsAppVoiceCallHandler::lineId() const { return m_lineId; }
QString WhatsAppVoiceCallHandler::subscriberId() const { return QString(); }
QDateTime WhatsAppVoiceCallHandler::startedAt() const { return m_startedAt; }
int WhatsAppVoiceCallHandler::duration() const { return m_duration; }
bool WhatsAppVoiceCallHandler::isIncoming() const { return m_incoming; }
bool WhatsAppVoiceCallHandler::isMultiparty() const { return false; }
bool WhatsAppVoiceCallHandler::isEmergency() const { return false; }
bool WhatsAppVoiceCallHandler::isForwarded() const { return false; }
bool WhatsAppVoiceCallHandler::isRemoteHeld() const { return false; }
QString WhatsAppVoiceCallHandler::parentHandlerId() const { return QString(); }
QList<AbstractVoiceCallHandler *> WhatsAppVoiceCallHandler::childCalls() const { return QList<AbstractVoiceCallHandler *>(); }
AbstractVoiceCallHandler::VoiceCallStatus WhatsAppVoiceCallHandler::status() const { return m_status; }

void WhatsAppVoiceCallHandler::setLineId(const QString &lineId)
{
    if (lineId.isEmpty() || lineId == m_lineId) {
        return;
    }
    m_lineId = lineId;
    emit lineIdChanged(m_lineId);
}

void WhatsAppVoiceCallHandler::setStatus(VoiceCallStatus status)
{
    if (status == m_status) {
        return;
    }
    m_status = status;
    if (status == STATUS_ACTIVE && !m_startedAt.isValid()) {
        m_startedAt = QDateTime::currentDateTime();
        emit startedAtChanged(m_startedAt);
        m_durationTimer.start();
    }
    if (status == STATUS_DISCONNECTED || status == STATUS_REJECTED || status == STATUS_IGNORED) {
        m_durationTimer.stop();
    }
    emit statusChanged(m_status);
}

void WhatsAppVoiceCallHandler::onDurationTick()
{
    ++m_duration;
    emit durationChanged(m_duration);
}

void WhatsAppVoiceCallHandler::answer()
{
    qWarning() << "[WA-VOICECALL] answer from system UI";
    m_bridge->request(QStringLiteral("/call/accept"));
}

void WhatsAppVoiceCallHandler::hangup()
{
    qWarning() << "[WA-VOICECALL] hangup from system UI, status" << m_status;
    if (m_status == STATUS_INCOMING || m_status == STATUS_WAITING) {
        m_bridge->request(QStringLiteral("/call/reject"));
    } else {
        m_bridge->request(QStringLiteral("/call/hangup"));
    }
}

void WhatsAppVoiceCallHandler::hold(bool on) { Q_UNUSED(on); }
void WhatsAppVoiceCallHandler::deflect(const QString &target) { Q_UNUSED(target); }
void WhatsAppVoiceCallHandler::sendDtmf(const QString &tones) { Q_UNUSED(tones); }
void WhatsAppVoiceCallHandler::merge(const QString &callHandle) { Q_UNUSED(callHandle); }
void WhatsAppVoiceCallHandler::split() {}

void WhatsAppVoiceCallHandler::filter(VoiceCallFilterAction action)
{
    if (action == ACTION_REJECT) {
        m_bridge->request(QStringLiteral("/call/reject"));
    }
}
