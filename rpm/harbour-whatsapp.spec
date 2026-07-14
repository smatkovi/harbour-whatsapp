Name:       harbour-whatsapp
Version:    0.9.6
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
* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.6-1
- THE image download fix, found via QML runtime errors in the journal:
  the download state (downloadingId/downloadError) lived on the
  message ListView, but QML resolves unqualified names only against
  the scope object, the component root and ids - and a delegate is a
  component boundary. Every download binding in the message delegate
  threw ReferenceError, so taps never reached the handler (no request,
  no log, no visible reaction). The state now lives on the chat page
  root. Same class of bug fixed for the poll tile (vote counts threw
  ReferenceError from the option repeater); poll helpers now live on
  the delegate root. Undefined-to-bool binding warnings hardened

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.5-1
- Fix downloads doing literally nothing after one stuck attempt: a
  single hanging /download request left the UI download guard set
  forever, silently swallowing every further tap (matches the empty
  backend log). Downloads now have timeouts on both sides (60 s UI,
  90 s backend CDN deadline), a busy guard message instead of
  silence, and clear timeout errors
- Logout remorse timer extended to 15 seconds

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.4-1
- Download taps can no longer fail silently: empty or connection-level
  failures (HTTP status 0) now show a clear error under the message
  instead of nothing; the backend logs every /download request and
  which branch it took, so backend.log pinpoints remaining cases
- After a successful media retry the raw key is kept (with the fresh
  direct path) per the re-download policy, instead of being dropped

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.3-1
- Fix tap-to-download for media from before a re-pairing: after
  re-registering, WhatsApp's CDN answers old direct paths with 403
  (bound to the old session), which bypassed the media-retry path
  that only matched 404/410. All three cases now use whatsmeow's
  typed errors and ask the phone to re-upload; the answer arrives
  asynchronously, so tap once ("requested re-upload..."), wait a
  few seconds with the phone online, then tap again

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.2-1
- Live location sharing: chat menu "Share live location" (15 min/1 h/
  8 h). Position is streamed every ~20 s via GPS while the app keeps
  running - background/cover works like Pure Maps; closing the app or
  "Stop live location" ends the share, recipients see moving updates.
  Requires the Location permission
- Fix tap-to-download for media whose file was deleted after a
  successful download (storage clear, file manager, ephemeral
  cleanup): /download now stat()s the stored path and re-downloads
  instead of returning a dead path, and the image view triggers a
  re-download on load errors
- Location permission sed grant/revoke verified with an 11-case matrix

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.1-1
- Mentions by name: typing @ in a group shows live suggestions from
  the participant list (filtered as you type); picking one inserts
  @Name, which is translated to the protocol form on send. Incoming
  @<number> mentions are displayed as @Name everywhere
- Pinned message bar: the latest pinned message is shown in a bar
  right below the page header; tapping it jumps to the message
- Send location: chat menu entry with GPS autofill (QtPositioning)
  and manual coordinate entry plus optional label; Location
  permission grant/revoke commands added to Settings. Note: real live
  location sharing requires a continuous update stream from the
  sharing device and is not implemented - this sends a static pin

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.0-1
- Mentions: type @<number> in groups to mention; messages mentioning
  you are marked with a bell
- Forwarding: context menu "Forward..." with chat picker; text carries
  the forwarded flag, media is re-sent from the local file
- Live locations: shown like locations with a live marker; incoming
  updates move the existing entry instead of spamming the chat
- Disappearing messages: set per chat (off/24h/7d/90d) from the chat
  menu; incoming timer changes are shown; expired messages are cleaned
  up locally; outgoing messages honor the chat timer
