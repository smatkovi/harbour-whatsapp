Name:       harbour-whatsapp
Version:    0.9.255
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
# Fuenf QML-Module werden importiert, aber nur drei Pakete waren genannt.
# Dass es ueberall lief, hiess nur, dass die uebrigen zufaellig
# mitinstalliert waren - fehlt eines, laedt die QML-Datei nicht und die App
# startet ueberhaupt nicht. Paketnamen auf einem laufenden Geraet mit
# "rpm -qf" ermittelt, nicht geraten.
Requires:   libkeepalive
Requires:   nemo-qml-plugin-dbus-qt5
Requires:   nemo-qml-plugin-notifications-qt5
Requires:   sailfish-components-pickers-qt5
# Stellt /usr/bin/sailfish-qml bereit, also genau das Programm aus unserer
# Exec-Zeile. Auf offiziell unterstuetzten Geraeten ist es immer vorhanden,
# weil zahllose Apps es mitziehen - auf einem frisch geflashten
# Community-Port nicht zwingend. Fehlt es, gibt es kein Programm, das
# starten koennte, und die App reagiert auf das Antippen mit gar nichts.
Requires:   libsailfishapp-launcher
# Voice-Aufnahme: der Rekorder wird bei der Installation an einen
# exec-erlaubten Ort gebuendelt - ohne dieses Paket lief %post ins Leere
# und die Aufnahme scheiterte mit einem irrefuehrenden Errno 13.
# Nur aarch64 als harte Abhaengigkeit: auf aelteren armv7hl/i486-Geraeten
# (XA2-Feldbericht: "Error during install") kann das Paket in den Repos
# fehlen und wuerde die GESAMTE Installation blockieren - dort greift
# stattdessen die Laufzeit-Kette mit ihrer praezisen Install-Anweisung
%ifarch aarch64
Requires:   gstreamer1.0-tools
%endif
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
echo %{version} > %{buildroot}/usr/share/harbour-whatsapp/VERSION
install -m 644 %{_sourcedir}/harbour-whatsapp-daemon.desktop %{buildroot}/usr/share/applications/
# Versionsstempel fuer den Daemon-Selbst-Update-Poller: /usr/share/
# harbour-whatsapp ist im Daemon-Jail UNSICHTBAR (sailjail leitet die
# Whitelist vom Desktop-DATEINAMEN ab -> nur *-daemon-Pfade), aber das
# Daemon-Desktop-File selbst steht woertlich in der Whitelist
sed -i "/^NoDisplay=true/a X-Whatsapp-Version=%{version}" %{buildroot}/usr/share/applications/harbour-whatsapp-daemon.desktop
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
/usr/share/harbour-whatsapp/VERSION
/usr/bin/harbour-whatsapp-daemon

%post
# Desktop-File-Migration: harbour-whatsapp.desktop ist %config(noreplace),
# damit Nutzer-Grants (Microphone etc.) Updates ueberleben - neue Pflicht-
# Schluessel muessen daher idempotent nachgeruestet werden, sonst fehlt
# dem Jail die dbus-Erlaubnis (Reply) bzw. die Aktivierung (Tap-Kaltstart)
D=/usr/share/applications/harbour-whatsapp.desktop
# X-Maemo-Service im HAUPT-Desktop lenkt den Icon-Start auf einen
# D-Bus-Ruf um und macht die App vom Launcher aus unstartbar (0.9.90-
# Lehrstueck) - die Zeile gehoert nur ins Daemon-Desktop-File
sed -i '/^X-Maemo-Service=/d' $D
# ExecDBus OHNE sailjail-Wrapper: sailjaild wickelt die Zeile in
# invoker, und der Silica-Booster laedt sein Ziel per dlopen -
# sailjail ist nicht boostbar ("cannot dynamically load executable",
# der Grund, warum der Kaltstart-Tap nie funktionierte). Sandboxing
# kommt ueber die Launcher-Integration, wie beim Icon-Start
sed -i '/^ExecDBus=/d' $D
printf 'ExecDBus=/usr/bin/sailfish-qml harbour-whatsapp\n' >> $D

# Nutzer-Grants auf das Daemon-Profil spiegeln: das Haupt-Desktop-File ist
# %config(noreplace) und traegt die per Einstellungs-Befehl erteilten Rechte,
# das Daemon-File wird bei jedem Update ersetzt. Ohne Spiegelung darf die App
# Dateien auswaehlen, das Backend im Daemon-Jail sie aber nicht lesen -
# Senden von Bildern/Videos passiert dann stillschweigend nie
DD=/usr/share/applications/harbour-whatsapp-daemon.desktop
P=$(sed -n 's/^Permissions=//p' $D | head -1)
if [ -n "$P" ] && [ -f $DD ]; then
  sed -i "s|^Permissions=.*|Permissions=$P|" $DD
fi

# gst-launch am exec-erlaubten Ort verfuegbar machen (Voice-Aufnahme):
# /usr/bin kann im Sailjail auf eine Positivliste reduziert sein
ln -f /usr/bin/gst-launch-1.0 /usr/share/harbour-whatsapp/gst-launch-1.0 2>/dev/null ||   cp /usr/bin/gst-launch-1.0 /usr/share/harbour-whatsapp/gst-launch-1.0 2>/dev/null || true
ln -f /usr/bin/pactl /usr/share/harbour-whatsapp/pactl 2>/dev/null ||   cp /usr/bin/pactl /usr/share/harbour-whatsapp/pactl 2>/dev/null || true

# systemd von der neuen Unit-Datei in Kenntnis setzen. Ohne das lief der
# alte Daemon nach dem Update gegen eine im Speicher veraltete Definition -
# genau die Warnung "unit file changed on disk" - und das absichtliche
# Exit-1-Selbstupdate fand keinen Weg zurueck. try-restart beruehrt nur
# einen LAUFENDEN Dienst, wer ihn nie eingeschaltet hat bleibt unbehelligt.
if [ -x /usr/bin/systemctl-user ]; then
  /usr/bin/systemctl-user daemon-reload || true
  /usr/bin/systemctl-user try-restart harbour-whatsapp-daemon.service || true
fi

%postun
if [ "$1" = "0" ]; then
  rm -f /usr/share/harbour-whatsapp/gst-launch-1.0 /usr/share/harbour-whatsapp/pactl
fi

%changelog
* Thu Aug 13 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.255-1
- Presence for the chat you have open, which is kempertom's wish narrowed to
  what can be done safely. WhatsApp sends nothing about anyone unless
  subscribed to individually, so a page listing who is online would mean one
  request per contact - 808 of them here - and a burst of identical requests
  across a contact list is precisely the pattern that has already cost this
  account two restrictions. Instead one subscription happens when a chat is
  opened, and again when a chat is newly started, so it is one request per
  deliberate act. The header then shows online, or when the person was last
  seen. Reopening the same chat inside ten minutes does not ask again.
  Groups and channels are skipped since they have no presence, and nothing
  is asked at all while "do not appear online" is on - WhatsApp would send
  nothing back, so the request would be pure noise. Eight test cases, under
  the race detector, since the event handler writes what the endpoint reads

* Thu Aug 13 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.254-1
- Notifications now clear when you reply from them. Replying called
  /chat/opened with a "jid" parameter while the endpoint reads "chat", so
  every one of those calls came back 400 and the notification stayed put -
  rdomschk noticed it after renaming the app, but it was never about the
  renaming. Both names are accepted now. The daemon's notifications also
  carry the configured app name instead of a hardcoded WhatsApp, which is
  what put two different senders in the events view once the app was
  renamed. Five test cases.
- The status page can list people instead of posts, optional and off by
  default: one row per person with a count and the time of their latest
  post, tapping opens what they posted. Built from the entries already
  loaded, so it costs no extra requests - which matters, given what extra
  requests have cost this account lately. Six test cases.
- The chat header fades out towards the list rather than ending in a line.
  A true blur would need a shader over the ambience image, which an app
  cannot reach; a gradient serves the same purpose - carrying the text at
  the top, dissolving into the messages below

* Thu Aug 13 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.253-1
- Not appearing online is now the default. The app used to announce itself
  as available on every connect, which is what made the device show as
  online to everyone. It no longer does unless asked to. There is a cost,
  and it is not small: WhatsApp only delivers status broadcasts to devices
  that announce themselves, so the status page will be empty until the
  setting is turned off. It therefore says so in as many words rather than
  looking broken, and names the setting to change

* Thu Aug 13 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.252-1
- A setting not to appear online. The app announces itself as available on
  every connect, and has to: WhatsApp only delivers status broadcasts to
  devices that do. Turning this on skips that announcement, so nobody sees
  the device online - and no status updates arrive either. That trade is
  stated in the setting itself rather than buried, because finding out by
  wondering where the statuses went would be worse. Off by default, since
  that is what the app has always done, and only the exact value counts so a
  stray entry cannot quietly hide you. Four test cases, one of them under
  the race detector, as the preference is read from the connect handler
  while the settings page writes it

* Thu Aug 13 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.251-1
- Status updates from individual people can be hidden - kempertom has an
  acquaintance who posts a small photo album daily and buries everyone else,
  and rdomschk put the same wish at the top of his list. Long press an entry
  to hide that person, and the status pulley has a page listing everyone,
  which also serves as the way back: someone who has stopped posting would
  otherwise be impossible to unhide. Hidden means hidden here only, not
  unsubscribed - WhatsApp sees no change, and nothing is done that cannot be
  undone. Your own posts are never filtered. Nine test cases. The status
  delegate had to become a ListItem to carry a context menu at all; it is
  built like the channel directory's, which demonstrably works, and the
  Column inside it is untouched.
