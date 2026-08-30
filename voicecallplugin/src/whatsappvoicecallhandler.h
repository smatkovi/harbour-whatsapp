/* harbour-whatsapp voicecall plugin - MIT License */
#ifndef WHATSAPPVOICECALLHANDLER_H
#define WHATSAPPVOICECALLHANDLER_H

#include <abstractvoicecallhandler.h>
#include <QTimer>

class WhatsAppVoiceCallProvider;
class WhatsAppBackendBridge;

// One WhatsApp call as the call engine sees it. lineId is what the system
// call UI prints as the caller, so it carries the WhatsApp display name
// (the number when there is none) - RooTelegram does the same.
class WhatsAppVoiceCallHandler : public AbstractVoiceCallHandler
{
    Q_OBJECT
public:
    WhatsAppVoiceCallHandler(const QString &handlerId, const QString &callId,
                             const QString &lineId, bool incoming,
                             WhatsAppVoiceCallProvider *provider,
                             WhatsAppBackendBridge *bridge);

    AbstractVoiceCallProvider *provider() const;
    QString handlerId() const;
    QString lineId() const;
    QString subscriberId() const;
    QDateTime startedAt() const;
    int duration() const;
    bool isIncoming() const;
    bool isMultiparty() const;
    bool isEmergency() const;
    bool isForwarded() const;
    bool isRemoteHeld() const;
    QString parentHandlerId() const;
    QList<AbstractVoiceCallHandler *> childCalls() const;
    VoiceCallStatus status() const;

    QString callId() const { return m_callId; }
    void setStatus(VoiceCallStatus status);
    void setLineId(const QString &lineId);

public Q_SLOTS:
    void answer();
    void hangup();
    void hold(bool on);
    void deflect(const QString &target);
    void sendDtmf(const QString &tones);
    void merge(const QString &callHandle);
    void split();
    void filter(VoiceCallFilterAction action);

private Q_SLOTS:
    void onDurationTick();

private:
    QString m_handlerId;
    QString m_callId;
    QString m_lineId;
    bool m_incoming;
    WhatsAppVoiceCallProvider *m_provider;
    WhatsAppBackendBridge *m_bridge;
    VoiceCallStatus m_status;
    QDateTime m_startedAt;
    int m_duration;
    QTimer m_durationTimer;
};

#endif // WHATSAPPVOICECALLHANDLER_H
