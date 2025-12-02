Name:       harbour-whatsapp
Version:    0.1.1
Release:    1
Summary:    WhatsApp Client for Sailfish OS
License:    MIT
Group:      Applications/Communications

%define debug_package %{nil}
%define __strip /bin/true
%define __spec_install_post %{nil}

Requires:   sailfishsilica-qt5
Requires:   nemo-qml-plugin-contacts-qt5
Requires:   pyotherside-qml-plugin-python3-qt5
Requires:   sqlcipher

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
