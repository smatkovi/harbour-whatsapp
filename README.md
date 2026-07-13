# harbour-whatsapp

Native WhatsApp client for Sailfish OS using whatsmeow library.

## Requirements

- Sailfish OS device
- Go 1.21+ (for building)
- SQLCipher development headers

## Building

### On Sailfish OS device:
```bash
# Install dependencies
devel-su pkcon install sqlcipher-devel rpm-build

# Install Go (if not installed)
# Download from https://go.dev/dl/

# Build
./build.sh
```

### Install
```bash
devel-su rpm -i ~/rpmbuild/RPMS/aarch64/harbour-whatsapp-*.rpm
```

## Structure
```
harbour-whatsapp-src/
├── backend/           # Go source files
│   ├── main.go
│   ├── secrets.go
│   ├── go.mod
│   └── go.sum
├── qml/               # QML UI
│   └── harbour-whatsapp.qml
├── icons/             # App icons
│   └── hicolor/
├── systemd/           # Systemd service
│   └── harbour-whatsapp-backend.service
├── rpm/               # RPM spec
│   └── harbour-whatsapp.spec
├── harbour-whatsapp.desktop
├── build.sh
└── README.md
```

## License

MIT
