Name:       harbour-whatsapp
Version:    0.9.90
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
# Voice-Aufnahme: der Rekorder wird bei der Installation an einen
# exec-erlaubten Ort gebuendelt - ohne dieses Paket lief %post ins Leere
# und die Aufnahme scheiterte mit einem irrefuehrenden Errno 13
Requires:   gstreamer1.0-tools
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

# Opt-in-Daemon (systemd user unit)
mkdir -p %{buildroot}/usr/lib/systemd/user
install -m 644 %{_sourcedir}/harbour-whatsapp-daemon.service %{buildroot}/usr/lib/systemd/user/

# QML files
mkdir -p %{buildroot}/usr/share/harbour-whatsapp/qml
cp -r %{_sourcedir}/qml/* %{buildroot}/usr/share/harbour-whatsapp/qml/

# Desktop file
mkdir -p %{buildroot}/usr/share/applications
install -m 644 %{_sourcedir}/harbour-whatsapp.desktop %{buildroot}/usr/share/applications/
install -m 644 %{_sourcedir}/harbour-whatsapp-daemon.desktop %{buildroot}/usr/share/applications/
# Daemon-Binary: sailjail verlangt ein ELF (kein Skript) in /usr/bin -
# Hardlink auf das Backend, cpio dedupliziert (kein Groessenzuwachs)
mkdir -p %{buildroot}/usr/bin
ln %{buildroot}/usr/share/harbour-whatsapp/wa-backend %{buildroot}/usr/bin/harbour-whatsapp-daemon

# Icons
mkdir -p %{buildroot}/usr/share/icons/hicolor
cp -r %{_sourcedir}/icons/hicolor/* %{buildroot}/usr/share/icons/hicolor/

%files
%defattr(-,root,root,-)
/usr/share/harbour-whatsapp
%config(noreplace) /usr/share/applications/harbour-whatsapp.desktop
/usr/share/icons/hicolor/*/apps/harbour-whatsapp.png
/usr/lib/systemd/user/harbour-whatsapp-daemon.service
/usr/share/applications/harbour-whatsapp-daemon.desktop
/usr/bin/harbour-whatsapp-daemon

%post
# Desktop-File-Migration: harbour-whatsapp.desktop ist %config(noreplace),
# damit Nutzer-Grants (Microphone etc.) Updates ueberleben - neue Pflicht-
# Schluessel muessen daher idempotent nachgeruestet werden, sonst fehlt
# dem Jail die dbus-Erlaubnis (Reply) bzw. die Aktivierung (Tap-Kaltstart)
D=/usr/share/applications/harbour-whatsapp.desktop
grep -q '^X-Maemo-Service=' $D || sed -i '/^\[X-Sailjail\]/i X-Maemo-Service=harbour.whatsapp.backend' $D
grep -q '^ExecDBus=' $D || printf 'ExecDBus=/usr/bin/sailjail -p harbour-whatsapp.desktop -- /usr/bin/sailfish-qml harbour-whatsapp\n' >> $D

# gst-launch am exec-erlaubten Ort verfuegbar machen (Voice-Aufnahme):
# /usr/bin kann im Sailjail auf eine Positivliste reduziert sein
ln -f /usr/bin/gst-launch-1.0 /usr/share/harbour-whatsapp/gst-launch-1.0 2>/dev/null ||   cp /usr/bin/gst-launch-1.0 /usr/share/harbour-whatsapp/gst-launch-1.0 2>/dev/null || true
ln -f /usr/bin/pactl /usr/share/harbour-whatsapp/pactl 2>/dev/null ||   cp /usr/bin/pactl /usr/share/harbour-whatsapp/pactl 2>/dev/null || true

%postun
if [ "$1" = "0" ]; then
  rm -f /usr/share/harbour-whatsapp/gst-launch-1.0 /usr/share/harbour-whatsapp/pactl
fi

%changelog
* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.90-1
- Notification reply repaired on updated installs: the main desktop
  file is %config(noreplace) so user permission grants survive
  updates - which also meant the 0.9.87 additions (X-Maemo-Service
  for the backend reply bus name, ExecDBus for tap-to-open cold
  start) never reached modified installations; the new file sat
  unused as .rpmnew, the jail lacked the dbus grant, RequestName
  failed silently and lipstick discarded typed replies. %post now
  migrates the installed desktop file idempotently (user grants
  untouched), and the reply service logs its failures instead of
  retrying in silence. After the update: fully close and reopen the
  app (and restart the daemon if enabled) so the jail is composed
  with the new grant

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.89-1
- Gallery visibility (community suggestion): optional per-type
  .nomedia markers hide the WhatsApp media folders from Gallery and
  Media apps - separate toggles for received images, videos, voice
  notes/audio, documents and profile pictures (Settings, shown when
  media storage access is granted). The switches reflect the actual
  marker files on disk; the tracker picks changes up on its next
  indexing run

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.88-1
- Voice recording on devices without gstreamer1.0-tools (OpenRepos
  report: "all permissions granted" but errno 13 on gst-launch-1.0):
  the recorder is bundled at install time by hardlinking the system
  gst-launch-1.0 - on devices where that tool was never installed,
  %post silently had nothing to bundle and recording failed with a
  misleading permission error (execvp aggregates EACCES over jailed
  PATH entries). gstreamer1.0-tools is now a declared RPM dependency,
  so the store installs it automatically, and the runtime fallback
  chain reports its findings verbatim (bundled copy -> /usr/bin ->
  precise install instructions) instead of a bare errno

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.87-1
- Tapping a notification opens the conversation: the default remote
  action calls openChat(jid) on the canonical bus name
  harbour.harbour-whatsapp, now owned by the GUI (DBusAdaptor) - and
  if the app is not running, sailjaild starts it via the new ExecDBus
  line in the desktop file and delivers the call after startup, so
  the tap works from a cold start too. The backend reply service
  moves to a second name (harbour.whatsapp.backend) declared via
  X-Maemo-Service in both desktop files - sailjaild turns that key
  into a dbus-user.own grant (sailjailclient.c line 854)

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.86-1
- One notification per message again: group messages produced two -
  a reply-less one titled with the group (legacy QML-side publishing)
  and one titled with the sender (backend). The QML duplicate is
  removed; the backend notification is the only one and carries the
  reply action