- Zoomed pictures stay centred. The previous version scaled the image while
  PinchArea also dragged it, and that displacement remained afterwards, so
  the picture sat low and off-centre once zoomed back out. The image itself
  now grows and the flickable pans it, which is what a flickable is for

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.250-1
- Takes the run-now buttons out again: the sandbox forbids it. pkexec,
  polkitd and the Sailfish polkit agent are all present and running, but the
  call from inside the app fails with PermissionError(13) - shown on the
  device, not guessed. rdomschk's example comes from a Patchmanager patch,
  and patches run outside Sailjail, which is the difference. Routing it
  through the daemon would not help either, since the daemon is itself
  started under sailjail - that is what lets it reach the secrets
  collection. So the commands stay copyable and the reasoning is recorded in
  the source, to save the next person from trying it again

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.249-1
- The run-now buttons report back where the finger is. They were writing
  into a hint label sitting hundreds of pixels further down the page, so
  tapping one appeared to do nothing at all; the row itself now says
  "waiting for the password", then whether it worked. And the call goes
  through a Python helper that catches its own exceptions: calling
  subprocess directly meant that if the command could not be started, no
  callback ever arrived and the interface simply sat there - the very
  silence that was reported. pkexec, polkitd and the Sailfish polkit agent
  are all present on the device, so the mechanism itself is sound

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.248-1
- Every permission command gets a second, indented row beneath it that runs
  the command straight away, polkit asking for the password or fingerprint
  itself. The copy row stays exactly where it was: anyone who would rather
  read what is about to run than trust a button can still do that, and a
  test now asserts that all ten buttons execute character-for-character what
  the row above them copies - if the two ever drift apart, the build fails.
  Commands are passed as argument lists, never through a shell, and a test
  asserts that too. On failure the hint points back at the command above

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.247-1
- Renaming the launcher icon can now be done from the app, using the pkexec
  approach rdomschk sent over - polkit asks for the password or fingerprint
  itself, so no Terminal is needed. Both ways are offered: the command to
  copy stays above, for anyone who would rather read what is about to run
  than trust a button, and the button sits below it. The command is passed
  as a list of arguments with no shell involved, so a stray character in the
  name cannot append a second command; a slash would still break the sed
  expression, so the name is checked first. Sixteen test cases, including
  that a name of "a;rm -rf /" is refused. If pkexec is unavailable or the
  sandbox forbids it, the button says so and points at the command above.
- The chat header is translucent again at 0.25, so the ambience shows
  through as rdomschk prefers. That was only safe once 0.9.246 stopped the
  messages running underneath it

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.246-1
- Messages no longer show through the chat header. The list only allowed for
  the header's height when a message was pinned, and otherwise started at
  the very top of the page, running underneath it - barely noticeable while
  the header was transparent, but with the tinted backing and the avatar the
  text and the name visibly overlap, as rdomschk's screenshot showed. The
  header is now always accounted for, and carries a z of 10 in case anything
  else reaches past its bounds - the same fix the bottom bar needed today

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.245-1
- The rename command gets a copy button after all, built exactly like the
  permission ones - and the difference turns out to have been the thing all
  nine previous attempts had in common: a visibility condition. Those
  buttons have none, mine always did, and whenever the condition came out
  false or undefined the row vanished, collapsed to no height, or drew
  without taking a tap. The condition is gone; the name is read straight
  from the field when the button is pressed, falling back to WhatsSail if
  it is empty. The caption stays put and the command goes to the clipboard,
  as it does for the permissions

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.244-1
- Drops the copy button for the rename command and puts the command itself
  into the setting's description, where it appears as soon as a name is
  entered and updates as it is typed. Nine attempts at that button - as a
  BackgroundItem, as a Label with a MouseArea, moved elsewhere on the page,
  with a derived height and then a fixed one - left it variously invisible,
  overlapping its neighbours, or simply unresponsive, while the same
  construction works for the permission commands further down. Plain text
  renders reliably and can be selected, and the app cannot rename the
  launcher icon itself in any case, since that file is read before it starts
  and only root may write it

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.243-1
- Gives the rename row a fixed height instead of deriving it from the label
  inside, which came out at nothing in this column and let the neighbouring
  entries overlap it. A single-line entry needs no arithmetic

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.242-1
- Moves the rename button to the end of the settings page, away from the
  name field. Sitting directly beneath it, the row was drawn but would not
  take a tap - Silica's TextField brings its own touch area that reaches
  past what it appears to occupy, the same shape of fault as the bottom bar
  earlier today, where the list swallowed the taps meant for the strip. The
  button is one of the last entries on the page now, still tied to the name
  entered above

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.241-1
- Found it: the two properties the rename command depends on were declared
  after the column's children instead of at its start, and the binding to
  the text field simply never took - which QML does not report, an empty
  string being no error. renameSafe was therefore always false, the button
  never rendered, and six versions of rebuilding the button were aimed at
  the wrong thing entirely. The clipboard was never at fault; the
  permission command copies perfectly on the same device, which is what
  settled it. The properties now sit where properties belong

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.240-1
- Separates the two things that could be failing about the rename command.
  Tapping it now prints the command it built and, in brackets, what reading
  the clipboard back gives. If the brackets are empty the write is failing;
  if they hold something else the string is at fault; and if the command
  itself is missing it was never assembled. Either way the command is on
  screen and can be copied by hand, so this is useful as well as diagnostic

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.239-1
- The rename command is built the way the permission commands further down
  are built, which was the right question to ask: why does it work there.
  Because those never display the command at all. They show a short caption,
  put the long string into the clipboard, and report back through a label of
  their own. Four attempts went into rendering the command itself, which
  stayed blank each time without the QML engine saying a word - so this
  stops trying and copies the pattern that demonstrably works. The temporary
  diagnostic line is gone with it

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.238-1
- Makes the rename command observable instead of guessing at it a fourth
  time. Two constructions in a row rendered nothing while the QML engine
  reported no error whatsoever, and after the last attempt the row vanished
  entirely - which points at the visibility test rather than the layout. A
  temporary line under the name field now prints what is actually in the
  field, in the derived name, in the saved setting and in the safety check.
  The command itself appears as soon as any name other than WhatsApp is
  there, and if that name cannot go into a sed expression it says so rather
  than disappearing without trace - silent absence is what made this take
  four rounds. The diagnostic line comes out again once the cause is known

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.237-1
- Another go at showing the rename command, this time built the way the
  hint below it is built - a plain Label in the column with a MouseArea for
  the copying - since that one demonstrably renders. The BackgroundItem
  version stayed blank even after being given a width, and the QML engine
  reported nothing at all about it, so rather than keep guessing at a
  construction that produces no diagnostics, this drops the construction

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.236-1
- The rename command is actually legible. The tappable area was there but
  empty: a BackgroundItem inside a Column gets no width of its own, so the
  label inside it came out at minus twice the margin and had no room for
  anything. The same omission was sitting on the three terminal commands for
  the background service, where it evidently did no harm - but relying on
  that is luck rather than intent, so all four now state their width. The
  label also no longer centres itself against a height that is derived from
  its own, which was a binding loop waiting to matter

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.235-1
- The rename command appears while you type rather than after leaving the
  field. It was keyed to the saved setting, which is only written when the
  text field loses focus - so having typed a name one saw nothing and had to
  tap elsewhere first to find out the command existed. It follows the field
  contents now

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.234-1
- Lines instead of bubbles, as an optional view under More settings.
  Suggested by kempertom after Element's bubble-free mode. Messages fill the
  width in alternating tints - own ones lighter, others darker - since
  without a side to sit on, the colour has to carry what the alignment used
  to say. For the same reason the sender's name is shown in front of every
  message, including in one-to-one chats and on your own, which read simply
  "Me": the name would say nothing there. Reactions, timestamps and ticks
  keep their places, and the text no longer draws a panel of its own, which
  would only have been a box inside a box - the very bubbles being done away
  with. Off by default and off is exactly as before, so it can be tried
  without risk

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.233-1
- The chat partner's name reads properly now: the backing behind the header
  went from 0.12 to 0.6 opacity, so the text sits on a settled ground rather
  than on the ambience showing through. Avatars beside status entries are
  medium rather than small. And the header no longer falls back to the phone
  number while the profile is still loading - it stays empty for that
  moment, since flashing the number briefly is exactly what replacing it was
  meant to avoid

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.232-1
- Renaming the launcher icon too, without editing files by hand. Setting a
  name in More settings now also offers a tappable command that copies to
  the clipboard and renames the icon. That name lives in the desktop file,
  which is read before the app starts and only root may change, so the app
  cannot do it itself. It does survive updates, though, and this was worth
  checking rather than assuming: the file is config(noreplace) and the
  %%post script only ever touches X-Maemo-Service, ExecDBus and the
  permissions line - never Name. The command only appears for names made of
  letters, digits, spaces, dots, hyphens and underscores: the name goes
  into a sed expression, where a slash or an apostrophe would break it
  apart, and in the worse case run something else entirely

* Tue Aug 11 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.231-1
- whatsmeow updated to 2026-08-10 (a23afe31) with proto v1044834443. No
  dependency changes and no API breakage this time.
- The header shows your own name instead of your phone number, as rdomschk
  put it: anyone you hand the phone to can read a number off the screen,
  and the name says the same thing without giving it away. Falls back to
  the number until the profile has loaded.
- The app name is a setting rather than something to patch by hand. He had
  been editing the QML himself so the notification count in the switcher
  would not collide with the official WhatsApp app - which every update
  overwrote. It now applies to the header and to notifications; the name
  under the launcher icon still needs the desktop file, since that is read
  before the app starts.
- Avatars where they help: beside every status entry, not just the first of
  a group - with ten pictures from one person you otherwise cannot see who
  posted them without scrolling back - and beside the chat partner's name
  in the chat header, which also got the same faintly tinted background as
  the bottom bar, because the transparency made it hard to read

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.230-1
- whatsmeow updated to 2026-08-06 (e277b766), ten commits on from the
  previous build, among them proto v1044440921. Protocol updates are the
  ones that eventually stop being optional: a client speaking an outdated
  protocol looks like a broken one to the server, which is what draws
  account restrictions. Dependencies were unchanged, but the API was not -
  SetStatusMessage now takes a types.SetStatusInput rather than a string,
  the server having gained emoji and expiry for the About text. Only the
  text is set, through a pointer, so that clearing it stays distinguishable
  from leaving it alone. go vet caught it before the build did

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.229-1
- The emoji picker follows the colour emoji setting. It was drawing the
  system font's monochrome glyphs regardless, so one picked a grey symbol
  and the message then showed a coloured one - the same character looking
  like two different things. It now uses the same Twemoji images as the
  message text when the setting is on, via twemoji.js's own getEmojiPath so
  that the variation selector is stripped by exactly the same rule. All
  fifty characters in the panel were checked against the bundled files

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.228-1
- The bar highlights the page one is actually on again. Giving it a
  background in 0.9.225 meant wrapping the Row in an Item, so the Loader's
  "item" became that wrapper rather than the Row - and onLoaded set
  activeIndex on something that had no such property, leaving Chats
  highlighted everywhere. An alias passes it through

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.227-1
- The bottom bar can be hit now, and the reason was never its height. A
  ListView without clip draws its delegates past its own bounds, and those
  delegates still take touches - so the last chat sat behind the bar and
  swallowed the tap no matter how tall the strip was made. Three rounds of
  raising the height and a settings entry all missed it; the word that gave
  it away was "behind". The four lists that end at the bar are clipped now,
  and the bar carries a z of 10 as a second line of defence

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.226-1
- A recipient can only be forwarded to once per forward. Without any sign
  that something was happening one taps again, and every tap sent the
  picture anew - it arrived several times. The entry is now disabled while
  the send is in flight and stays disabled once it succeeded, showing dots
  during and a tick after, so there is something to look at instead of
  guessing. A failed attempt unlocks again, since one should be able to
  retry that. Opening the recipient list for a new forward builds the page
  afresh and clears the locks by itself. Four test cases, including that
  three rapid taps produce exactly one request

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.225-1
- Several messages can be forwarded at once. Long press offers Select,
  after which a tap picks messages instead of opening them - otherwise
  there would be no way out of the mode - and a strip above the input shows
  the count with Forward and Cancel. The chosen messages go out one after
  another with a pause between them, since a burst of forwards is the
  pattern that earned an account restriction here.