- Pin/unpin messages in chat (for everyone) via context menu
- Clear chat and delete chat (local) from the chat menu
- Group descriptions can be set from group info
- Join requests: list, approve and reject from group info
- Group invite messages are rendered with a "Join group" action

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.29-1
- App state diagnostics: after the (error-free) full sync still
  yielded 0 contacts, log the stored patch versions - version > 0
  with 0 contacts proves the server-side app state itself is empty,
  consistent with the phone having been freshly re-connected: the
  phone needs to re-upload its contact list before any companion
  device (including WhatsApp Web) can see names or reach contacts
  with status posts

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.28-1
- Fix own statuses reaching nobody: whatsmeow does not perform the
  initial app state sync automatically - it must be requested by the
  client (as mautrix-whatsapp does after login). With the contact
  store empty (3 contacts, 0 with full name on the affected device),
  the status fan-out list was empty. When the store has no named
  contacts on connect, a full app state sync (contact list, pins,
  mutes, archive states) is now requested from the phone and the
  resulting contact counts are logged

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.27-1
- Status media presentation: feed images are no longer cropped into a
  low strip - they render aspect-fit on a black card up to 60% of the
  screen height; tapping an image opens a fullscreen viewer (black
  background, caption overlaid, tap to close), videos open in the
  media player as before

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.26-1
- Diagnostics for status reach: on connect, log how many contacts the
  whatsmeow store knows (own statuses are only fanned out to contacts
  with a full name - after a fresh pairing this can be near zero until
  the app-state sync from the phone completes). Also documents the
  reception latency after re-pairing: contacts' phones only include a
  newly linked device in their status fan-out after refreshing its
  device list, typically when they next message you

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.25-1
- Image/video statuses now support a caption: after picking media, a
  preview dialog asks for an optional caption before posting - the
  WhatsApp way of putting text on a full-image status (solid-colour
  backgrounds remain the text-status variant)

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.24-1
- Delete your own status: cross icon next to your status in the feed
  revokes it for everyone (WhatsApp does not support editing statuses,
  only delete + repost). Revoked statuses disappear from the feed
- Background colour picker for text statuses (WhatsApp-style palette)
- Reception diagnostics: undecryptable incoming messages are now
  logged with sender/chat, status broadcasts specially flagged, to
  pin down why contact statuses are not appearing

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.23-1
- Post image and video statuses: "Post image or video" in the Status
  page pulley opens the content picker; media is uploaded and sent to
  the status broadcast, distributed per your status privacy settings,
  and shown immediately in your own feed. Incoming media statuses were
  already displayed via the regular media pipeline (auto/tap-to-
  download)

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.22-1
- Post your own text status: pulley menu on the Status page, delivered
  according to your WhatsApp status privacy settings; appears in your
  own feed immediately. This doubles as the end-to-end test for status
  reception (own statuses are echoed to linked devices)
- Every incoming status broadcast is now logged as a camera line in
  backend.log to make reception diagnosable
- Note: polls in 1:1 chats are official WhatsApp behaviour, the
  compose option there is intentional

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.21-1
- The daemon finally told us in plain words what was wrong: "SQLCipher
  plugin only supports collection names with alphanumeric Latin-1
  characters". Collection and secret names contained hyphens
  (harbour-whatsapp-secrets, encryption-key) and were rejected on
  every attempt - renamed to harbourwhatsapp / encryptionkey, same
  scheme Storeman uses ("storeman"). CollectionAlreadyExists is now
  tolerated via the daemon error code instead of message matching

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.20-1
- Sailfish Secrets, final piece: with transport working (0.8.19), the
  remaining store/retrieve failures were argument marshalling - the
  code passed structs as []interface{}, which godbus sends as variant
  arrays "av" instead of D-Bus structs "(sss)" etc. All Secrets calls
  now use proper Go struct types matching the daemon introspection
  signatures exactly (Identifier, Secret, InteractionParameters, enum
  wrappers), daemon Result codes/messages are parsed and logged, and
  timeouts allow for the daemon's delayed replies

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.19-1
- Hopefully the actual Secrets fix. With the read loop now running,
  the persistent EOF pinned the cause to the message itself: godbus'
  Object().Call() always sets a DESTINATION header field, even empty,
  which is invalid on a peer (non-bus) connection - libdbus-based
  servers like Qt's sailfishsecretsd drop such messages without a
  reply (EOF). We now build the method-call message by hand without a
  DESTINATION field, matching how Qt peer clients talk. The
  getPluginInfo self-test is the tell

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.18-1
- Follow-up to the Secrets fix: 0.8.17 turned the EOF into a timeout
  because the hand-rolled handshake never started godbus' internal
  read loop (it is only started by conn.Auth), so replies were never
  read. Now we wrap the raw socket with dbus.NewConn (generic
  transport, no unix-FD support advertised) and call conn.Auth with
  EXTERNAL - this runs the real handshake without FD negotiation AND
  starts the read loop. The getPluginInfo self-test should now pass

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.17-1
- Very likely fix for the Sailfish Secrets EOF. Root cause found by
  reading the sailfish-secrets daemon and godbus sources: godbus'
  built-in Auth() always negotiates NEGOTIATE_UNIX_FD on unix sockets,
  and Qt's QDBusServer in sailfishsecretsd handles that in a way that
  makes godbus drop the connection right after auth succeeds - visible
  as "ready" but EOF on the first real call. We now perform the SASL
  EXTERNAL handshake ourselves on the raw socket (no FD negotiation)
  and hand the authenticated socket to dbus.NewConn, whose generic
  transport does not advertise unix-FD support. The getPluginInfo
  self-test from 0.8.16 confirms whether this worked

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.16-1
- Attempt to fix Sailfish Secrets EOF (secretsd dropping every real
  request) by explicitly using EXTERNAL D-Bus authentication with the
  process UID on the peer-to-peer socket, matching what Qt's
  QDBusServer in sailfishsecretsd expects, instead of letting the
  library negotiate the mechanism. Added a getPluginInfo self-test on
  startup so backend.log distinguishes an auth/transport problem from
  a message-marshalling one

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.15-1
- Fix "Reset & pair again" looping straight back into relogin_required:
  the launcher's one-time data migration from the pre-0.4.x location
  (~/.local/share/harbour-whatsapp) kept restoring an ancient plaintext
  wa.db whenever the current one was missing - i.e. right after every
  reset. The migration is removed; under the Secrets-only policy those
  legacy remnants require a fresh pairing anyway

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.14-1
- The relogin/secrets explanations are now shown as a full wrapping
  text block instead of being cut off in the single-line status row