- Group notifications are titled with the GROUP name now, the sender
  moves into the preview ("Sender: message") - replying from the
  notification answers into the group, as expected

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.85-1
- Clearer permission guidance after an OpenRepos report ("permissions
  are granted but a message says no permission"): the app ships with
  a minimal desktop file, so the Sailfish Settings app has no
  Microphone entry to grant - the permission must first be ADDED via
  the tap-to-copy Terminal command in the app's own settings. The
  microphone notice now says exactly that and where, and the Sailjail
  permissions section explains the two levels up front

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.84-1
- Reply directly from the events view, like SMS: notifications carry
  a named remote action with type=input (the mechanism learned from
  the commhistory-daemon and nemo-qml-plugin-notifications sources) -
  lipstick shows the reply arrow with a text field and calls
  Reply(chat, text) on the backend via the session bus. The backend
  owns the sandbox-permitted bus name harbour.harbour-whatsapp
  (sailjailclient.c grants OrganizationName.ApplicationName),
  delegates to its own /send (identical local echo and ephemeral
  handling) and closes the notification. Because the BACKEND answers,
  replying works even with the app closed, through the daemon

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.83-1
- Duplicate notifications switches merged: "Event screen
  notifications" (older wording, better description) and
  "Notifications" (daemon-era logic) both wrote the same backend
  pref with separate UI state that could contradict each other. One
  switch remains, carrying the old name and description and the new
  logic (immediate daemon handover, prefs-ready guard, state kept in
  sync with the in-app trigger logic). Sound and vibration toggles
  are thereby coupled to "Event screen notifications" - and to
  nothing else

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.82-1
- Notification sound/vibration toggles are shown together with the
  notifications feature they belong to (stage 1), while remaining
  fully independent of the background daemon - the description now
  says exactly that

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.81-1
- Notification sound and vibration toggles are independent settings
  now, always visible and configurable regardless of the
  notifications stage or daemon state - they simply apply whenever a
  notification fires

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.80-1
- Notification sound and vibration are separately switchable
  (sub-toggles under Notifications, both default on): the
  x-nemo-feedback list names the ngfd events ("chat" for sound,
  "vibra" for vibration); actual behaviour additionally follows the
  ringtone profile
- Events view cleans itself: bringing the app to the foreground
  closes all of its notification entries - previously only opening
  the specific chat cleared its entry

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.79-1
- Permission wording polish: the Audio+Sensors grant note now also
  mentions the earpiece volume control it enables and states
  explicitly that the app NEVER records with only these permissions
  (recording happens solely via the mic button, which requires the
  Microphone permission and refuses otherwise); the Microphone grant
  row notes that it includes the Audio permission, so its system
  prompt surprises nobody either

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.78-1
- Earpiece debug logging removed now that the feature is verified:
  the per-event cost was negligible, but ui-debug.log grew without
  bound. The mce reachability probe is gone as well (question
  settled: reachable, call model works)
- Runtime gate matched to the status display: (Audio OR Microphone)
  plus Sensors enables ear-speaker switching - previously the
  runtime required the explicit Audio token while the 0.9.77 status
  line already promised readiness for Microphone+Sensors
- Sensors stays a required permission for the feature: upstream
  sailjail-permissions shows Sensors.permission is exactly the
  com.nokia.SensorService D-Bus grant and the base profile contains
  no sensor access - without it the proximity sensor is silent in
  the sandbox

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.77-1
- Permission display fixes: the ear-speaker readiness line now
  accounts for Microphone including Audio (Microphone+Sensors showed
  a wrong "needs audio" although switching works), and the Audio
  status line says "included in Microphone" in that case instead of
  "not granted"

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.76-1
- Earpiece display handling rebuilt on the call model, straight from
  the mce sources (tklock.c UIEXCEPTION_TYPE_CALL): instead of
  fighting mce with manual display/tklock requests, the app now
  declares a call state ("req_call_state_change active/none") while
  audio plays on the earpiece - mce then natively blanks when the
  sensor is covered and ACTIVATES the display when it is uncovered,
  exactly like a real phone call, with its own sensor. All manual
  wake juggling removed. When playback ends at the ear, the full
  release (route, volume, call state) is deferred until "far" (25s
  safety timeout); mce additionally restores the call state itself
  if the app vanishes from D-Bus. Leaving the player page releases
  everything including the saved volume

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.75-1
- Earpiece wake hardening: taking the phone off the ear DURING
  playback left the device locked. The wake sequence (display on +
  tklock unlock) now repeats three times over ~1s - mce can see
  "call + near" right after the route flip and cancel an early wake
  - and is additionally re-sent once the Route Manager confirms the
  route is back on speaker. An mce reachability probe at player
  start logs whether com.nokia.mce is even callable from the
  sandbox, settling the filter question for good

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.74-1
- Proximity earpiece polish after on-device testing: waking the
  display is deferred until the sensor actually reports "far" -
  voice notes often END while the phone is still at the ear, and
  waking immediately made mce blank and lock the screen again
  (stuck lockscreen). The sensor stays active while the ear mode
  is winding down so the far event is never missed
- Earpiece volume: the earpiece stream class is quiet and the
  volume keys do not reach it - entering ear mode now sets the sink
  to a defined 60% (via pactl, hardlinked to the exec-allowed app
  dir like gst-launch) and restores the previous volume when
  switching back

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.73-1
- Ear-mode gate made fully symmetric: the player enables it only
  with BOTH explicit tokens (Audio and Sensors) confirmed via
  /permcheck. Sensors was previously only implicitly gated by the
  sandbox silencing the proximity sensor - correct today, but the
  same class of implicit trust that produced the microphone-include
  mismatch; now the displayed model is enforced on both halves

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.72-1
- Permission matrix walked across all eight Audio/Sensors/Microphone
  combinations; one inconsistency found and fixed: with
  Microphone+Sensors (but no explicit Audio token) the ear mode ran
  anyway - sailjail's Microphone permission includes Audio - while
  the status honestly said "needs audio". The player now checks
  /permcheck on open and enables ear mode ONLY with the explicit
  Audio token: display model and runtime behaviour now agree in
  every row of the matrix

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.71-1
- Ear mode is advertised and checked purely as Audio+Sensors:
  the microphone permission no longer appears in the readiness
  logic or as an alternative route - microphone means recording,
  nothing else. Audio shows plainly granted/not granted by its own
  token

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.70-1
- Permission pairs reorganized by purpose: "Audio+Sensors" grants
  ear-speaker listening WITHOUT any microphone access (Audio brings
  the routing D-Bus, Sensors the proximity), "Microphone" grants
  voice-note recording (and includes Audio at the sailjail level, so
  mic + sensors also enables ear mode). The status now states
  ear-mode readiness explicitly ("ready" / "needs audio+sensors" /
  "needs sensors" / "needs audio (or microphone)") and shows Audio
  as "granted (via microphone)" where applicable

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.69-1
- Ear-mode test matrix walked, one real hole found and fixed:
  with headphones or Bluetooth connected, a covered proximity
  sensor (pocket!) would have yanked audio onto the ear speaker -
  ear mode now engages only when the active output route is the
  loudspeaker (ActiveRoutes check on each near event, like the
  official clients)
- Sensors is its own separate optional permission again: dedicated
  grant/revoke tap-to-copy commands next to the microphone pair
  (microphone = voice notes; sensors = proximity, ear mode needs
  both and stays safely off with only one granted)

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.68-1
- Ear mode complete: the proximity sensor needs the Sensors sailjail
  permission (silently empty without it - found via the file log).
  The grant/revoke commands in Settings now set/remove BOTH tokens
  (Microphone + Sensors), /permcheck reports Sensors, and the wake-up
  unlock is fired twice (immediately and after 300ms) to win the race
  against the lockscreen engaging after display-on

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.67-1
- Ear-mode diagnostics to file (~/.local/share/harbour/
  harbour-whatsapp/ui-debug.log): player page open, Routes reply
  (raw), earpiece type found, every proximity reading and every
  earpiece switch - debuggable without terminal launch and without
  sound, considerate of sleeping households

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.66-1
- Ear mode wakes up WITHOUT the lockscreen: after req_display_state_on
  the touch lock mce engages on blanking is lifted again
  (req_tklock_mode_change unlocked) - a device lock with security
  code deliberately stays in place. Diagnostic logging around the
  Routes lookup and earpiece switching to pin down why the in-app
  switch did not fire

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.65-1
- The display now turns off while the phone is held to the ear
  during playback (mce req_display_state_off/on) - also preventing
  cheek touches on pause/seek - and back on when moving away, when
  playback ends and when leaving the player. Nemo.KeepAlive holds
  the device awake during ear mode so the "far" proximity event
  always gets through (audio playback usually prevents suspend, but
  guaranteed is better)

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.64-1
- WhatsApp-style proximity earpiece: holding the phone to your ear
  while a voice note or audio plays routes the sound to the ear
  speaker, moving it away routes back (QtSensors proximity + ohm
  Route Manager Prefer on the system bus - the real signature is
  string,uint32,uint32, the introspection XML lies). The
  device-specific earpiece type bits are read from the Routes list
  at runtime instead of being hardcoded. Reset is guaranteed
  threefold: on far, on playback stop/end, and on leaving the
  player page. Requires the microphone permission (its included
  Audio permission whitelists the Route Manager D-Bus interface);
  without it the calls fail silently and playback stays on the
  loudspeaker

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.63-1
- Voice recording vs. the sandbox, round two: launching gst-launch-1.0
  from /usr/bin fails inside the jail (EACCES - sailjail can reduce
  /usr/bin to an allowlist), while the manual pipeline works
  unsandboxed. The recorder is now started from
  /usr/share/harbour-whatsapp - the path the backend provenly executes
  from - via a hardlink to the system binary created at install time
  (%post). Early recorder deaths now report the recorder's actual
  stderr verbatim instead of just an exit code

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.62-1
- Voice recording hardened after walking the permission/flow test
  matrix: the recorder process dies with the app via PR_SET_PDEATHSIG
  (previously an orphaned gst-launch kept the MICROPHONE hot after
  closing the app mid-recording - privacy hole); missing microphone
  permission is reported immediately at start instead of after
  recording into the void; leaving the chat page cancels a running
  recording; sub-second double-taps are discarded ("too short")
  instead of sending 0-second notes; a notice at recording start
  points out the discard (X) and send controls

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.61-1
- Voice notes (requested on OpenRepos - "the only thing missing"):
  tap the mic button (shown while the text field is empty) to record,
  tap send to stop and send, tap the X to discard. Recording runs via
  GStreamer (PulseAudio -> Opus/OGG, 16 kHz mono) and is sent as a
  real WhatsApp voice note - PTT flag, audio/ogg codecs=opus mimetype
  and duration - which is exactly the combination Android, iOS and
  Web require to render it as a playable voice message instead of a
  generic audio attachment
- Microphone is a new OPTIONAL sailjail permission, handled like the
  others: status display plus tap-to-copy grant/revoke Terminal
  commands in Settings; the app keeps shipping with minimal
  permissions

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.60-1
- Daemon section hints: after enabling, restart the app if the status
  does not switch to running within a few seconds; switching
  notifications off only stops the running daemon - removing the
  autostart completely needs the Terminal disable command. Since the
  enabled state cannot be probed from inside the sandbox
  (~/.config/systemd is hidden; a probe would err towards hiding),
  a local "ever enabled" flag decides when to show the disable
  command: while the daemon runs, or after the enable command was
  copied and the disable command has not been copied yet

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.59-1
- Notifications toggle no longer shows "off" while the backend says
  on (display-sync bug family, member four): the switch relied on a
  Connections element to follow the async prefs load - the same
  construct that already failed for the auto-download boxes. The
  sync handler now lives directly on the settings page (the
  property's owner), which fires reliably

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.58-1
- Daemon early exit before connecting: an enabled unit starts at
  every login - with notifications off, the daemon now exits right
  after loading prefs and BEFORE touching WhatsApp (previously the
  30s watchdog caught it only after the connection was already
  established). An enabled-but-"disabled" unit thus never shows
  presence; only the running process can be controlled from the UI,
  removing the autostart link still needs the one terminal command

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.57-1
- Switching notifications off now stops a running daemon immediately
  (sandbox-compatible: the GUI asks it to /quit - a clean exit that
  Restart=on-failure leaves alone - and respawns a child backend for
  the open app). Previously the daemon kept showing "running" until
  the watchdog caught it after the app was closed. The autostart
  symlink remains until the disable command is run; a daemon started
  at next login exits by itself while notifications are off

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.56-1
- cwd guard: the backend derives its data directory from the working
  directory - started manually (or with the sandbox mapping the cwd
  to $HOME), it created a FRESH empty wa.db in $HOME and reported
  "need to pair" although the real database exists. With cwd at
  $HOME or /, it now switches to the canonical app data directory
  (~/.local/share/harbour/harbour-whatsapp) by itself

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.55-1
- Daemon launch, layer four: sailjail additionally requires the
  launched file to be an ELF binary (shell wrapper rejected: "is not
  elf binary"). /usr/bin/harbour-whatsapp-daemon is now a hardlink to
  the backend itself - same file under a second name, no size
  increase (cpio deduplicates hardlinks). The stale-backend pkill
  fallback also matches the daemon process name now

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.54-1
- Daemon launch, layer three: the desktop-profile validation passed
  (one-time permissions confirmation), but firejail refuses to launch
  executables from /usr/share ("no suitable ... executable found") -
  the launcher enforces noexec there, while exec from within the
  running jail is fine. The daemon now starts through a small wrapper
  at /usr/bin/harbour-whatsapp-daemon (harbour convention), which
  execs the backend; desktop file and unit point at it

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.53-1
- Daemon vs. sailjail exec validation: sailjail refuses to launch a
  binary that is not named in the profile's Exec line ("Exec line
  does not contain .../wa-backend"), and the app desktop naturally
  says sailfish-qml. The daemon now uses its own hidden desktop file
  (NoDisplay, Exec=wa-backend) with the SAME OrganizationName and
  ApplicationName, keeping the secrets identity - whether sailjail
  additionally requires the desktop filename to match ApplicationName
  is being verified empirically on device

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.52-1
- Daemon takeover: started via systemctl while the app is open, the
  daemon now politely /quits any existing backend before binding -
  previously two backends fought over the WhatsApp session and the
  daemon ran with stale prefs (loaded before you toggled
  notifications), so the watchdog killed it right after closing the
  app ("daemon off despite enable"). The open GUI finds the daemon
  again through its port rescan
- The daemon watchdog reloads prefs from disk before deciding to
  exit, so a notifications toggle written by another backend instance
  is always respected
- setPref no longer loses writes silently: one delayed retry (backend
  may still be starting), then a visible error notice

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.51-1
- Daemon command rows now show the full systemctl command: the labels
  wrap across lines (smaller monospace, row height adapts) instead of
  truncating - what you tap is exactly what gets copied

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.50-1
- Daemon control reworked for the sandbox reality: Sailjail denies
  systemctl (errno 13), so the settings now show a live status line
  ("Background daemon: running/not running", reported by the backend
  itself via WA_DAEMON=1 from the unit) plus tap-to-copy enable and
  disable commands for the Terminal. The notifications rule is now
  enforced by the daemon itself: running without notifications
  enabled and without an attached GUI, it exits cleanly (silent
  zombies quit on their own; Restart=on-failure leaves clean exits
  alone)

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.49-1
- Notifications, two explicit stages: stage 1 notifies about incoming
  messages while the app runs in the background (Lipstick
  notifications via D-Bus, per-chat deduplication with a counter,
  muted chats stay silent, opening the chat clears them, nothing
  fires while the app is in the foreground - the GUI reports its
  state and missing polls mean the app is gone); stage 2 ("also when
  the app is closed") is the background daemon and can only be
  enabled when notifications are on - switching notifications off
  also disables the daemon. Both default to off

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.48-1
- Daemon toggle now hands over cleanly in both directions: enabling
  first stops the app-owned child backend (two backends with the same
  credentials would make WhatsApp kick one connection) and waits for
  the daemon to hold the port; disabling stops the daemon and
  immediately respawns a child backend so the open app is never left
  without one. The GUI keeps running on the same port either way

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.47-1
- Backend lifetime hardened: the backend now receives SIGTERM from
  the kernel (PR_SET_PDEATHSIG) whenever the app process dies - even
  on a crash or OOM kill, where the QML destruction handler never
  runs. No more orphaned connections between a hard app death and
  the next launch
- Opt-in background daemon (Whisperfish pattern): a systemd user
  unit starts the backend via sailjail with the app's own sandbox
  identity - required so the daemon may open the sailfish-secrets
  collection holding the store key. Toggle in Settings (with
  Terminal command fallback in case systemctl is blocked inside the
  sandbox); default remains off - the app stays silent once closed
  unless you explicitly opt in

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.46-1
- Mark all as read (requested on OpenRepos): pulley menu entry on the
  chat list clears all unread counters at once (backend endpoint
  /chats/read-all sets the last-opened marker for every chat)
- Event screen notifications (requested on OpenRepos), optional and
  OFF by default: when enabled in Settings, a chat whose unread count
  rises while the app is in the background publishes a notification
  (sender name, message preview, count) via Nemo.Notifications. Muted
  chats stay silent. Works while the app is running, also minimised
  as a cover; no notifications when the app is closed completely

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.45-1
- Live location update throttle relaxed to 45 seconds (or 75 meters
  of movement, whichever comes first)

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.44-1
- Live location sharing no longer floods the chat with hundreds of
  messages: the 20-second GPS tick sent a full new message per fix
  (~500 over a few hours), and recipients' official clients showed
  each one instead of collapsing them into the live bubble. Two-part
  fix: updates are aligned with what official senders emit
  (SequenceNumber as unix millis instead of 1,2,3..., TimeOffset in
  seconds since the share started, no empty caption) to give
  receiving clients their collapse key, and updates are throttled to
  every 90 seconds OR 75 meters of movement, whichever comes first
  (📍 log line per sent update). Your own bubble still refreshes on
  every GPS fix

* Thu Jul 16 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.43-1
- Group messages no longer leak into 1:1 chats: the per-chat message
  filter also matched on sender, so a person's group posts appeared
  in their direct chat as well. The sender match is now restricted to
  its intended purpose - legacy messages without a chat jid

* Wed Jul 15 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.42-1
- Tapping another person's (ended) live location no longer does
  nothing: WhatsApp often sends a final live-location packet without
  real coordinates when sharing ends, which overwrote the last known
  position with 0/0 - geo:0,0 then failed silently in maps apps.
  Zero-coordinate updates are now consumed without touching the
  bubble (it freezes at the last real position), and tapping a
  bubble that has no coordinates shows an explanatory notice instead
  of failing silently

* Wed Jul 15 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.41-1
- Unread indication (requested on OpenRepos): chats with new messages
  show a highlighted bold name and an unread-count badge next to the
  time. A per-chat last-opened marker (persisted in chat settings)
  counts incoming messages newer than your last visit; opening a chat
  or receiving messages while it is open clears it. Reading a chat on
  the PHONE clears it too: WhatsApp distributes read receipts to all
  devices (read-self, or read from the own jid when read receipts are
  enabled) and the marker follows (📖 log line). Read receipts are
  only RECEIVED - the app still never sends blue ticks

* Wed Jul 15 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.40-1
- The bottom pushup menu in chats now mirrors the complete top pulley
  menu (all entries incl. visibility conditions) instead of a
  three-item selection - every chat action is reachable from the
  bottom where you already are

* Wed Jul 15 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.39-1
- Chat scrolling no longer fights the poll timer: the 2-second poll
  reassigned the whole message model even when nothing changed,
  rebuilding the view and jumping to the end - with live location
  updates this made reaching the top (pulley menu) impossible.
  Unchanged responses are now skipped entirely, and on real changes
  the reading position is preserved unless you were already at the
  bottom
- Live location can be stopped from the chat overview (long-press the
  chat) and from a new bottom pushup menu inside the chat - no need
  to scroll to the top anymore. The pushup menu also carries Search
  in chat and Group info as reachable shortcuts

* Wed Jul 15 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.38-1
- Pairing failures now tell you WHY: the PairError event (fired when
  the phone accepts the code but the handshake fails afterwards -
  the phone only shows "there was an error") was silently discarded.
  The reason is now shown on the pairing screen and logged
  (❌ PairError line), covering the classic causes: outdated app
  version rejected by WhatsApp, device clock skew, device limit

* Wed Jul 15 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.37-1
- Auto-download display made deterministic: the policy ComboBoxes are
  only instantiated AFTER the prefs have loaded (small spinner in the
  meantime), so they initialize directly with the stored values -
  independent of Silica ComboBox binding/menu timing that kept the
  display stuck on defaults while the backend value was correct

* Wed Jul 15 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.36-1
- Auto-download settings DISPLAY fixed (the backend value was already
  correct and persisted since 0.9.35): Silica's ComboBox assigns
  currentIndex imperatively during menu setup, destroying the
  declarative binding before the async prefs fetch returns - the
  boxes then showed the default ("Wi-Fi only") forever regardless of
  the stored value. The index is now synchronized imperatively
  whenever the prefs arrive or change

* Wed Jul 15 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.35-1
- The real auto-download reset bug, caught in the act: opening the
  settings page OVERWROTE saved policies with the defaults. The
  ComboBox change handler fires already during initialization (index
  jumps to the default) while the async /prefs fetch is still
  running, compared against the still-empty map, saw a "change" and
  wrote the default to the backend - deterministically on every page
  visit ("Documents: Always" became "Wi-Fi only" even within one
  session). Writes are now blocked until the prefs are actually
  loaded; re-set your preferred values once after updating

* Wed Jul 15 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.34-1
- In-app audio player: voice messages and audio files play inside the
  app (play/pause, seek slider, position display) - completing the
  media trio after images (0.9.24) and videos (0.9.32). External
  players cannot read the app's private data directory under
  Sailjail, so no media permission is needed anymore for any
  received media type

* Wed Jul 15 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.33-1
- Auto-download settings no longer appear reset after an update or
  restart: /prefs answered with an empty map before the stores were
  loaded, making the settings page fall back to defaults ("Wi-Fi
  only"), and worse, /prefs/set could overwrite prefs.enc with a
  single-entry map in that window, actually losing settings. Both
  endpoints now answer 503 while starting and the UI retries shortly
- Channel audio "invalid media hmac" fixed: the server re-hosts
  newsletter media UNENCRYPTED while the message proto still carries
  the author's mediaKey, so normal decryption fails HMAC validation.
  On that error the download retries as a plaintext newsletter fetch
  over the direct path (mms-type newsletter-*) - applies to audio,
  video and documents in channels alike

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.32-1
- In-app video player (QtMultimedia): videos play inside the app -
  fullscreen, tap for play/pause, seek slider, position display. The
  Gallery cannot read the app's private data directory under Sailjail
  (users saw "0 bytes"), and unlike before no media permission is
  needed to watch. All six media-open sites route videos to the
  player; other file types still open externally
- Pinned chats survive restarts reliably: the pin/mute/archive
  handler mutated local state, then bailed out before saving when the
  WhatsApp app-state sync failed (typical shortly after a fresh
  pairing) - the UI showed the pin from memory and lost it on
  restart. Local state is now persisted synchronously first; a failed
  server sync is logged and reported but no longer discards the pin
* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.31-1
- Group photo actually works: WhatsApp's server only accepts square
  baseline JPEGs up to ~640x640 and answered full-size uploads with
  not-acceptable ("the given data is not a valid image" via
  whatsmeow). Photos are now center-cropped to a square and scaled
  to 640x640 (pure-Go bilinear, no new dependency) before upload;
  the handler finally logs decode/upload results (🖼️ lines)

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.30-1
- Admin changes (promote/demote), rename, description, photo and
  leave now show up immediately: all mutating group endpoints
  invalidate the group-info cache, so the reload after the action
  fetches fresh data instead of the cached copy (cache moved to
  package level so every handler can invalidate it)
- Group photo selection reports errors instead of failing silently:
  the picker XHR had no response handler. The most common failure is
  Sailjail denying the backend read access to ~/Pictures without the
  media storage permission - the error message now says so

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.29-1
- REAL online channel search: the search doc_id (26301059626252132)
  and its exact typed variable schema were found in the published
  WhatsApp Web Mex bindings (@vinikjkkj/wa-mex on npm) - no DevTools
  digging needed after all. Search now queries the directory
  server-side with {input:{search_text, categories, limit,
  start_cursor}}; pagination cursors work for search results too.
  The .dir-search-docid override file remains supported in case the
  ID ever rotates; local recommendation filtering stays as fallback

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.28-1
- Channel search restructured on hard evidence: all 8 input shapes on
  the list doc_id return clean 400s, proving directory SEARCH is a
  separate persisted GraphQL query. Searching no longer wastes a
  request cascade - it goes straight to the locally filtered
  recommendations (single request). The real search doc_id can be
  retrofitted WITHOUT a rebuild: extract it from the WhatsApp Web JS
  bundle (DevTools > Sources > search "NewsletterDirectorySearch")
  and write it to .dir-search-docid in the app data dir - the backend
  then performs true online search with the wa-js parameter shape

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.27-1
- Directory rate-limit protection (a 429 today was self-inflicted by
  the variant cascade): a rate-limit response aborts the cascade
  immediately instead of burning the remaining variants, the first
  accepted variant is remembered and used exclusively afterwards,
  infinite scroll auto-loads at most every 3 seconds, and the UI
  shows a friendly "wait a minute" message on 429

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.26-1
- Online channel search, next attempt with researched field names:
  wa-js documents the web client's directory search job
  (WAWebMexFetchNewsletterDirectorySearchResultsJob) taking
  searchText, categories, limit and cursorToken - and the documented
  "view" variable strongly suggests the same persisted query serves
  both RECOMMENDED and SEARCH. Three new SEARCH input shapes with
  categories/cursor_token are tried first; the local-filter fallback
  remains if all are rejected

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.25-1
- Channel search fallback fixed: it used one hardcoded input shape
  for the recommendations fetch, which the server can reject just
  like the search shapes - the fallback now walks the same variant
  cascade that makes the list work, then filters locally
- Loading beyond 50 channels actually works now: infinite scroll at
  the list end plus a visible "Load more" footer; when the response
  carries no pagination cursor the request is repeated with a larger
  limit instead (backend cap raised to 500); a spinner shows while
  loading and the footer disappears once no new entries arrive

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.24-1
- Channel directory pagination: responses carry an end_cursor, which
  is now parsed (defensively, incl. has_next_page) and exposed as a
  "Load more" button - browse beyond the first 50 recommendations
- Images open in the app's own fullscreen viewer instead of the
  external Gallery: downloads live in the app's private data dir,
  which other sandboxed apps (Gallery) cannot read - external open
  showed nothing, especially with media permission revoked. Videos
  and documents still open externally

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.23-1
- Channel search: WhatsApp's directory SEARCH uses a separate
  persisted GraphQL query whose ID is not public (whatsmeow and
  Baileys only know the recommendations list). Until that ID
  surfaces, search falls back to fetching up to 50 recommendations
  and filtering them locally by name/description, clearly labelled
  in the UI as "showing matches from recommendations"

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.22-1
- Channel directory: the GraphQL endpoint answers incomplete variables
  with a bare 400, so the request now walks a cascade of plausible
  input shapes (start_cursor, filters, search field naming), logging
  each rejection and using the first accepted form - backend.log
  documents which variant the server takes

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.21-1
- Channel discovery: new "Discover channels" page (pulley on the
  Channels page) with recommendations on open and full-text search
  via WhatsApp's channel directory (same GraphQL interface the
  official clients use); results show name, description, follower
  count and verification badge, long-press to follow. /channel/follow
  accepts a jid directly and imports the last 50 channel posts

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.20-1
- Status updates after a fresh pairing: WhatsApp only delivers status
  broadcasts to devices that announced available presence, and sending
  presence requires the push name, which arrives only via app state
  sync some time after pairing. The old code gave up with a warning;
  now it waits up to 2 minutes for the push name and announces
  presence as soon as it is there, plus reacts to the push-name event
  directly. Note: statuses are push-only - anything posted while
  presence was missing will never arrive retroactively

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.19-1
- Big-group performance, the real fix: contact name resolution did a
  full linear scan over the entire device address book (with an inner
  loop over every phone number) on EVERY delegate evaluation - in an
  80-member group every visible message paid that price on each
  scroll. The address book is now distilled once into O(1) lookup
  maps (canonical JID + 9-digit suffix for the country-code
  heuristic), rebuilt debounced when the PeopleModel changes
- Group info answers instantly from a backend cache; the WhatsApp
  server roundtrip refreshes it in the background (Go doing the heavy
  lifting instead of QML JavaScript)

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.18-1
- Group info rebuilt the Fernschreiber way: the page is now a
  virtualized SilicaListView (info sections as list header, one
  delegate per participant) instead of a Flickable+Repeater that
  instantiated every row up front. Only the ~10 visible rows exist at
  any time, so opening the info of an 80-member group is instant and
  scales to any size; the 0.9.17 "show first 30" workaround is gone.
  A busy indicator would still be nice while the server roundtrip
  runs - the seconds until data arrives are network, not UI

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.17-1
- Secrets robustness hardened against a dangerous edge: a key READ
  failing for reasons other than "does not exist" (missed confirmation
  prompt, locked collection, daemon trouble) previously made that
  collection eligible as a store target - a freshly generated key
  could have OVERWRITTEN the real one. Only genuinely empty
  collections (error codes 40/41/43) qualify now; any other read
  error halts with "Restart backend", which re-triggers the prompt
- Group info no longer freezes on large groups (~80 members caused
  the OS "not responding" banner): participant context menus are
  instantiated lazily on long-press instead of eagerly at page build,
  and only the first 30 rows render immediately with a "Show all"
  button for the rest

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.16-1
- Key handover no longer touches the filesystem: the owning identity
  stores the key directly into a NoAccessControl Secrets collection
  which the app identity then loads normally - the key never exists
  in plaintext on disk. Legacy handover files from 0.9.12-0.9.15 are
  still adopted once and deleted
- "Load history from phone" works without an anchor message: after
  data loss the request uses a fabricated cursor at the current time,
  so history can be recovered chat by chat without having to send a
  message into every chat first

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.15-1
- CRITICAL: a backend that halted before loading its stores (Secrets
  halt) saved empty state over the real files on /quit, wiping
  messages.enc and rawmedia.enc. All save functions are now guarded
  by a stores-loaded flag - a halted backend can never overwrite data
  again
- Recover lost history: new chat menu entry "Load history from phone"
  (on-demand history sync); the phone re-sends up to 100 older
  messages per request, repeat to page further back. Requires one
  anchor message in the chat
- Leftover key handover files (plaintext key!) and stale handover
  markers are removed automatically after a successful normal key load

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.14-1
- Fix the 0.9.13 collection search stopping at the first empty fixed
  candidate ("not found" broke the loop), so the scanned dynamic
  hwapp* collection holding the key was never reached. The search now
  visits every candidate and only remembers the first ownable name as
  the store target for fresh keys. Note after updating: tap "Restart
  backend" once (or fully close the app) so the running halted backend
  is actually replaced by the new version

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.13-1
- Fix ownership error returning right after a successful re-pair: the
  key was stored under a dynamically generated collection name, but
  the lookup only searched the fixed candidates - the name was never
  persisted. The chosen collection name is now remembered in a state
  file AND the plugin's existing collections are scanned for our
  naming patterns, so an existing key is always found again. Existing
  installations recover automatically, no further re-pairing
- Settings: Location permission status is now shown next to Contacts
  and Media; permission command rows wrap instead of overflowing the
  line

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.12-1
- Icon-only escape from Secrets identity conflicts, no terminal and no
  reboot: the error screen offers "Re-pair (keeps message history)".
  Messages, contacts and media live in the app's own stores, NOT in
  wa.db - a session reset only costs re-entering a pairing code. The
  UI says so explicitly; /reset is allowed in secrets_error state
- Collection names can never be exhausted: if every fixed candidate is
  owned by foreign identities, a dynamic alphanumeric name is used
- The key handover via a one-time start under the owning identity
  remains available for those who prefer zero re-pairing

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.11-1
- Startup self-test now lists the existing Secrets collections in the
  plugin (collectionNames, as Storeman does via CollectionNamesRequest)
  so ownership/legacy situations are visible in backend.log before any
  access fails. Review of Storeman's approach confirmed the design:
  it uses OwnerOnlyMode with silent failure, affordable because its
  secret is a re-obtainable login token; ours guards the message
  database, hence explicit recovery states and the key handover

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.10-1
- Secrets identity conflicts are now fully recoverable WITHOUT
  re-pairing: if the key collection is owned by a different Sailjail
  identity (e.g. it was created by a Terminal-started instance), the
  app requests a key handover - start it once the way it last worked,
  that instance exports the key to a private file, the next normal
  start adopts the same key into its own collection and deletes the
  file. Same database, same messages, no reset
- New collections are created with NoAccessControlMode (still guarded
  by the sandbox Secrets permission and the device lock) so identity
  differences can never lock the app out of its own key again;
  inspired by reviewing how Storeman handles collections (it uses
  OwnerOnlyMode and would hit the same trap)
- Collection name falls back to alternatives if a foreign-owned one
  blocks the default name

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.9-1
- Secrets ownership conflicts (errorCode 10, "owned by a different
  application") are now recognized as what they are: the app running
  under a different Sailjail identity, e.g. started from a Terminal
  instead of the app icon. No data is lost in this state, so instead
  of retry loops or destructive workarounds the app halts with plain
  instructions: close the app completely and start it from the app
  grid - key and messages load again. No reset, no re-pairing, no
  terminal needed. Error wrapping switched to %w so the daemon error
  codes survive for typed detection

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.8-1
- Fix "Restart backend" / retry / reset leaving the UI in "Starting
  backend" forever: retryBackend() called the pyotherside call()
  method unqualified from the window root, which silently throws a
  ReferenceError - no backend was ever started. Now correctly invoked
  on the Python element. This dead branch dated back to 0.8.5 and
  affected every automatic backend restart path

* Tue Jul 14 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.7-1
- Escape hatch for a dismissed Sailfish Secrets confirmation prompt:
  the backend halts in secrets_error, but since it outlives the app,
  reopening found the same halted backend forever. /quit is now
  registered early (works in halt states) and the error screen offers
  a "Restart backend" button - tap it, accept the Secrets prompt this
  time, done. Explanations mention the prompt explicitly

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