- The bottom bar has its own background and a separating line. Until now it
  was visually indistinguishable from the list above it, and where one aims
  at an invisible strip is guesswork - which is the likelier reason for
  hitting the last chat instead of Status than any remaining height problem

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.225-1
- The bottom bar has a background and a dividing line. Until now it was
  invisible against the list, so where to aim was guesswork - hitting the
  last chat instead of Status is the natural consequence of a strip you
  cannot see. It also settles the open question: the tinted area shows
  exactly where the bar sits and how tall it really is, which four rounds
  of adjusting a number could not

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.224-1
- The bottom bar was being set to Low behind your back. A Silica ComboBox
  emits currentIndexChanged while it is being built, with index 0, before
  the value from the preferences has been applied - so merely opening More
  settings wrote "small" and saved it, which is why three rounds of raising
  the default changed nothing on a device where the settings page had been
  visited. The handler now waits for the sync. The same guard went on the
  orientation and attachment pickers, where index 0 happens to be the
  default and the bug was therefore invisible.
- Status grouping is a switch under More settings, on by default. It was
  already in 0.9.220 but only reorders and shows each name once, which is
  easy to miss if you expected collapsible groups - and some people simply
  want the plain newest-first order regardless of who posted

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.223-1
- The bottom bar height is a setting, defaulting to tall. Three fixed
  guesses in a row (extra small, small, medium) each turned out too low for
  the person using it, and no single number is going to suit every thumb
  and every screen - so it is Low, Medium or Tall under More settings, and
  it starts Tall, because hitting the last chat instead of the bar is more
  annoying than losing a row of list. The geometry was checked first: the
  lists end at the bar's top edge and never overlap it, so this really is
  about the target size

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.222-1
- An emoji button beside the input, as rdomschk asked - switching the
  keyboard over for every single smiley was the complaint. It opens a small
  panel of fifty common characters above the input and inserts at the
  cursor. Deliberately a fixed short list rather than all 4010 bundled
  ones: a grid of thousands would be neither quick nor usable, and the
  keyboard remains there for everything else

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.221-1
- Fixes the white screen in 0.9.220. Multiple image selection was written
  against MultiImagePickerPage, which does not exist - Sailfish provides the
  multi-select variants as dialogs only (MultiImagePickerDialog), and an
  unknown type makes the whole QML file fail to load, so nothing rendered.
  The type name was assumed from the pattern of the single-select pages
  instead of read off the device, which is what listing
  /usr/lib64/qt5/qml/Sailfish/Pickers settles in one command. Selection is
  taken on accept now rather than on every change, as a dialog requires. All
  four picker types the app uses were checked against that listing

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.220-1
- Reverts the navigation change from 0.9.219, which left the bottom bar
  dead: a loop of navigateBack calls threw inside the click handler, and
  once that happens no entry responds at all. Back to pop(); getting back
  from Status still needs a proper fix, but a bar that does nothing is
  worse than one route that does nothing.
- Several pictures can be sent at once. The picker is the multi-select one
  now, and the files go out one after another with a pause between them
  rather than all at once - a burst of simultaneous uploads is the very
  pattern that earned an account restriction here in the first place.
- The status list groups by person, as rdomschk asked. Someone posting a
  whole photo album used to push everyone else off the screen; now their
  entries stay together, ordered newest person first, with the name shown
  once and the rest counted (2/7) instead of repeating it seven times

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.219-1
- Pictures zoom. Pinch to enlarge up to sixfold, double tap to switch
  between fitted and doubled, and the flickable pans what does not fit.
  Full resolution is requested once enlarged, otherwise one only magnifies
  screen pixels. Tapping to close now only works at normal size, since
  otherwise panning drops you out of the viewer. Suggested by rdomschk,
  who pointed at Fernschreiber.
- The bottom bar is taller again - itemSizeSmall in 0.9.218 was still too
  small a target - and going back from Status now works. That page is
  attached to the chat list with pushAttached, where pop(targetPage) is not
  the intended route and quietly did nothing; navigateBack is, and it
  carries both kinds of page

* Thu Aug 06 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.218-1
- The bottom bar is easier to hit. 0.9.217 made its labels bigger but left
  the strip itself at itemSizeExtraSmall, so the target stayed small and
  taps landed in the list above it - which is what rdomschk kept running
  into. The strip is itemSizeSmall now.
- Forwarding says where it went and can stay put. The confirmation was the
  untranslated word "Forwarded" and told you nothing about the recipient;
  it now names them, in all 22 languages, and failures are worded rather
  than pasted raw. More settings gained an option to remain in the
  recipient list after forwarding, so the same message can go to several
  people in a row, with a tick marking who already has it - without that
  mark one loses track and sends twice. Off by default, since returning to
  the chat is what one usually expects

* Mon Aug 03 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.217-1
- Two of Ralf's three suggestions. The bottom bar was hard to read: the
  labels are a size larger now, inactive entries carry the full secondary
  colour instead of a dimmed one, and the active one is bold. Unread counts
  appear beside Chats as well, not only Status, and either makes its label
  bold and highlighted - the point of a bar like that is to tell you where
  something is waiting without opening anything.
- A status reply quoted "[image]" or "[video]" when the status had no
  caption, so the recipient could not tell which one was meant - Ralf's
  daughter had to ask. The quote now names the status by time and date when
  there is no caption to quote instead

* Sun Aug 02 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.216-1
- Requires libsailfishapp-launcher, which provides the /usr/bin/sailfish-qml
  named in the Exec line. Found by danovium, who installed that package
  himself and had the app running - a user diagnosing it faster than three
  rounds of guessing here. On supported devices it is always present because
  countless apps pull it in; on a freshly flashed community port it need not
  be, and without it there is simply no binary to launch, so tapping the icon
  does nothing at all and leaves no trace. 0.9.215 added four missing module
  dependencies and this was the fifth and most fundamental one

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.215-1
- Declares the QML modules it actually imports. Five were being used while
  only three packages were listed as required: Nemo.KeepAlive,
  Nemo.DBus, Nemo.Notifications and Sailfish.Pickers went unmentioned. That
  it worked everywhere only meant those happened to be installed anyway -
  where one is missing the QML file does not load and the app does not
  start at all, with no error the user can see. Reported by a user on a
  OnePlus 6T community port at 5.0.0.67 where it would not launch; whether
  this is their cause is not yet confirmed, but the gap is real either way.
  Package names were read off a running device with rpm -qf rather than
  guessed, since a wrong Requires would break installation for everyone

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.214-1
- Channels show their names. The names were being fetched all along -
  GetSubscribedNewsletters returns them - but they went straight to the
  channel page and were never kept, so the chat list showed the bare
  newsletter id: an eighteen digit string nobody recognises a channel by.
  They are stored with the other names now and refreshed shortly after
  connecting, rather than only when someone happens to open the channel
  page. Noticed while checking whether the status LID work had broken
  anything for channels; it had not, they had simply never had names

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.213-1
- Links in status updates are tappable. The text there was rendered raw
  while the chat has run everything through linkify for ages, so a link in
  someone's status could only be read, not followed - and emoji stayed
  monochrome there as well. Same treatment as in chat now, escaping
  included

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.212-1
- The status list resolves its senders properly. 0.9.211 only flagged
  messages as they arrived, which left every stored one - that is, every
  one actually on screen - unmarked. Resolution happens when the list is
  served now: each sender is looked up in the LID store first, and where
  that succeeds the real number replaces the hidden one, which also
  restores the name. Failing that, obvious cases are recognised by length
  and country code. The heuristic has a limit worth naming: 5184193331367
  and 6098937458744 are LIDs too, but 518 starts with 51 (Peru) and 609
  with 60 (Malaysia), and the length passes for real - no prefix rule can
  tell those apart. So the reply button does not hang on the guess at all;
  it appears only where the sender can actually be named from the
  contacts. Replying into the dark would reach whoever really owns that
  number. Seventeen test cases, using the numbers from the affected device

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.211-1
- Status updates were showing numbers that belong to nobody. What appears
  there is often a LID - WhatsApp's hidden addressing - and a LID looks
  exactly like a phone number with an unfamiliar country code while being
  nothing of the sort: no name can be found for it, and it must not be
  treated as a number to dial or message. resolvePN already tries to turn
  it into a real number but falls back to the LID when the mapping is
  missing, which for status broadcasts is the common case. Messages now
  carry a flag saying the sender could not be resolved, and where that is
  set the entry reads "Unknown contact" instead of a plausible-looking
  string of digits - a wrong number is worse than none, because it invites
  belief. The reply button added in 0.9.210 is hidden for those entries:
  replying would have addressed whoever really owns that number. Caught by
  smatkovi before the button was ever used in anger

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.210-1
- The remaining two of rdomschk's three wishes, and colour emoji goes back
  to being on by default: tested on the device, scrolling showed no
  noticeable difference, and the switch to turn it off stays.
- Replying to a status. Each entry that is not your own now carries a reply
  button, which opens the chat with its author and puts the status in the
  quote box - which is what the official client does too, a status reply
  being an ordinary message that quotes the status. The send path already
  understood quotes, so nothing new was needed there; the quote is handed
  to the chat page and picked up once it exists, since the page is built
  only at the moment of pushing.
