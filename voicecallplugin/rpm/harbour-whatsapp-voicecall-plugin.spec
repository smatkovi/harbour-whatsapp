Name:       harbour-whatsapp-voicecall-plugin
Version:    0.9.287
Release:    1
Summary:    System call UI integration for harbour-whatsapp voice calls
License:    MIT
URL:        https://github.com/smatkovi/harbour-whatsapp
Source0:    %{name}-%{version}.tar.bz2
BuildRequires: pkgconfig(Qt5Core)
BuildRequires: pkgconfig(Qt5Network)
BuildRequires: voicecall-qt5
Requires:   voicecall-qt5
Requires:   harbour-whatsapp >= 0.9.287

%description
Plugin for voicecall-manager that registers WhatsApp voice calls carried by
harbour-whatsapp with the Sailfish call engine. Incoming and outgoing calls
then appear in the system call UI - including over the lock screen - and the
answer, decline, mute and speaker controls are relayed to the app's backend.
The plugin talks to the backend over its loopback HTTP API only; the app
itself stays sandboxed and unchanged.

%prep
%setup -q -n %{name}-%{version}

%build
%qmake5
make %{?_smp_mflags}

%install
%qmake5_install

%post
# voicecall-manager loads plugins at start only
/usr/bin/systemctl-user restart voicecall-manager.service || :

%postun
/usr/bin/systemctl-user restart voicecall-manager.service || :

%files
%defattr(-,root,root,-)
%{_libdir}/voicecall/plugins/libharbour-whatsapp-voicecall-plugin.so

%changelog
* Sat Aug 29 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.287-1
- Acknowledge each call handed to the call engine (/call/uiack) so the
  backend knows the system UI has it and does not need to ring itself.

* Sat Aug 29 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.284-1
- Changelog added for rpmlint; no functional change since 0.9.283.

* Sat Aug 29 2026 smatkovi <smatkovi@users.noreply.github.com> 0.9.283-1
- First release: registers harbour-whatsapp voice calls with
  voicecall-manager so the system call UI shows them over the lock screen
  and relays answer, decline, mute and speaker to the backend.
