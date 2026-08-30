/* harbour-whatsapp voicecall plugin - MIT License */
#ifndef WHATSAPPVOICECALLPLUGIN_H
#define WHATSAPPVOICECALLPLUGIN_H

#include <abstractvoicecallmanagerplugin.h>
#include <voicecallmanagerinterface.h>

class WhatsAppBackendBridge;
class WhatsAppVoiceCallProvider;

class WhatsAppVoiceCallPlugin : public AbstractVoiceCallManagerPlugin
{
    Q_OBJECT
    Q_INTERFACES(AbstractVoiceCallManagerPlugin)
    Q_PLUGIN_METADATA(IID "harbour.whatsapp.voicecall.plugin")
public:
    explicit WhatsAppVoiceCallPlugin(QObject *parent = 0);

    QString pluginId() const;

public Q_SLOTS:
    bool initialize();
    bool configure(VoiceCallManagerInterface *manager);
    bool start();
    bool suspend();
    bool resume();
    void finalize();

private:
    VoiceCallManagerInterface *m_manager;
    WhatsAppBackendBridge *m_bridge;
    WhatsAppVoiceCallProvider *m_provider;
};

#endif // WHATSAPPVOICECALLPLUGIN_H
