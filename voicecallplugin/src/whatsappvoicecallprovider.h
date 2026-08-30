/* harbour-whatsapp voicecall plugin - MIT License */
#ifndef WHATSAPPVOICECALLPROVIDER_H
#define WHATSAPPVOICECALLPROVIDER_H

#include <abstractvoicecallprovider.h>
#include <voicecallmanagerinterface.h>
#include <QJsonObject>

class WhatsAppVoiceCallHandler;
class WhatsAppBackendBridge;

class WhatsAppVoiceCallProvider : public AbstractVoiceCallProvider
{
    Q_OBJECT
public:
    WhatsAppVoiceCallProvider(VoiceCallManagerInterface *manager, WhatsAppBackendBridge *bridge, QObject *parent = 0);

    QString providerId() const;
    QString providerType() const;
    QList<AbstractVoiceCallHandler *> voiceCalls() const;
    QString errorString() const;

public Q_SLOTS:
    bool dial(const QString &msisdn);

private Q_SLOTS:
    void onCallState(const QJsonObject &state);
    void onBackendLost();
    void onAudioModeChanged();
    void onMicrophoneMutedChanged();
    void removeHandler();

private:
    VoiceCallManagerInterface *m_manager;
    WhatsAppBackendBridge *m_bridge;
    WhatsAppVoiceCallHandler *m_handler;
    bool m_speaker;
    bool m_muted;
};

#endif // WHATSAPPVOICECALLPROVIDER_H
