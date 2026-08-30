# harbour-whatsapp voicecall plugin

Registers WhatsApp voice calls with `voicecall-manager`, so the Sailfish
system call UI shows them - over the lock screen, with answer, decline, mute
and speaker - and relays those controls to the app's backend over its
loopback HTTP API (`/events`, `/call/state`, `/call/*`). The backend detects
the plugin by the `X-WhatsApp-Voicecall-Plugin` request header and then
leaves ringing and audio routing to the call engine.

Build with the Sailfish SDK (coderus platform SDK container works):

    cd voicecallplugin
    mb2 -t SailfishOS-5.2.0.17-aarch64 build
    # RPM lands in RPMS/

The plugin ships the public voicecall headers (LGPL 2.1, from
github.com/sailfishos/voicecall) and links the device's `libvoicecall.so.1`,
so only `voicecall-qt5` is needed in the target - no -devel package.
Install the RPM on the device; `%post` restarts `voicecall-manager`.
Check with: `journalctl --user -u voicecall-manager | grep WA-VOICECALL`.