- After "Reset & pair again" the UI stays in the starting state until
  the restarted backend reports its real state, instead of briefly
  exposing the pairing form against a dead backend ("pairing failed
  (0)"); unreachable/starting backends now produce a clear message
  when pairing is attempted too early

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.13-1
- Fix the relogin_required/secrets_error explanations from 0.8.12
  never reaching the UI: /status overrode the state with "starting"
  whenever the client was nil - which is exactly the case in those
  halt states. "starting" is now only reported while no state is set

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.12-1
- Encryption is now strictly Sailfish-Secrets-only. If the local
  database was created without Sailfish Secrets (plaintext SQLite
  header - the result of earlier silent "development mode" fallbacks),
  the app stops with an explanation and a "Reset & pair again" button:
  it deletes the local database (chats stay on the phone and re-sync)
  and creates a new, encrypted one on the next pairing. If Sailfish
  Secrets itself is not responding, the app explains that instead of
  silently running unencrypted - no database is created or opened
  without a Secrets-stored key. The silent development-mode fallback
  is gone

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.11-1
- Fix settings (address book opt-in, download policies) appearing to
  reset on every app start: preferences were fetched exactly once at
  backend handshake, which since 0.8.8 happens while the backend is
  still in the "starting" phase before its /prefs endpoint exists -
  the single fetch 404ed and was never retried. Preferences are now
  (re)loaded as soon as the backend leaves the starting state

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.10-1
- Fix ~30 s "Starting backend" hang: the Secrets discovery used the
  process-wide shared D-Bus session connection and closed it, so from
  the second attempt on, every retry of the 0.8.5 handshake loop
  failed against its own closed connection and the loop always ran to
  exhaustion. Discovery now uses a private connection; init and key
  retrieval retry independently with shorter backoff, capped at ~8 s
  total. Normal warm starts are back to a moment

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.9-1
- Fix status updates never arriving: WhatsApp only delivers status
  broadcasts (stories) to devices that announce "available" presence,
  which the backend never did. It now sends available presence on
  every connect - like WhatsApp Web, the device counts as online while
  connected. Note: statuses are push-only; the page fills with what
  contacts post from now on, there is no way to fetch past statuses

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.8-1
- Fix "Not connected" hanging after the 0.8.5 pairing fix: the backend
  bound its HTTP port only after the (now potentially slow) Secrets
  handshake and DB init, so the UI could not tell "still starting"
  from "dead" and would keep polling a port the backend never got.
  The port is now bound first and /status responds immediately with
  state "starting"; the UI additionally rescans ports 8085-8089 if its
  remembered port stops answering
- The Status page is only attached (glow indicator, swipe from the
  right) once the connection is up

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.7-1
- Fix white screen on startup introduced in 0.8.6: the status page
  used Column.padding, which does not exist in QtQuick 2.0, so the
  whole QML file failed to load. Replaced with explicit margins

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.6-1
- Dedicated Status page as a Sailfish attached page: the main chat
  list shows the glow indicator at the top right, swipe left to open.
  Status updates from contacts are listed newest-first with sender,
  time, text and media (tap to download, tap again to view); pull
  down to refresh. The former read-only status pseudo-chat is gone
  from the chat list

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.5-1
- Fix pairing button doing nothing on the very first launch after a
  reboot (previously a workaround was to start the app once from the
  terminal). Root cause: on a cold start sailfishsecretsd may not be
  ready yet, so the backend took longer than the launcher waited.
  The backend now retries the Secrets handshake with backoff, the
  launcher waits up to ~25 s and restarts the backend once if it exits
  early, and a "Retry connection" button is shown if startup still
  fails instead of an unresponsive pairing button

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.4-1
- Add group participants from the contact list: "Add from contacts" on
  the Group info page opens a searchable multi-select of your merged
  contacts (address book + WhatsApp), excluding people already in the
  group. The manual number field remains as an alternative

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.3-1
- Create polls yourself: "Create poll" in the chat pulley (question,
  2-12 options, optional multiple answers)
- Group admin management: promote/demote participants to/from admin
  via long-press on the Group info page (promote/demote actions)
- Phone numbers are now shown when selecting contacts for a new group
  and for each participant on the Group info page; participant
  long-press offers "Call +<number>" for a cellular call

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.3-1
- Create polls: "Create poll" in the chat pulley opens a dialog with
  question, dynamically addable options (2-12) and a multiple-answers
  switch; the poll appears as an interactive tile for all participants
- Group admin management: long-press a participant on the Group info
  page to promote to admin or remove admin rights (in addition to the
  existing add/remove)

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.2-1
- Fix newly created groups not appearing in the chat list: the list is
  built from stored messages, and a fresh group has none. Group
  creation now records the group name and adds a system entry
  ("Group created"), so the group shows up immediately and can be
  opened and written to
- Group creation reports success or the actual error on the main page
  (previously failures were silently swallowed)

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.1-1
- Vote in polls: poll messages are now interactive - tap an option to
  vote (tap again to retract; multi-answer polls toggle selections).
  Votes are end-to-end encrypted via the poll's message secret
  (whatsmeow BuildPollVote). Incoming votes from others are decrypted
  and live vote counts are shown per option, with your own choice
  highlighted
- Limitation: polls imported via history sync carry no message secret,
  voting on them fails with a clear error; polls received live work

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.8.0-1
- Per-type automatic download policy (Settings): Images, Stickers,
  Videos, Audio, Documents and Profile pictures can each be set to
  Always / Wi-Fi only / Never. Wi-Fi detection via the default route;
  defaults: images/stickers/avatars always, the rest Wi-Fi only.
  Tap-to-download always works regardless of the policy
- Storage overview (Settings): per-category size and file count, with
  long-press to delete a category (remorse timer). Deleted chat media
  reverts to the download placeholder and can be re-fetched; deleting
  profile pictures re-queues them
- Fix a latent double-RUnlock crash in avatar caching (triggered when
  a cached avatar file disappeared at runtime)

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.7.9-1
- Fix avatars and media disappearing after revoking the media storage
  permission: files downloaded earlier live under ~/Pictures etc.,
  which becomes invisible to the sandbox. On startup the backend now
  validates all stored paths, re-queues inaccessible avatars (they are
  re-fetched automatically into the private data folder) and clears
  inaccessible media paths so chats show the download placeholder
  again
- Media keys are no longer discarded after a successful download, so
  such media can simply be downloaded again by tapping

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.7.8-1
- More robust permission grant/revoke commands: each permission token
  is now added or removed individually on the Permissions line only,
  independent of order and adjacency, idempotent, and tolerant of
  hand-edited lines (missing trailing semicolon, partial states,
  legacy token order from older installs). Verified against a nine-
  case test matrix

* Mon Jul 13 2026 smatkovi <smatkovi@users.noreply.github.com> 0.7.7-1
- Minimal permissions by default: the app now ships with only
  Internet and Secrets. Media storage (UserDirs, MediaIndexing,
  RemovableMedia) is opt-in like contacts, with status display and
  tap-to-copy grant/revoke commands on the Settings page
- Without the media permission the app stays fully functional:
  received media is stored inside the app's private data folder
  (media/ next to the message database) instead of ~/Pictures etc.,
  it is just not visible in Gallery and the system pickers for
  sending images/files appear empty

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