- Unread status updates are counted, shown next to Status in the bottom bar
  and cleared when the page is opened. What gets remembered is the
  timestamp of the newest one seen, not every individual id: that cannot
  grow without bound and survives a restart. The count is refreshed on the
  same beat as the chat list, because a counter only visible while its own
  page is open would be seen by nobody. Six test cases, including that your
  own posts never count and that an older entry cannot push the mark back

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.209-1
- Colour emoji is opt-in. It touches every message text and puts images
  where glyphs used to be, which is not a change to make on someone's
  behalf: whoever wants it turns it on under More settings, and whoever
  does nothing keeps the app exactly as it was. The description says so
  too, in all 22 languages

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.208-1
- Colour emoji, as suggested by rdomschk, who pointed at Fernschreiber.
  Reading its source settled how: Sailfish ships no colour emoji font at
  all, so Fernschreiber substitutes each emoji with a bundled Twemoji SVG
  (MIT, Twitter and contributors) via an img tag. The same approach works
  here without changing how text is rendered - message labels already use
  StyledText, which understands img. The substitution sits at the end of
  linkify, deliberately after the escaping of angle brackets, since doing
  it earlier would escape the very tags it produces. 4010 files sound
  heavy but compress to about a megabyte in the package. There is a switch
  under More settings for anyone who prefers the system font's plain
  glyphs. Seven test cases cover the ordering trap: escaped text stays
  escaped, links survive alongside emoji, and multi-codepoint sequences
  such as flags resolve to the right file

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.207-1
- Notifications make a sound again, and the LED blinks. Reported by
  rdomschk, who had the sound switch on and heard nothing, and noticed the
  status LED stayed dark while the official client lights it. The ngfd
  event we asked for was named wrong: chat.ini defines both [chat] and
  [chat_exists], and they do quite different things - [chat] pulls in only
  "haptic", so vibration and nothing else, while [chat_exists] pulls in
  "default" with the tone and mce.led_pattern = PatternCommunicationIM.
  The notification category ships x-nemo-feedback=chat_exists for exactly
  that reason, and we were overriding it with "chat,vibra", replacing
  something that worked with something inert. Measured on the device:
  category default rings, our value is silent, chat_exists,vibra rings and
  vibrates. When the tone is switched off, communication_led is now sent
  in its place, because the LED hangs off the same event - muting should
  buy quiet, not the loss of the one silent hint that something is unread

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.206-1
- The chat page carries the same nineteen entries twice, once as a
  pull-down at the top and once as a push-up at the bottom, and 0.9.203
  shortened only the first - so in landscape the long menu was still
  there, just at the other end. Both are down to six now: search, live
  location, location, disappearing messages, clear chat, and call, which
  takes the poll's place in a one-to-one chat while groups keep the poll.
  Portrait is unchanged. The entries written on a single line were edited
  in place this time rather than given an extra line, which is what
  produced the duplicate property and the white screen in 0.9.204

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.205-1
- Fixes the white screen in 0.9.204. Three menu entries were written on a
  single line with their visible property inline, and the landscape
  condition was appended as a further line - which lands outside the
  braces and sets visible on the enclosing menu a second time. QML refuses
  the whole file for that, so nothing rendered at all. The three are
  ordinary multi-line entries now. Neither qmllint nor qmlformat reports a
  duplicate property; only the running engine does, and only as
  "Property value set multiple times" once it is too late. There is a
  check for it in the test suite now (tests/qml_dupprops.py), verified
  against a deliberately broken copy. Also gives width to the list items
  on the collected actions page and in the attachment chooser: children of
  a Column get no width of their own, so they would have been zero pixels
  wide - the attachment chooser has carried that since 0.9.189

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.204-1
- Fixes 0.9.203, which had the landscape condition inverted on the entries
  it was supposed to keep: settings, search, join via link, new group and
  new chat carried "visible: isLandscape", so in PORTRAIT they disappeared
  entirely - the one thing the change was explicitly not meant to touch.
  Caught by comparing the packaged QML against the source rather than
  trusting the build, which is now a fixed step: the file inside the RPM
  must be byte-identical to the one in the tree. Landscape behaviour is
  unchanged from what 0.9.203 intended - six entries per screen, All
  actions in place of channels, portrait exactly as it always was

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.204-1
- Calling is reachable where the number actually is. The contact info page
  had a pull-down menu only for groups: open it for a person and there was
  no entry at all, on the very page that shows their number. It now offers
  Call for contacts and keeps the three group entries for groups. In a
  one-to-one chat in landscape, Call takes the place of Create poll - a
  poll between two people is rarely what anyone is after, and landscape
  has room for six entries, not seven. Portrait keeps both, unchanged.
- Fixes a mistake in 0.9.203: the six entries kept for landscape were
  written as visible-only-in-landscape, which would have made them vanish
  in portrait - the opposite of "portrait stays as it is". Only the hidden
  ones carry a condition now, plus All actions, which is landscape-only by
  design

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.203-1
- Short pulley menus in landscape. Since 0.9.200 the interface follows the
  device, and sideways the chat menu's nineteen entries simply do not fit -
  the lower ones were unreachable. Landscape now shows six on each screen
  and portrait is untouched. Chat: search, live location, location,
  disappearing messages, clear chat, poll. Main screen: settings (in place
  of profile), search, join via link, new group, new chat, and All actions
  in place of channels - a page rather than a second pulley, because a list
  scrolls and a pulley does not, so everything stays reachable from there,
  channels and profile included. The collected page reuses the real
  handlers, including the fifteen-second remorse window on logout, which
  matters more in a list one can mistap than in a pulley

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.202-1
- Same content as 0.9.201 under a number that can be installed: 0.9.201
  was already taken

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.201-1
- In groups the sender line often showed the GROUP name instead of the
  person, or nothing at all. The history sync fell back to sender =
  chatJid when a message carried no participant field, which for a group
  is the group's own JID - and the contact map, which holds groups too,
  then dutifully resolved it to the group name. The fallback now applies
  only to one-to-one chats, where the chat partner really is the sender,
  and the display order is stated plainly: your own contact name first,
  then the name the person gave themselves (the push name the server
  sends), then the phone number. A group JID is never a valid sender, so
  it yields nothing and the line is omitted rather than asserting
  something false. The empty label also used to occupy its line silently,
  which is why the name appeared to be missing at random. Six test cases,
  including both directions of the group-name confusion

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.201-1
- Fixes 0.9.200, which did nothing: the app stayed in portrait whatever
  the setting said. allowedOrientations on the window only PERMITS
  rotation - every page decides for itself and defaults to portrait
  without an entry of its own, so the pages went on refusing what the
  window allowed. All thirty pages and dialogs now carry the mask
  explicitly. Silica's internal _defaultPageOrientations would have been
  one line instead of thirty, but it is undocumented and a version that
  lacks it would refuse to start the app at all - not a risk worth taking
  for brevity when the failure mode is that severe. The three fullscreen
  views keep Orientation.All as before

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.200-1
- The interface follows the device now. Everything except the three
  fullscreen views was locked to portrait, which on a keyboard-less phone
  held sideways is simply the wrong shape. More settings gained Screen
  orientation with three choices: follow device (the new default), portrait
  only, landscape only - the fixed options are there because a phone lying
  on a desk or in a car mount flips at every touch, and for reading in bed
  the lock is the whole point. The window sets the default and every page
  inherits it. The fullscreen photo, status and video pages keep rotating
  freely regardless of the setting: someone who locks the chat list to
  portrait still wants a video the right way round, and watching it
  sideways is the entire purpose of fullscreen. Five new strings in all 22
  languages

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.199-1
- Tapping a group member opens the chat with them. Suggested by
  kempertom, who had only the long-press menu with call, admin and remove
  and no way to simply write to someone. Silica separates the two
  gestures by itself - the favourites list has had a context menu and an
  onClicked side by side all along - so the menu keeps its three entries
  unchanged and no fourth was added; an entry duplicating what the tap
  already does would just be clutter. Both member lists behave the same
  now, the one on the group info page and the one further down on the
  chat info page, because two lists of the same people that respond
  differently are worse than either alone. Your own entry is deliberately
  not excluded: a note to self is a real use for it

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.198-1
- The "background service is not running" warning was itself the bug. It
  checked once, twenty seconds after start, and then stopped the timer -
  and twenty seconds after start is exactly when the service is coming
  back up from a package update. The warning was true at the instant it
  was made and wrong for the rest of the session, with no way to clear it
  short of restarting the app, which is what made it look like the daemon
  had really died. The check keeps running now, waits for two consecutive
  misses before saying anything, and withdraws its own warning when the
  service reappears - and may warn again later if it really goes away.
  The message also carries the start command, since the app cannot start
  a systemd unit from inside the sandbox and pointing at a settings entry
  that has no button was no help. Six test cases for the state machine,
  cross-checked against the old one-shot logic, where three of them fail

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.197-1
- Revoking a permission now says the truth about when it takes hold. The
  grant and revoke commands already edit both desktop files, so the
  daemon profile is written immediately - but sailjail applies a profile
  at process START, and a background service is by design one that keeps
  running. Revoke storage and the file says no while the running daemon
  goes on reading, possibly for days. 0.9.195 caught the granted-but-not
  yet-effective direction; this catches the other, which is the more
  uncomfortable one, since nobody expects a permission they just removed
  to still be in force. The Sailjail page compares what the file says
  with what the process can actually do and, when they disagree, names
  the direction and offers to restart the service right there. Five new
  strings in all 22 languages

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.196-1
- A partial storage grant is now named as such. permcheck reported the
  three media tokens as one yes-or-no, so having UserDirs and
  MediaIndexing but not RemovableMedia - internal storage fine, SD card
  denied - looked exactly like "nothing granted at all", which is useless
  advice for someone who ran the grant long ago. The missing tokens are
  reported individually now and the message names them, points out that
  RemovableMedia is the one for the SD card, and says the GRANT command
  may simply be run again: it appends only what is missing, so a second
  run is harmless. That last part matters because the desktop file is
  config(noreplace) and can therefore be in any historical state, from
  before a token existed - it survives every update untouched, which is
  the point of the flag and also the trap. In all 22 languages

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.194-1
- "Permission denied" on a file now says what it means. Reported by
  kempertom, who had granted the permissions and still could not send a
  file from the SD card - and he was right to be puzzled. Two things were
  wrong. The raw error pointed at file ownership when the real cause is
  the sandbox: outside its own data directory the backend may read
  nothing without the storage grant. And permcheck read the DESKTOP FILE
  rather than the live sandbox, so it reported "granted" the moment the
  text was there, while sailjail applies a profile at process START -
  the running process still carried the old one. Since 0.9.181 the app
  attaches to a running daemon instead of starting its own backend, so
  the file is opened in the DAEMON's jail and restarting the app alone
  changes nothing. permcheck now probes what the running process can
  actually open, and the message distinguishes the two cases: not granted
  yet, or granted but not in effect yet - and in the latter case it names
  the right process. With a background service running, that service has
  to be restarted and restarting the app achieves nothing, because the
  app attaches to it and the file is opened there. Without one, the
  backend is the app's own child and inherits its jail, so closing the app
  properly and reopening it is genuinely enough - telling those users to
  restart a service they never enabled would have sent them looking for a
  switch that is not there. In all 22 languages
* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.194-1
- "permission denied" when sending a file from the SD card is now
  explained instead of quoted. The backend cannot read anything outside
  its own data directory until the storage permission is granted, and the
  raw error sends people looking at file modes rather than at sailjail -
  reported by kempertom, whose message only reached us at all because
  0.9.185 stopped swallowing send errors. The notice now names the cause
  and the exact route: Settings, Sailjail permissions, GRANT storage,
  then restart the app and the background service. The offending path
  stays visible underneath so it is still clear which file failed. Server
  rejections are unaffected and keep their own wording. In all 22
  languages, with test cases covering both directions

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.193-1
- The daemon writes a log now. It was the only part of the system without
  one: systemd sends its output to the journal, which on the device is
  volatile, capped at one megabyte and unreadable without being in the
  systemd-journal group - so the instance that is meant to run unattended
  logged into nothing. Every diagnosis so far read backend.log, which
  only ever contained the app's own backend; the daemon's side of the
  same events was simply absent, including the logout this morning. It
  writes to daemon.log in the data directory now, trimmed at startup the
  same way. File descriptors 1 and 2 are swapped rather than os.Stdout,
  so whatsmeow's own logger follows too, and a separate file is used
  because start_backend.py rotates backend.log at app start - the daemon
  would have carried on writing into a deleted inode. Doing it in the
  backend rather than via StandardOutput=append: keeps it independent of
  the systemd version on the device

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.192-1
- Half of what the matrix called device-only turned out not to be. The
  daemon guard in start_backend.py now runs against a real HTTP backend
  on port 8085 and counts which endpoints get touched: an old daemon must
  not be replaced via /quit, an old child must, matching versions leave
  everyone alone, and an unknown installed version shoots nothing. Cross
  checked against the broken 0.9.186 state, where two of those cases
  fail - so the test actually tests something. The connman handling now
  runs against a real bus with a stand-in net.connman, exercising
  watchNetwork unchanged: match rule, signal name, object path and
  variant unpacking, none of which a table test can reach. Port file
  release is covered too, including the case where the entry belongs to
  another instance. connectWithGuard grew a nil-client check on the way,
  since a network signal can arrive before initialisation finishes. What
  is left for the device is genuinely device-bound: sailjail, systemd,
  the WhatsApp servers, and the screen

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.191-1
- Same code as the corrected 0.9.190 under a version number that can
  actually be installed: 0.9.190 was built twice, the second time with
  the backoff overflow fix, and pkcon refuses to reinstall a version it
  already has. Adds TESTMATRIX.md, which lists what is checked
  automatically (backoff ladder, watchdog decisions, connman property
  handling, wake channel, the eight-hour offline simulation, error text
  and catalogue coverage) and what only a device can answer (sailjail and
  the system bus, systemd restart timing, first contact against the
  actual servers). The three most expensive bugs in this project would
  not have been caught by any unit test - they were all in the log, and
  the matrix says so out loud

