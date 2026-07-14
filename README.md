# harbour-whatsapp

Native WhatsApp client for Sailfish OS using whatsmeow library.

## Requirements

- Sailfish OS 4.5+ device (tested on 5.1, Xperia 10 V)
- For building: Go **1.25 or newer** (the whatsmeow dependency requires it)

## Installing (prebuilt RPM)

Download the RPM for your architecture (aarch64 for most modern devices,
armv7hl for older 32-bit ones) from OpenRepos or the GitHub releases, then:

```bash
devel-su rpm -U ~/Downloads/harbour-whatsapp-*.rpm
```

On first start, pair the app as a linked device: WhatsApp on your phone →
Settings → Linked devices → Link with phone number, and enter the pairing
code the app shows. The app ships with minimal sandbox permissions
(Internet, Secrets); optional features are enabled by copy-paste commands
found in the app's Settings page:
- **Media storage** access (save/pick files outside the sandbox)
- **Location** (send your position / share live location)
- **Contacts** (address book suggestions, opt-in inside the app as well)

Encryption of the local database strictly requires Sailfish Secrets - the
app refuses to run unencrypted and will guide you through a reset if an
old unencrypted database is found.

## Building from source

### A) On the Sailfish device itself

Go 1.25+ is not in the Jolla repos, but community repositories carry it.
With the Rikudou_Sennin OpenRepos repository enabled (via Storeman):

```bash
# Toolchain + build dependencies
devel-su zypper in --repo openrepos-Rikudou_Sennin go
devel-su pkcon install gcc sqlcipher-devel rpm-build

git clone https://github.com/smatkovi/harbour-whatsapp.git
cd harbour-whatsapp
./build.sh

devel-su rpm -U ~/rpmbuild/RPMS/$(uname -m)/harbour-whatsapp-*.rpm
```

This builds the backend dynamically against the device's SQLCipher.

### B) Cross-compiling on a Linux desktop (recommended)

Produces fully static backend binaries - no runtime dependencies on the
device beyond a stock Sailfish OS:

```bash
# Debian/Ubuntu example
sudo apt install golang gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf rpm

git clone https://github.com/smatkovi/harbour-whatsapp.git
cd harbour-whatsapp/backend

VERSION=$(grep '^Version:' ../rpm/harbour-whatsapp.spec | awk '{print $2}')

# aarch64 (64-bit devices)
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC=aarch64-linux-gnu-gcc \
  go build -tags netgo,osusergo \
  -ldflags "-s -w -X main.version=$VERSION -linkmode external -extldflags '-static'" \
  -o wa-backend .

# armv7hl (32-bit devices): GOARCH=arm GOARM=7 CC=arm-linux-gnueabihf-gcc

# Then package (see rpm/harbour-whatsapp.spec; sources are the wa-backend
# binary plus qml/, start_backend.py, harbour-whatsapp.desktop, icons/)
```

The committed `go.sum` makes builds reproducible - a fresh clone compiles
without running `go mod tidy` first.

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
├── rpm/               # RPM spec
│   └── harbour-whatsapp.spec
├── harbour-whatsapp.desktop
├── build.sh
└── README.md
```

## License

MIT
