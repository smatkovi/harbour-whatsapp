Name:       harbour-whatsapp
Version:    0.7.6
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
echo %{version} > %{buildroot}/usr/share/harbour-whatsapp/VERSION

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
%config(noreplace) /usr/share/applications/harbour-whatsapp.desktop
/usr/share/icons/hicolor/*/apps/harbour-whatsapp.png

%changelog
* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.7.6-1
- Privacy-first permissions: the app now ships WITHOUT the Contacts
  and Privileged Sailjail permissions. The Settings page shows whether
  the permission is currently granted and offers tap-to-copy devel-su
  commands to grant or revoke it (run in Terminal, restart the app)
- The desktop file is marked config(noreplace): app updates no longer
  overwrite your permission choice
- Existing users: after this update, run the grant command once from
  Settings if you want address book suggestions back

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.7.5-1
- Address book suggestions are now opt-in: new Settings page (main
  pulley) with a switch, default off. When disabled the PeopleModel
  is never instantiated, so the contact database is never touched.
  Note: Sailjail permissions themselves are static (no runtime
  permission dialogs on Sailfish OS); the Settings page explains this
  and shows how to remove the permission entirely as root
- Profile page now shows your current profile picture

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.7.4-1
- Search within a chat or group: "Search in chat" in the chat pulley
  opens a scoped search; tapping a result jumps back into the chat,
  scrolls to the matching message and briefly highlights it

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.7.3-1
- Search (main pulley): full-text search across chat names and all
  stored message texts with debounced live results - chat matches
  first, then messages newest-first with highlighted-context snippets;
  tap a result to open the chat

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.7.2-1
- Fix keyboard closing after every letter in the group-creation
  contact search: filtering swaps the list model, which recreates the
  ListView header and destroyed the focused search field. Name and
  search fields now live in a fixed header above the list

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.7.1-1
- Group creation: search field to filter the contact list by name or
  number; selection is kept while filtering and the participant count
  is shown in the section header

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.7.0-1
- Channels (WhatsApp newsletters): browse your subscribed channels
  (main pulley > Channels), read their messages in a read-only chat
  with media support, refresh on demand, follow via invite link and
  unfollow
- "Join via link" in the main pulley accepts both group invite links
  (chat.whatsapp.com/...) and channel links (whatsapp.com/channel/...)
  and prefills from the clipboard - scan QR codes with any scanner app
  and copy the link
- Communities: the group info page of a community lists its linked
  groups, tap to open them
- Group creation now offers the full merged contact list (local
  address book + WhatsApp contacts) instead of only WhatsApp contacts

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.6.0-1
- Load older messages: pulley entry in every chat asks your phone for
  the 50 messages before the oldest known one (on-demand history sync,
  phone must be online). Repeat to page further back - this also
  recovers media in chats paired with pre-0.4.9 versions
- Pin, mute and archive chats via long-press in the chat list, synced
  to your other devices via app state; pinned chats sort first,
  archived last with markers in the list
- Block and unblock contacts from the chat pulley menu
- Group management: create groups (name + participant selection),
  group info page with participant list, add/remove participants,
  rename, change group photo, copy invite link, leave group
- WhatsApp status updates now collect in a read-only "Status updates"
  pseudo-chat instead of producing a broken chat entry

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.5.2-1
- Media retry: when a tapped download fails because the media expired
  on WhatsApp's servers (404/410), the app now asks your phone to
  re-upload it (SendMediaRetryReceipt). Once the phone responds, the
  refreshed direct path is used to download automatically; if the app
  was quicker than the phone, just tap again. Requires the phone to
  be online

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.5.1-1
- Edit your own profile: push name, about text and profile photo
  (Profile entry in the main pulley menu). Photos are converted to
  JPEG automatically; new /profile, /setprofile and /setphoto
  endpoints

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.5.0-1
- Reactions: incoming reactions are shown aggregated under the bubble;
  react yourself via long-press (six common emojis)
- Replies/quotes: quoted messages are shown in a WhatsApp-style box;
  reply via long-press > Reply with a banner above the input field
- Edit and "Delete for everyone" for own messages via long-press;
  incoming edits ("edited" marker) and deletions are applied too
- Location messages show as a tile; tapping opens the coordinates via
  geo: URI in your maps app (e.g. Pure Maps). Contact cards, polls and
  group invites are rendered as text instead of being silently dropped
- All of the above also applies to history-synced chats where possible

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.14-1
- "Call +<number>" in the chat page pulley menu (1:1 chats) starts a
  regular cellular call via the Sailfish Phone app - the practical
  answer to WhatsApp calls, which cannot be taken on Sailfish
- "Call back" in the context menu of missed-call entries

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.13-1
- Group chats now show the sender's name above each message bubble,
  in a stable per-sender color (WhatsApp style). Names resolve via
  local address book, then WhatsApp push name, then phone number
- History sync now stores the actual group participant as sender
  instead of the group JID

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.12-1
- Incoming WhatsApp calls are now logged in the chat: "Missed call"
  or "Incoming call (answered on your phone)", for 1:1 and group
  calls. whatsmeow only receives call signaling - actually taking
  calls on Sailfish is not possible, but missed calls are no longer
  silently invisible

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.11-1
- The pairing form (phone number field + "Start pairing") is now only
  shown when the device is actually not linked. While an existing
  pairing is (re)connecting after app start, a busy indicator is shown
  instead ("paired" field added to /status)

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.10-1
- Fix updates silently keeping the old backend running: the launcher
  now compares the running backend's version (new "version" field in
  /status) against the installed one and replaces stale backends
  automatically (graceful /quit with state save, pkill fallback).
  No more manual "pkill wa-backend" or reboot after updating.

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.9-1
- Media in history-synced chats: images, videos, audio, documents and
  stickers from conversations imported at pairing time now show up as
  placeholders with size info and can be downloaded on demand by
  tapping them (previously all media messages from history were
  silently skipped, so freshly paired installs showed no pictures)
- Media keys are stored encrypted (rawmedia.enc) so downloads also
  work after a restart; downloaded media opens in the system viewer
- Live messages whose automatic download fails keep their media key
  and can be retried by tapping
- Clear error message when media has expired on WhatsApp servers

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.8-1
- Fix "Send image" (and "Send file") pickers showing no entries: the
  Sailfish gallery pickers query the Tracker3 media index over D-Bus,
  which requires the MediaIndexing Sailjail permission
- Also request RemovableMedia so pictures and files on the SD card
  show up in the pickers

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.7-1
- Fix wrong contact name shown on chats: local contact matching now
  canonicalizes both numbers to full international form (using your
  account's country code) and requires an exact match; the loose
  suffix fallback only applies with at least 9 matching digits and
  never overrides an exact match

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.6-1
- Fix chats failing to open (silently) with "TypeError: Property
  'endsWith' ... is not a function": String.endsWith is ES6 and not
  available in the Qt 5.6 QML engine on Sailfish OS; contact name
  matching now uses a compatible suffix check and also handles
  numeric phoneDetails values
- Suffix matching of phone numbers now requires at least 6 digits on
  both sides, avoiding false contact-name matches on short numbers

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.5-1
- Fix local address book contacts not showing up on the "New chat" page
  ("No contacts accessible"): the app now requests the Privileged
  permission in addition to Contacts, like other Sailjail apps with
  working contact access (e.g. Fernschreiber). Without it, qtcontacts
  only sees the non-privileged contacts database, which is empty on
  many installations. Sandboxing stays fully enabled.

* Sun Jul 12 2026 smatkovi <smatkovi@users.noreply.github.com> 0.4.4-1
- "New chat" now lists your local Sailfish address book (via PeopleModel)
  merged with your WhatsApp contacts, searchable by name or number, with
  a WhatsApp badge on contacts known to be on WhatsApp
- Local numbers are normalized automatically ("+43...", "0043...", and
  national "0676..." formats all resolve to the right WhatsApp number,
  using your own account's country code)
- Clear hint on the "New chat" page if no contacts are accessible

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