* Sat Aug 01 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.190-1
- The daemon now survives being offline, which it did not. With
  whatsmeow's own auto-reconnect deliberately off since 0.9.178, a failed
  connection attempt produces neither a Disconnected nor a ConnectFailure
  event - so the one place that could have scheduled another try simply
  printed the error and returned. One dead spot with no signal (a tunnel,
  flight mode, wifi dropping at the wrong second) and the daemon stopped
  trying for good: still running, still answering /status, just never
  connecting again and never saying so. Failed attempts now reschedule
  through the same guard, and a watchdog checks every minute whether we
  ought to be connected but are not. On top of that the daemon listens to
  connman on the system bus (already covered by Internet.permission,
  which includes Connman.permission): when wifi, mobile data or the end
  of flight mode brings the network back, the pending backoff is cut
  short instead of waiting out up to five minutes. /status gained a
  network field for diagnosis. Testing the new code turned up an old
  overflow in the backoff itself: 5*(1<<61) does not fit in an int64, so
  after roughly sixty consecutive failures - about five hours without a
  signal - the five-minute spacing collapsed to zero and only the ten
  second floor remained. Simulated over an eight hour night that is 1752
  connection attempts instead of 100, which is precisely the storm the
  guard exists to prevent. The exponent is now clamped before shifting.
  The reconnect logic, the connman handling and the watchdog decisions
  come with a test suite (backend/reconnect_test.go,
  backend/offline_scenario_test.go)

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.189-1
- The paperclip no longer forces the folder tree on you. Sailfish ships
  more than one chooser, and the one kempertom was asking about is the
  content picker, which sorts by type - pictures, videos, music,
  documents - the same component the status page has always used. Tapping
  attach now asks which one to use, and More settings holds the default
  (ask every time, media library, file browser) for anyone who wants the
  question gone. Picking from the question replaces rather than stacks,
  so the way back from a chooser leads to the chat. Six new strings in
  all 22 languages

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.188-1
- No functional changes: a version bump to field-test the daemon guard
  repaired in 0.9.187. Only a version difference sends the app down the
  /quit path at all, so 0.9.187 could not test itself - install this,
  touch the daemon with nothing, open the app, and the daemon must still
  be there afterwards. Also drops qml/harbour-whatsapp.qml.bak, a stale
  300 KB copy of the main QML file that cp -r had been shipping to every
  user

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.187-1
- Found the real reason the daemon vanished after an update, and it was
  not what 0.9.186 guessed. The guard from 0.9.181 - never replace a
  running DAEMON via /quit, because a clean exit is one systemd will not
  restart - was dead code: it parses the status with json, but json was
  imported inside backend_version() only, so the module namespace never
  had it. The resulting NameError landed in a bare except, is_daemon
  stayed False, and the app politely shot the daemon dead on every start
  after a version bump. The backend log shows it exactly: two "Quit
  requested" and not a single "self-updating via exit 1". One import
  moved to module level fixes it; the except now reports instead of
  swallowing, since a silent failure there is what disabled the guard in
  the first place

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.186-1
- The background daemon no longer dies quietly on update. Installing the
  RPM replaced the unit file while the old daemon deliberately exited 1
  for its self-update - systemd still held the stale definition ("unit
  file changed on disk") and the restart never happened, so notifications
  stopped and nothing said so; it was noticed by chance when opening the
  app. The %%post script now runs daemon-reload and try-restart via systemctl-user,
  which only touches a daemon that was actually running. The start rate
  limit is relaxed (30 starts per 10 minutes, 10 s apart) so a single
  failed self-update cannot park the service for good. And if it is
  stopped anyway while autostart is on, the app says so on the main page
  after twenty seconds instead of leaving it to be discovered - in all 22
  languages

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.185-1
- Failed sends are no longer silent: the text path only ever handled HTTP
  200, so a rejection left the message sitting in the box with no hint at
  all - the reason existed, it was thrown away. Every non-200 now shows
  the backend's answer, and WhatsApp's own rejection codes (4xx in the
  server ack, e.g. 463 on a first contact during a temporary account
  restriction) are translated into a plain explanation instead of a bare
  number. After such a rejection in an empty chat, further attempts are
  held back - repeated first-contact tries are exactly what prolongs a
  restriction. Voice notes and file sends use the same wording. Error
  colouring no longer depends on the English word "failed" appearing in
  the text, which quietly broke for every translated message. Six new
  strings in all 22 languages. The backend also releases its port file on
  every clean exit (quit, SIGTERM, self-update) instead of leaving it
  pointing at a dead port

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.184-1
- Own message bubbles are translucent now (Theme.highlightBackgroundColor
  at the ambience-tuned Theme.highlightBackgroundOpacity instead of the
  solid color): with light ambiences the black text sat on heavy color
  and was hardly readable - thanks kempertom for the report. Incoming
  bubbles were already translucent; readability now follows the
  ambience contrast in both directions

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.183-1
- No functional changes: version bump to field-verify the app-free
  daemon self-update chain end to end (install RPM, touch nothing, the
  running 0.9.182 daemon reads the stamped desktop file and swaps
  itself within five minutes)

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.182-1
- The self-update poller was blind: sailjail derives the daemon jail
  whitelist from the desktop FILE NAME, so /usr/share/harbour-whatsapp
  (and its VERSION file) is invisible to the daemon - and the read
  failure was swallowed silently, a double fault. The spec now stamps
  X-Whatsapp-Version into the daemon desktop file, which is verbatim in
  the jail whitelist; the poller falls back to it and logs once if no
  version source is readable instead of hiding

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.181-1
- Fixed two competing update mechanisms racing each other: the legacy
  app-start path replaced ANY version-lagging backend via /quit - which
  is a clean exit, so systemd deliberately does not restart it. Applied
  to the daemon this meant: app open -> daemon permanently stopped ->
  app closed -> nothing running at all. The app now recognises a daemon
  (status daemon:true), attaches instead of quitting it, and leaves the
  upgrade to the exit-1 path (QML trigger or the daemon's own VERSION
  poller). /quit remains reserved for the app's own child backend

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.180-1
- The daemon updates itself without the app now: it polls the installed
  VERSION file every five minutes and exits deliberately on a mismatch
  so systemd starts the fresh binary - pure daemon users who never open
  the app after updates are covered. The app-side trigger from 0.9.177
  remains as the faster path. The tappable disable command in Settings
  got a red warning label, since it sits right below restart and a
  mis-tap silently ends notifications at the next reboot

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.179-1
- whatsmeow updated to 2026-07-30 (662ad1dc): four protocol bumps up to
  v1044142122, DMs now always sent via LID matching current official
  client behaviour, pairing improvements (client props, passkey
  support), LID group fixes, receipts acked only after handling, and an
  updated IsOnWhatsApp query. go-util bumped alongside. Good timing:
  re-pairing after the restriction happens on a fresh protocol level

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.178-1
- Single-connection guard and reconnect damper: before ANY connect, the
  backend checks whether another local instance (app or daemon) already
  holds the WhatsApp session and stands by instead of competing; between
  connection attempts a minimum interval and exponential backoff apply.
  whatsmeow's instant auto-reconnect is disabled in favour of this
  guarded path. Lesson from the two-instance session tug-of-war that got
  the device logged out by the server - that class of storm is now
  structurally impossible

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.177-1
- The daemon updates itself: after an RPM update the old process kept
  running (and old builds sat in a silent halt, which is why the new
  self-healing never announced itself). The app now detects the version
  lag and asks the daemon to restart via a new endpoint that exits
  non-zero on purpose, so systemd brings up the freshly installed binary
  - no Terminal, no manual restart, the app reattaches automatically

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.176-1
- The daemon is infinitely patient with Sailfish Secrets now: instead of
  giving up ~8 seconds after boot (while the device is still locked, so
  Secrets cannot answer yet), every secrets failure enters a quiet
  10-second retry loop - unlocking the device heals it automatically.
  If only an app start can help (one-time key handover), the daemon uses
  its core competence and sends a notification asking for exactly that
  after a few minutes. Verified on-device that app and daemon share the
  same sailjail identity and data directory, so this plus the proactive
  migration closes the daemon-from-boot story

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.175-1
- The one-time migration is proactive now: when the app loads the key
  from the legacy owner-bound collection, it immediately re-publishes it
  into the identity-open one - so after the first app start following
  this update, the boot daemon serves notifications forever without the
  app ever being opened again. Fresh installs are identity-open from the
  start and never need any of this

* Fri Jul 31 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.174-1
- Key handover between identities is fully automatic now: an instance
  without the key (typically the background daemon) no longer halts but
  retries every 10 seconds, and the owning instance exports the key
  inside Sailfish Secrets and keeps running - opening the app once from
  the app grid heals everything, no Terminal, no restarts. The old error
  text confidently blamed Terminal starts, which was misleading (thanks
  for calling it out); it now states only what the error code actually
  says, with app-versus-daemon named as the common case

* Thu Jul 30 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.173-1
- The Liberapay donate button is live: liberapay.com/smatkovi for
  recurring support, alongside the existing PayPal button

* Thu Jul 30 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.172-1
- The About page speaks all 22 languages now, including the thanks
  paragraph and the not-affiliated disclaimer - and Vienna appears as
  Vindobona where a daemon would expect it to

* Thu Jul 30 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.171-1
- Donate button now uses paypal.me/smatkovi: the classic donations flow
  turned out to be reserved for registered organisations, PayPal.me is
  the proper route for individual developers

* Thu Jul 30 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.170-1
- About page in Settings: version, developer, GitHub and issue links,
  community thanks, whatsmeow credit and the usual not-affiliated-with-
  Meta disclaimer. Donate button for PayPal included; a Liberapay button
  is wired up and appears once the account exists

* Thu Jul 30 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.168-1
- Sending a file now says so: the chat shows "Sending <name>... 12s" while
  the upload runs and clears it when the message appears. Large files take
  double-digit seconds, and silence looked exactly like failure

* Thu Jul 30 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.167-1
- Sending pictures, videos and files works again (reported by kempertom,
  traced on-device): during an upload the phone is busy, so the status
  check ran into its one-second timeout - and a missing answer counted as
  a version mismatch, which made the app shut down its own backend in the
  middle of the transfer. No response, nothing sent, no error. Now only a
  genuinely different version replaces the backend, the status timeouts
  are generous, and while an upload is in flight a slow backend counts as
  busy rather than lost

* Thu Jul 30 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.166-1
- Notices are now shown on the chat page as well: they only existed on
  the chat list and the main page, so a failed send reported nothing
  where you actually are. Plus WASEND diagnostics on the picker and send
  path to find why sending does nothing at all

* Thu Jul 30 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.165-1
- Notices can be tapped to copy, like the pairing error already could -
  error texts are meant to be forwarded, and the new send-failure notice
  carries the status code, the backend reason and the file path

* Thu Jul 30 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.164-1
- Sending pictures, videos and files works for background-daemon users
  (reported by kempertom): the daemon runs under its own sailjail profile,
  but the permission commands in Settings only patched the app profile -
  so the picker could select a file the backend was not allowed to read,
  and sending silently did nothing. The grant/revoke commands now cover
  both profiles, and %post mirrors already-granted permissions onto the
  daemon profile, so existing installs are fixed by the update alone.
  Permissions stay opt-in as before - nothing is granted by default
- Failed sends no longer fail silently: the send path ignored the HTTP
  status entirely, so a backend error (unreadable file, upload refused)
  looked exactly like nothing happening. The reason and the file path
  are now shown in a notice, which is what the next report needs

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.163-1
- Chat position now holds for videos and audio too (reported by rdomschk):
  those open an internal player page, so the chat page becomes invisible
  and its delegates are gone - the position anchor is now taken from the
  snapshot captured while the page was still visible instead of probing
  the empty view
- Unread counter clears immediately when you open a chat and go straight
  back (reported by rdomschk): opening a chat did not announce itself to
  the long-poll, so the chat list kept the stale count until some other
  event arrived; the read state is now also written on leaving the chat

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.162-1
- The chat position saga is over, confirmed on-device: every model
  refresh used to teleport the view synchronously, and all restoring
  happened 200 ms later - now the view is re-anchored to the topmost
  visible message by id, with its pixel offset, in the same JS turn as
  the refresh. No frame with a wrong position is ever rendered, origin
  shifts of the list are absorbed by design, and viewer returns, mid-chat
  downloads and scroll-during-refresh all hold steady. Diagnostic logging
  removed for release

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.161-1
- Mid-chat position now survives refreshes exactly: pixel coordinates
  are not a stable identity across a model reassignment (the list can
  shift its origin, logs showed a 222 px error), so the synchronous
  holdback now re-anchors by message id plus offset in the same JS turn,
  with the pixel value only as a fallback when the anchor message is gone

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.160-1
- The actual fix, proven by WAPOS logs: every model refresh teleported
  the view position synchronously (pre keepY=10073 -> post y=25106) and
  everything so far compensated 200 ms later, leaving a window for wrong
  jumps to be cemented. The teleport is now undone in the same JS turn -
  no frame with a wrong position is ever rendered. The restore timers
  remain only as safety nets against late layout drift

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.159-1
- Root cause from WAPOS logs, two shots: the activity flicker when the
  external viewer starts triggered a second capture that overwrote the
  good position snapshot with a transient zombie state (atYEnd=true at
  contentY~-40, no anchor), and the first refresh after resume sampled
  that same zombie as "at the end". Captures are now one-shot until a
  restore consumes them, and while a capture is unconsumed, refreshes
  trust the captured wasAtEnd/position instead of the live view state

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.158-1
- Shields the restore target against back-to-back model refreshes: when
  a restore is still pending, the transiently wrong view position is no
  longer sampled as "at the end" and the previous restore target is
  carried over - a second refresh arriving within the 200 ms window
  could otherwise cement the wrong jump. More WAPOS detail in load()

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.157-1
- The downloaded image no longer scrolls out of the viewport: WAPOS
  diagnostics showed a stale keep-me-at-bottom flag (set by an earlier
  at-the-end restore) firing on the download refresh and jumping the
  view to the chat end. The flag is now cleared on every programmatic
  reposition - entering the viewer, mid-chat restores and anchor
  settling - where the touch-scroll clearing never triggers

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.156-1
- Downloaded media shows up immediately again: since long-polling, every
  message mutation must announce itself, but the download path (and a few
  others: pinning, clearing chats, storage cleanup, logout) still wrote
  silently - the UI only noticed via the 30-second safety net. All direct
  message mutations now trigger the event bump. WAPOS diagnostics still in

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.155-1
- Fixes the chat jumping to the top after the viewer: a stale anchor id
  made the regular restore timer yield forever, so after the next model
  refresh nobody restored the position at all. The anchor is now cleared
  in every restore branch and the right-of-way rule only applies while
  settling actually runs. WAPOS diagnostics still included

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.154-1
- Diagnostic build for the remaining position issue after the media
  viewer: compact WAPOS log lines cover capture, restore branch, anchor
  settling and the fallback path. Not meant for OpenRepos

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.153-1
- The two position restorers no longer race each other: while the anchor
  is settling, the regular restore timer yields; a model refresh during
  settling restarts the settling on the fresh delegates; and the anchor
  index is re-resolved by message id if it shifted. This removes the
  remaining back-and-forth and the occasional wrong final position after
  the media viewer

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.152-1
- No more visible back-and-forth while the position settles after the
  media viewer: coarse positioning and pixel offset are now applied in
  the same JS turn (nothing is rendered in between), repeated a few
  times idempotently to absorb late delegate layout, and the settling
  stops immediately if you start scrolling yourself

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.151-1
- Position restore after the media viewer is pixel-exact again: the
  anchor message no longer sticks to the top of the screen. The pixel
  offset is now applied in a second step after positionViewAtIndex has
  settled - applying it immediately was overrolled by the still-running
  delegate layout

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.150-1
- Long-polling replaces the blind 2-second refresh: the UI now hangs on
  a new /events endpoint and the backend answers the moment something
  happens. New messages, edits, reactions and deletions appear instantly,
  and when nothing happens, nothing is transferred - better battery life
  despite the snappier feel. The old timers remain only as slow safety
  nets (30 s in the chat, 60 s for the chat list)

* Wed Jul 29 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.149-1
- Fixes the white screen on startup in 0.9.148: two orphaned debug-log
  fragments (leftovers of the removed WAPOS diagnostics) broke QML
  parsing of the whole file. qmllint is now part of the release checks
  so a parse error can never ship again. If you installed 0.9.148,
  just update - nothing else to do

* Tue Jul 28 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.148-1
- Chat position after viewing media, the release version (reported by
  rdomschk, debugged on-device): no shift at all when nothing changed
  while the viewer was open; when messages arrived meanwhile, the list
  re-anchors to the message that was at the top of the screen at the
  same pixel offset, with center-on-message only as a last resort; a
  stale keep-me-at-bottom flag no longer fires on channel view-counter
  refreshes. WAPOS diagnostic probes from the test builds removed

* Mon Jul 27 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.147-1
- No more slight shift after viewing a picture: if the message model did
  not change while the viewer was open, the exact pixel position is kept
  (or silently restored); the coarse center-on-message restore only kicks
  in after a real model refresh reset the list

* Mon Jul 27 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.146-1
- Channel jump-to-bottom finally fixed, confirmed by journal diagnostics:
  a stale forceEnd flag ("keep me at the bottom"), armed whenever the
  page re-activated at the end, fired at the next JSON refresh - which
  in channels happens all the time because of view counters. The flag
  is now disarmed the moment the user starts scrolling. Diagnostic WAPOS
  probes stay in for one release to confirm on-device

* Mon Jul 27 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.145-1
- Diagnostic build for the channel scroll-to-bottom issue: WAPOS log
  probes around every code path that positions the message list, so the
  culprit shows up in the journal instead of being guessed at

* Mon Jul 27 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.144-1
- Channel position fix, the real one this time: channel messages carry
  view counters, so the poll refreshed the model without the count
  changing - and repositioning only ran on count changes, so the view
  reset shortly after every restore. The list now repositions after
  every model refresh, and the position probe has a fallback when it
  lands in a gap between messages

* Mon Jul 27 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.143-1
- Position restore now also works when you were scrolled up mid-chat -
  most noticeable in channels (reported by rdomschk): the message index
  is remembered both when an internal player/viewer opens and when media
  opens externally, and you return to exactly that spot; bottom stays
  bottom as before

* Sun Jul 26 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.142-1
- Coming back from an externally opened photo/video/audio no longer lands
  you in the middle of the chat (reported by rdomschk): the position is
  remembered as a message index when the app deactivates and restored on
  return - if you were at the bottom, you come back to the bottom

* Thu Jul 23 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.141-1
- The Reply button inside notifications is translated now (reported by
  rdomschk): the UI stores the translated label in prefs and the backend
  uses it, so qml/translations.js stays the single source of truth
- Sending a picture scrolls the chat to the bottom again (reported by
  rdomschk) - it looked as if nothing had been sent because the view
  stayed where it was after returning from the gallery picker

* Thu Jul 23 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.140-1
- Tile spacing slider now goes up to 30 (was 5) for a lot more ambience
  between the tiles. The cap is relaxed to a third of the cell width, so
  a tile never shrinks past the point where avatar and name stay readable.
  Higher column counts reach that cap earlier by design

* Thu Jul 23 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.140-1
- Tile spacing goes further now: slider maximum raised from 5 to 10 and
  the cap relaxed to a quarter of the cell width, so tiles can shrink to
  half their cell and let a lot more ambience through. Default unchanged

* Thu Jul 23 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.139-1
- Tile spacing is now adjustable in More settings (requested by kempertom):
  wider gaps let more of the blurred ambience show through between tiles.
  Default is unchanged, so the grid looks exactly as before until you
  move the slider; 0 gives a gapless mosaic. Spacing is capped relative
  to tile width so 5-6 columns stay readable

* Wed Jul 22 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.138-1
- Notification tap: back arrow now returns to Chats, not to Favorites -
  the chat is popped to the Chats page instead of the stack root, which
  could be another page after a bottom-bar jump
- Search page is now translated (title and placeholders) in all 22 languages

* Wed Jul 22 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.137-1
- Translation polish: "Make admin" / "Remove admin rights" (previously
  hardcoded English) and "Invite link copied" are now proper catalog keys,
  and media/links section headers are translated in all 22 languages

* Wed Jul 22 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.136-1
- Group management works right on the info page now: long-press a
  participant to call, promote/demote or remove; pull down for invite
  link (copied to clipboard), leaving the group, or the full group
  info page (add participants, rename, description, join requests)

* Wed Jul 22 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.135-1
- Media, links and documents overview per chat (requested by tom_i):
  the contact/group info page (swipe left in a chat) now shows a photo/video
  grid, all shared links and all documents from the whole chat history -
  tap a placeholder to download, tap media to open
- Group participants are listed right on the info page (first 100)
- Tap the profile picture on the info page to view it fullscreen
- URL links in messages are now clickable (requested by tom_i)

* Wed Jul 22 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.134-1
- Bottom navigation bar now shows on all four pages - Archive, Favorites,
  Chats and Status - with the active page highlighted (requested by rdomschk)
- Multi-level jumps (e.g. Archive straight to Status) chain through the
  page stack automatically

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> - 0.9.133-1
- Every language Sailfish OS ships is now on the Language page - 15 new:
  Spanish, Italian, Portuguese, Dutch, Polish, Turkish, Danish, Norwegian,
  Czech, Greek, Estonian, Latvian, Lithuanian, Slovenian, Chinese
- 223 short-UI keys per new language; the dozen long technical paragraphs
  deliberately fall back to English until native speakers contribute -
  corrections are one-line edits in qml/translations.js
- 22 languages total, all parity-checked against the English base

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.132-1
- Five more languages join, each with the complete 235-key catalog:
  Svenska, Magyar, Russkij (Russian), Francais - and, honoris
  causa, Latina. The Language page now offers eight choices with
  instant switching; every dictionary passed an automatic key-
  parity check against the English base, so nothing can fall
  through except to the English fallback by design. Native-speaker
  corrections are one-line edits in qml/translations.js and very
  welcome

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.131-1
- "This message was deleted" is translated at display time (the
  backend writes the English sentinel into stored text and does not
  know the UI language; a display-level mapper handles the bubble,
  the chat list preview, favorites/archive rows and reply quotes) -
  along with the remaining in-bubble bits: "You:" in previews, the
  "edited" marker, the Forwarded/Pinned/Mentioned-you badges, poll
  and document fallback labels
- Finnish (Suomi) joins as the third language: the complete catalog
  - all ~250 keys - translated, selectable on the Language page,
  switching instantly like the others

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.130-1
- Translation completed - the final surfaces: both chat pull-down
  menus (history, search, locations, disappearing messages,
  clear/delete, polls, block, calls, send file/image), the message
  long-press menu (reply, edit, delete for everyone, copy, forward,
  join group, call back), media labels (location, tap to download),
  the empty chat state, the pairing screen (start pairing, tap code
  to copy, linked-devices walkthrough, re-pair and reset options),
  the whole group management page (participants, invite links, join
  requests with approve/reject, descriptions, community groups),
  create group, forward-to, disappearing messages, send/share
  location dialogs and the discover channels page - about 75 new
  keys. The app is now fully bilingual; technical error bodies and
  copyable commands remain English by policy

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.129-1
- Startup status line translated: starting backend, connecting,
  reconnecting, pairing prompts, logged out, action required and
  the generic fallbacks. Actual error DETAILS (lastError bodies
  with technical content) stay English by policy - they are meant
  to be copied into support threads verbatim

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.128-1
- The last two English paragraphs in the Sailjail section are
  translated: the permissions intro and the live status block
  (granted / not granted / included in Microphone / ear-speaker
  readiness per permission)

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.127-1
- Translation stage B3, settings completed: the background daemon
  explanation, the whole Sailjail permissions section (header, long
  explanation, all nine copy-button labels including the audio+
  sensors fine print), the Profile page and the Create poll dialog.
  The copied commands themselves stay English by policy - only the
  button labels translate

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.126-1
- Translation stage B2, the big one: the entire main Settings page
  (address book, chat input, gallery visibility, notifications,
  daemon status line, automatic downloads with Always/Wi-Fi
  only/Never, storage), the complete Status page (posting, viewing,
  captions, empty states), the complete Channels page (list,
  unfollow, discover, join dialog with link hint), the chat pulley
  channel entries, the New Chat page and the empty chat list -
  about 60 new catalog keys in English and German. Command-copy
  strings remain untranslated by policy

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.125-1
- Translation stage B1: both pull-down menus (all ten entries), all
  long-press menus (favorites/mute/archive on every surface), the
  Favorites and Archive pages including their empty-state hints,
  and the contact info page are translated now
- Catalog policy documented in the file header: technical command
  strings (curl/systemctl/install lines in error messages) are
  deliberately NOT translated - they must stay copy-pastable

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.124-1
- White-screen hotfix for 0.9.123: QML requires property names to
  start with a lowercase letter - the translation dictionary was
  bound as "property var L", which is a load-time error that kills
  the entire QML file. The property is "loc" now. Rulebook, again:
  a new construct gets its naming rules checked before it ships

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.123-1
- Translation infrastructure (concept credit: rdomschk on
  OpenRepos): a central catalog file qml/translations.js with an
  English base and a growing German dictionary - missing keys fall
  back to English automatically, translators touch exactly one
  file that survives app updates. A Language entry in Settings
  opens its own page: System default, English, Deutsch - switching
  applies INSTANTLY, no restart (property bindings re-evaluate),
  which is why this beats Qt's qsTr/lrelease here: a runtime
  language override would need a C++ translator our pure-QML stack
  does not have
- First translated surfaces: the settings entries, the whole More
  settings page and the bottom navigation bar

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.122-1
- Contact info page (OpenRepos request): every chat carries an
  attached page now - the glow dot at the top right, or a left
  swipe, opens the profile with the picture in big view (the
  avatar cache already holds the full-size image), the phone
  number and the about text for contacts, topic and participant
  count for groups (new /userinfo backend endpoint)

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.121-1
- Both navigation aids are optional now (OpenRepos request from a
  list-view purist): "Top view switcher" and "Bottom navigation
  bar" can be disabled in More settings, both default to on so
  nothing changes unless you want it to; the swipe gestures work
  regardless

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.120-1
- View switcher nudged left (field iteration with all six column
  buttons): the invisible left spacer shrinks from medium to
  extra-small, moving the whole row away from the Status glow on
  the right - there is more room on the left now that the row is
  wider

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.119-1
- The top view switcher offers all column counts now: list, 2, 3,
  4, 5 and 6 - matching the full range from More settings

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.118-1
- View switcher shifted right via an invisible left spacer (field
  iteration: compacting alone did not move the hamburger far enough
  out of the Favorites swipe zone) - the group's centre moves by
  half the spacer width, keeping "4" away from the Status glow on
  the right

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.117-1
- View switcher compacted toward the centre (field find: the list
  glyph sat close enough to the left edge to trigger the Favorites
  peek, and the right edge belongs to the Status glow): narrower
  buttons and tighter spacing keep the group clear of both swipe
  indicator zones

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.117-1
- View switcher is right-aligned now: centered, the list glyph sat
  far enough left that sloppy taps turned into the back-swipe
  gesture and landed on Favorites

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.116-1
- Bottom navigation bar on the main page (OpenRepos idea): one-tap
  access to Archive, Favorites and Status in both view modes; the
  swipe gestures stay unchanged and "Chats" marks the current
  location. Plain text buttons by design - Sailfish theme icon
  names vary between OS versions and an invisible button is worse
  than a written one
- View switcher at the top of both views: list or grid with 2/3/4
  columns, one tap, same preferences as More settings (where 5 and
  6 columns remain available); the active choice is highlighted

* Tue Jul 21 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.115-1
- Tap-to-open from a closed app works for the first time (OpenRepos
  report + local reproduction): sailjaild wraps the ExecDBus line in
  invoker, and the silica booster dlopens its target - sailjail is a
  plain executable and not boostable ("cannot dynamically load
  executable", exit 1 on every activation since 0.9.87). ExecDBus is
  now the bare boostable command (sailfish-qml harbour-whatsapp);
  sandboxing still applies through the launcher integration, same as
  an icon start. %post migrates existing desktop files by replacing
  any old ExecDBus line

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.114-1
- Archive page has its long-press menu too: Unarchive, Mute/Unmute
  and the favorites toggle, with native displacement - completing
  long-press parity across chat list, grid, Favorites and Archive

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.113-1
- Grid long-press menu displaces the tiles now: the grid is rebuilt
  as a list of tile ROWS (GridView cannot displace - the effect
  comes from growing ListItem delegates), so opening the menu on a
  tile pushes the following rows apart natively, exactly like the
  chat list. Same actions, per-tile long press
- Favorites page has a long-press menu: Remove from favorites,
  Mute/Unmute, Archive - with native displacement as well

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.112-1
- Grid view has a long-press menu now (one shared ContextMenu for
  all tiles, opening below the pressed row): the same actions as the
  list - favorites, mute, archive
- Both views name the favorites concept directly: the pin entry is
  "Add to favorites" / "Remove from favorites" (pinning IS the
  favorites mechanism, synced to other devices; pinned chats appear
  on the right-swipe Favorites page)

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.111-1
- Root-trick startup fixed (field find: app started at Archive with
  two black orphan pages behind it): initialPage is applied
  asynchronously, so pushing the stack in the window's onCompleted
  raced it and Archive ended up ON TOP of the orphaned pushes. The
  stack is now built on the root page's own first activation, where
  the root is guaranteed to be in place - the app starts on the
  chat list again, right-swipe reaches Favorites and Archive

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.110-1
- Right-swipe navigation (the root-page trick): the page stack now
  starts as Archive -> Favorites -> chat list, pushed through
  immediately at launch - so swiping right from the chat list opens
  Favorites and swiping again opens Archive, exactly the requested
  direction, while Status stays one swipe to the left. The pages
  are persistent items because Silica destroys component pages on
  back-swipe; each page re-attaches its forward neighbour so the
  cycle works indefinitely. The 0.9.108 left-side chain is removed
- Tiles per row extends to 5 and 6 columns

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.109-1
- Tiles per row is configurable (OpenRepos idea): 2, 3 or 4 columns
  for the chat grid view, selectable in More settings, persisted
  like every other preference. The sub-page talks only to root
  properties and setPref - the 0.9.106 lesson, now policy

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.108-1
- Favorites and Archive pages (OpenRepos idea), for both view
  modes: the swipe chain behind the main view is now Status (one
  swipe, as before), Favorites (two) and Archive (three). Favorites
  shows the pinned chats (long-press Pin, synced to other devices),
  Archive collects the archived ones as a proper page instead of
  only dimmed list entries; both open chats directly and show
  unread badges. Swiping right is Silica's back navigation, so the
  chain lives on the left - the requested right-swipe direction is
  not possible on Sailfish

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.107-1
- Grid view no longer hides startup and error states (field
  question: "no loading on the grid screen - are errors hidden
  too?" - they were): the list header carries the busy indicator,
  pairing UI, secrets/relogin recovery and the tap-to-copy error
  text, and the grid covered all of it. The grid now only takes
  over the healthy connected state; starting, pairing and every
  error state automatically shows the list with its full status
  header. Notices (e.g. "copied to clipboard") appear in a small
  grid header meanwhile

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.106-1
- Grid view setting truly persists now: the More-settings switch
  touched downloadPrefs, a property that belongs to the main
  settings PAGE - from the root-declared More-settings page that
  access threw a silent ReferenceError after the visual toggle and
  before setPref ever ran (diagnosed via curl: the key never
  reached the backend). The switch now toggles and saves directly;
  the 0.9.105 retry hardening stays as a genuine improvement it
  turned out not to be the culprit of

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.105-1
- Settings saved right after app start persist reliably now (field
  find via the grid view toggle "not staying"): the backend answers
  503 "starting" while its encrypted stores are still loading, which
  can take several seconds after a launch - and setPref retried
  exactly once after 1.5s, so the UI showed the toggled switch while
  the save quietly evaporated. setPref now retries up to ten times
  while the backend reports starting, and only then complains

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.104-1
- Grid view carries the full pull-down menu now: the first version
  had only Logout and Reload, which locked the user out of Settings
  (and Search, Profile, Channels, New chat/group, Join via link,
  Mark all as read) while grid mode was active - including the very
  switch to turn grid mode off again

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.103-1
- More settings: a second settings page for less central options,
  reachable via "More settings" on the main settings page
- Chat grid view (OpenRepos request), first resident of that page:
  chats as tiles, three per row, with the avatar as tile background,
  the name on a dark band at the bottom and the unread badge in the
  corner; archived chats are dimmed. Pull-down keeps Logout and
  Reload; the long-press menu (pin, mute, archive) stays available
  in the classic list view, which remains the default

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.102-1
- White-screen hotfix for 0.9.101: the five-line input cap used
  FontMetrics, a type that requires QtQuick 2.4 while the app
  imports QtQuick 2.0 - the unknown type killed the entire QML load.
  The cap now derives the line height from font.pixelSize (x1.4),
  no new types, same five-line behaviour at any text size

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.101-1
- The growing message input stops at about five lines (OpenRepos
  follow-up: long texts filled the whole screen) - beyond that the
  content scrolls inside the field; the cap follows the actual font
  metrics, so it stays five lines at any text size

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.100-1
- Multi-line message input (OpenRepos request): the chat input is a
  growing TextArea now - Enter inserts a new line by default and
  sending happens via the button, like the native Messages app. For
  the old behaviour there is an opt-in "Send by Enter" switch in
  Settings (default off); the enter key icon reflects the mode

* Mon Jul 20 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.99-1
- The gstreamer1.0-tools dependency is aarch64-only now: on older
  armv7hl/i486 devices (XA2 field report: "Error during install")
  the package can be missing from the configured repos, and a hard
  Requires blocked the entire installation. On those architectures
  the app installs cleanly again; if the recorder is absent, voice
  recording explains the exact one-line install command at runtime
  (the 0.9.88 fallback chain) instead of the store refusing upfront

* Sun Jul 19 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.98-1
- Notifications carry x-nemo-item-count with the real per-chat
  count (OpenRepos report: switcher badge patch always showed 1) -
  badge patches sum item counts instead of counting entries

* Sun Jul 19 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.97-1
- backend.log is trimmed to the last 128 KB at startup once it
  exceeds 512 KB (field report: 600 KB and growing) - deleting it
  manually remains safe at any time
- The "file is not a database" startup error now prints its own
  remedy into the log: delete ~/.local/share/harbour/harbour-whatsapp
  (NOT the unused legacy path without /harbour/) and pair again -
  exactly the guidance whose absence cost a three-comment support
  round. Message edit handling itself already exists (text, extended
  text, image/video captions, with a guaranteed log line per edit)

* Sat Jul 18 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.97-1
- Message edits (OpenRepos report): the receive pipeline existed
  end to end (backend replaces text and sets the edited flag, the
  chat shows "edited" next to the time) - but the edit handler
  ignored the update result and logged nothing, so a non-matching
  message ID vanished without a trace. Every received edit now
  leaves a log line (found or not, or unhandled shape), and edited
  image/video captions are extracted too. If the reported case
  recurs, the backend log will name the reason verbatim

* Sat Jul 18 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.96-1
- Startup race fixed (found through a field log): the installed-
  version query ran in the root Component.onCompleted while
  importModule was still in flight - fast devices won the race,
  slower ones (Xperia 10 III report) logged a scary NameError before
  the import finished, and 0.9.94 instantly painted it as "module
  failed to load". The query now runs inside the import callback,
  onError only collects while the import is pending, and the 6s
  watchdog is the sole judge - showing the LAST real error verbatim
  (tap to copy) only if the import truly never completes

* Sat Jul 18 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.95-1
- The startup/pairing error message is tappable now and copies
  itself to the clipboard ("tap to copy") - multi-line import
  tracebacks travel into a bug report with one tap instead of
  being retyped from a screenshot

* Sat Jul 18 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.94-1
- Self-diagnosing startup for a field report (Xperia 10 III, latest
  version: python module fails to import, so the backend never
  starts): the import traceback was only ever printed to the
  console no user sees. The first Python error before a successful
  import is now shown verbatim on the error screen with a "please
  report this text" note, and an import watchdog names the module
  and asks for the OS version if no error surfaces at all. The
  module itself audits clean for older-Python syntax - the next
  report will contain the actual reason on-screen

* Sat Jul 18 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.93-1
- Daemon lifecycle hardened for switching at will: running the
  disable command in the Terminal while the app was open killed the
  daemon the GUI was attached to and left the app backend-less until
  restart (only the notifications-toggle path respawned). The GUI
  now detects total backend loss - three consecutive failed status
  cycles including fruitless port rescans - and respawns a child
  backend by itself; the counter resets on every successful status
  so sporadic hiccups never accumulate into a spurious respawn.
  Enable/disable/re-enable now cycles cleanly in every order and
  from either place (settings toggle or Terminal)

* Sat Jul 18 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.92-1
- Update-lag detection for daemon users: jails and binaries are
  composed at process start, and RPM does not restart user units -
  so a running daemon silently stays on the old version after every
  app update. The app now knows its installed version (packaged
  VERSION file) and, when the daemon it talks to reports a different
  one, the daemon status line shows a warning and a tap-to-copy
  restart command appears. Without the daemon nothing changes: the
  child backend dies with the app and every app start is fully
  current automatically

* Sat Jul 18 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.92-1
- Update-lag detection for the daemon: jails and binaries are
  composed at process start, and RPM updates never restart user
  units - so a running daemon silently keeps serving the OLD version
  after every update (yesterday's lesson). The app now ships its
  version as a file, compares it against the version of the backend
  it talks to, and when the running daemon is older, the settings
  show a warning plus a tap-to-copy restart command. Enabling the
  daemon itself needs no desktop rewriting: the daemon desktop file
  is plainly packaged (never user-modified, replaced on every
  update) and its jail is composed fresh at daemon start

* Fri Jul 17 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.91-1
- App launches from the icon again: X-Maemo-Service in the MAIN
  desktop file makes lipstick "launch" the app via a D-Bus call
  instead of Exec - which goes nowhere on icon tap (manual sailjail
  launch worked, proving the file parsed fine). The key now lives
  ONLY in the daemon desktop file (NoDisplay, never icon-launched),
  and %post removes it from installed main desktop files
- Reply architecture split by mode: the daemon owns
  harbour.whatsapp.backend and answers directly (app closed); while
  the app runs, the notification reply targets the GUI's own bus
  name (replyFromNotification), which sends via the backend and
  closes the notification - no bus name needed in the child jail

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
