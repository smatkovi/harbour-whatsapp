# voicecall-manager plugin for harbour-whatsapp: registers WhatsApp voice
# calls with the Sailfish call engine so the SYSTEM call UI shows them -
# over the lock screen, with answer/decline/mute/speaker - and relays those
# buttons to the backend over its local HTTP API. Build with the Sailfish
# SDK (mb2) against a 5.x target; the plugin links the device's
# libvoicecall.so.1 and ships the public headers itself, so no -devel
# package is needed.
TEMPLATE = lib
TARGET = harbour-whatsapp-voicecall-plugin
QT = core network
CONFIG += plugin c++11 link_pkgconfig
CONFIG -= debug_and_release

INCLUDEPATH += $$PWD/include/voicecall
exists(/usr/include/voicecall/abstractvoicecallhandler.h) {
    INCLUDEPATH += /usr/include/voicecall
}
exists($$[QT_INSTALL_LIBS]/libvoicecall.so) {
    LIBS += -lvoicecall
} else {
    LIBS += -l:libvoicecall.so.1
}
DEFINES += PLUGIN_NAME=\\\"harbour-whatsapp-voicecall-plugin\\\"

HEADERS += \
    src/whatsappbackendbridge.h \
    src/whatsappvoicecallhandler.h \
    src/whatsappvoicecallprovider.h \
    src/whatsappvoicecallplugin.h
SOURCES += \
    src/whatsappbackendbridge.cpp \
    src/whatsappvoicecallhandler.cpp \
    src/whatsappvoicecallprovider.cpp \
    src/whatsappvoicecallplugin.cpp

target.path = $$[QT_INSTALL_LIBS]/voicecall/plugins
INSTALLS += target
