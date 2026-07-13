# harbour-whatsapp

Native WhatsApp client for Sailfish OS using the
[whatsmeow](https://github.com/tulir/whatsmeow) library.

Features: full media support (images, videos, audio, documents, stickers)
with per-type automatic download policies (always / Wi-Fi only / never),
on-demand history sync ("Load older messages"), reactions, replies/quotes,
edit and delete for everyone, locations (opens in Pure Maps via geo: URI),
group management, channels (newsletters), communities, missed-call log with
GSM call-back, global and in-chat full-text search, profile editing, and a
storage manager.

## How this was made

This app was developed with the help of a large language model ("AI",
Claude by Anthropic). The architecture decisions, testing on real
hardware, bug reports and the choices about what to build were made by
me; the model was used as a coding assistant. Every release is tested
on-device before publishing. Issues and patches are welcome regardless
of how any particular line came to exist.

## Permissions (important!)

The app ships with **minimal Sailjail permissions** (`Internet;Secrets;`).
Everything else is opt-in, because Sailfish OS has no runtime permission
dialogs and a sandboxed app cannot edit its own desktop file:

- **Contacts** (`Contacts;Privileged;`) — enables address book suggestions
  on the New chat page and in group creation. `Privileged` is required
  because the non-privileged contacts database is empty on many
  installations (same approach as e.g. Fernschreiber).
- **Media storage** (`UserDirs;MediaIndexing;RemovableMedia;`) — stores
  received media under `~/Pictures/WhatsApp` etc. (visible in Gallery) and
  makes the system image/file pickers work for sending. Without it, media
  is stored inside the app's private data folder and the pickers appear
  empty — the app itself stays fully functional.

Open **Settings** inside the app: it shows the current permission status
and offers tap-to-copy `devel-su` commands to grant or revoke each block.
The commands edit only the `Permissions=` line, are idempotent and
order-independent, e.g. granting contacts:

```bash
devel-su sed -i '/^Permissions=/{s/;*$/;/; /Contacts;/!s/$/Contacts;/; /Privileged;/!s/$/Privileged;/}' /usr/share/applications/harbour-whatsapp.desktop
```

Restart the app afterwards. The desktop file is packaged as
`%config(noreplace)`, so app updates keep your permission choice.

## Requirements

- Sailfish OS device (aarch64 or armv7hl)
- For building: Go 1.24+ and a C cross-compiler (SQLCipher is compiled in
  via CGO; no runtime sqlcipher dependency)

## Building on a desktop Linux machine (recommended)

Produces statically linked backends for both architectures and the RPMs,
without needing the Sailfish SDK:

```bash
# 1) Toolchain (example: Arch Linux / EndeavourOS)
sudo pacman -S go aarch64-linux-gnu-gcc arm-none-eabi-gcc rpm-tools
# Debian/Ubuntu instead:
#   sudo apt install golang gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf rpm

git clone https://github.com/smatkovi/harbour-whatsapp
cd harbour-whatsapp/backend

# 2) Backend, statically linked, version stamped from the spec
VERSION=$(grep '^Version:' ../rpm/harbour-whatsapp.spec | awk '{print $2}')

CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC=aarch64-linux-gnu-gcc \
  go build -tags netgo,osusergo \
  -ldflags "-s -w -X main.version=$VERSION -linkmode external -extldflags '-static'" \
  -o wa-backend-aarch64 .

CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=7 CC=arm-linux-gnueabihf-gcc \
  go build -tags netgo,osusergo \
  -ldflags "-s -w -X main.version=$VERSION -linkmode external -extldflags '-static'" \
  -o wa-backend-armv7 .

# 3) RPMs
cd ..
for arch in aarch64 armv7hl; do
  B=~/rpmbuild-wa; rm -rf $B
  mkdir -p $B/BUILD $B/RPMS $B/SOURCES $B/SPECS
  if [ $arch = aarch64 ]; then cp backend/wa-backend-aarch64 $B/SOURCES/wa-backend
  else cp backend/wa-backend-armv7 $B/SOURCES/wa-backend; fi
  cp -r qml start_backend.py harbour-whatsapp.desktop icons $B/SOURCES/
  cp rpm/harbour-whatsapp.spec $B/SPECS/
  rpmbuild --define "_topdir $B" --define "_build_id_links none" \
    -bb --target $arch-meego-linux $B/SPECS/harbour-whatsapp.spec
  cp $B/RPMS/$arch/*.rpm .
done
```

Notes:
- `-X main.version=` must match the spec version — the launcher compares
  it against the installed VERSION file to replace stale backends after
  updates.
- The static build embeds SQLCipher (bundled C sources of
  mutecomm/go-sqlcipher), so the RPM has no sqlcipher dependency.
- The `dlopen` linker warning from sqlite3.c is harmless.

## Building on the Sailfish OS device

```bash
devel-su pkcon install rpm-build
# Install Go >= 1.24 (https://go.dev/dl/, linux-arm64 tarball)
./build.sh
devel-su rpm -U --force ~/rpmbuild/RPMS/aarch64/harbour-whatsapp-*.rpm
```

## Structure
```
harbour-whatsapp/
├── backend/           # Go backend (whatsmeow, SQLCipher, HTTP API)
│   ├── main.go
│   ├── secrets.go     # Sailfish Secrets key storage
│   └── go.mod
├── qml/               # QML/Silica UI
│   └── harbour-whatsapp.qml
├── icons/hicolor/     # App icons
├── rpm/               # RPM spec (version, changelog)
├── harbour-whatsapp.desktop
├── start_backend.py   # Launcher: version check, port handling, logging
├── build.sh
└── README.md
```

## License

MIT
