Name:       harbour-whatsapp
Version:    0.4.3
Release:    1
Summary:    WhatsApp Client for Sailfish OS
License:    MIT
Group:      Applications/Communications

%define _build_id_links none
%define debug_package %{nil}
%define __strip /bin/true
%define __spec_install_post %{nil}

Requires:   sailfishsilica-qt5
Requires:   nemo-qml-plugin-contacts-qt5
Requires:   pyotherside-qml-plugin-python3-qt5
#Requires:   sqlcipher (statisch gelinkt)

%description
Native WhatsApp client for Sailfish OS using whatsmeow library.

%install
rm -rf %{buildroot}

# Backend
mkdir -p %{buildroot}/usr/share/harbour-whatsapp
install -m 755 %{_sourcedir}/wa-backend %{buildroot}/usr/share/harbour-whatsapp/
install -m 644 %{_sourcedir}/start_backend.py %{buildroot}/usr/share/harbour-whatsapp/

# QML files
mkdir -p %{buildroot}/usr/share/harbour-whatsapp/qml
cp -r %{_sourcedir}/qml/* %{buildroot}/usr/share/harbour-whatsapp/qml/

# Desktop file
mkdir -p %{buildroot}/usr/share/applications
install -m 644 %{_sourcedir}/harbour-whatsapp.desktop %{buildroot}/usr/share/applications/

# Icons
mkdir -p %{buildroot}/usr/share/icons/hicolor
cp -r %{_sourcedir}/icons/hicolor/* %{buildroot}/usr/share/icons/hicolor/

%files
%defattr(-,root,root,-)
/usr/share/harbour-whatsapp
/usr/share/applications/harbour-whatsapp.desktop
/usr/share/icons/hicolor/*/apps/harbour-whatsapp.png

%changelog
* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.3-1
- The header now shows a meaningful connection status instead of just
  "Not connected": starting, connecting, reconnecting, waiting for
  pairing, logged out - and the actual error reason if the connection
  fails (e.g. "client outdated", "stream replaced", temporary ban)
- Backend exposes connection state and last error via the /status
  endpoint and handles ConnectFailure, ClientOutdated, StreamReplaced,
  TemporaryBan and Disconnected events

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.2-1
- Phone number input is now normalized automatically: "+", spaces, dashes
  and a leading "00" are stripped, so entering e.g. "+43 664..." for
  pairing just works instead of silently registering a wrong number
- Backend now binds to 127.0.0.1 only - previously the message API was
  reachable from the local network, which was a security problem
- If port 8085 is taken, the backend now falls back to 8086-8089 and the
  app follows automatically, instead of failing silently with
  "Could not connect to server"
- The app now shows an error message with the log file location if the
  backend fails to start

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.1-1
- First armv7hl (32-bit) build, for devices like the Xperia X / XA2 running
  32-bit Sailfish OS. "Could not connect to localhost port 8085" on those
  devices was caused by the 64-bit backend binary not being able to start
- Backend output is now logged to
  ~/.local/share/harbour/harbour-whatsapp/backend.log instead of being
  discarded, so problems are much easier to report and diagnose

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.0-1
- Fix login/session data being lost on every app restart: the backend data
  directory is now the Sailjail-persistent path
  ~/.local/share/harbour/harbour-whatsapp (existing data is migrated
  automatically on first start; thanks rdomschk and kempertom!)
- Fix incoming messages sometimes not matching the existing chat and
  showing up as a new, separate chat: WhatsApp now often addresses chats
  with anonymous @lid IDs instead of phone numbers; these are now resolved
  back to the phone number so chats no longer split (thanks rdomschk!)
- Fix chat entries with multi-line last messages painting over the next
  entry in the chat list ("overlapping text"; thanks defactofactotum!)

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.3.1-1
- Fix chat view not scrolling to the latest message: positionViewAtEnd()
  was called before the SilicaListView finished layouting; now a short
  Timer positions the view at the last chat bubble, so it is always
  visible without manual scrolling (thanks for the community report!)

* Sat Jul 11 2026 smatkovi <smatkovi@users.noreply.github.com> 0.3.0-1
- Update whatsmeow to 2026-07-09: fixes pairing and login failing with
  "Client outdated (405)", which made new pairings impossible
- Show pairing errors in the UI instead of failing silently when
  tapping "Start pairing"
- Backend is now statically linked including SQLCipher (no external
  sqlcipher dependency required anymore)
