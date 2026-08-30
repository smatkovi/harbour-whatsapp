/* harbour-whatsapp voicecall plugin - MIT License */
#include "whatsappvoicecallplugin.h"
#include "whatsappbackendbridge.h"
#include "whatsappvoicecallprovider.h"

#include <QDebug>

WhatsAppVoiceCallPlugin::WhatsAppVoiceCallPlugin(QObject *parent)
    : AbstractVoiceCallManagerPlugin(parent), m_manager(0), m_bridge(0), m_provider(0)
{
}

QString WhatsAppVoiceCallPlugin::pluginId() const
{
    return QStringLiteral(PLUGIN_NAME);
}

bool WhatsAppVoiceCallPlugin::initialize()
{
    return true;
}

bool WhatsAppVoiceCallPlugin::configure(VoiceCallManagerInterface *manager)
{
    if (m_manager) {
        return false;
    }
    m_manager = manager;
    m_bridge = new WhatsAppBackendBridge(this);
    m_provider = new WhatsAppVoiceCallProvider(m_manager, m_bridge, this);
    m_manager->appendProvider(m_provider);
    qWarning() << "[WA-VOICECALL] provider registered";
    return true;
}

bool WhatsAppVoiceCallPlugin::start()
{
    if (m_bridge) {
        m_bridge->start();
    }
    return true;
}

bool WhatsAppVoiceCallPlugin::suspend() { return true; }
bool WhatsAppVoiceCallPlugin::resume() { return true; }

void WhatsAppVoiceCallPlugin::finalize()
{
    if (m_manager && m_provider) {
        m_manager->removeProvider(m_provider);
    }
}
