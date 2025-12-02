#!/bin/bash
set -e

echo "=== Building WhatsApp for Sailfish OS ==="

# Build Go backend
echo "Building backend..."
cd backend
CGO_CFLAGS="-I/usr/include/sqlcipher" \
CGO_LDFLAGS="-L/usr/lib64 -lsqlcipher" \
/usr/local/go/bin/go build -o ../wa-backend .
cd ..

echo "✅ Backend built"

# Build RPM
echo "Building RPM..."
SRCDIR="$(pwd)"
BUILDDIR="$HOME/rpmbuild"

rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR/BUILD"
mkdir -p "$BUILDDIR/RPMS"
mkdir -p "$BUILDDIR/SOURCES"
mkdir -p "$BUILDDIR/SPECS"
mkdir -p "$BUILDDIR/SRPMS"

cp -r qml "$BUILDDIR/SOURCES/"
cp wa-backend "$BUILDDIR/SOURCES/"
cp harbour-whatsapp.desktop "$BUILDDIR/SOURCES/"
cp -r systemd "$BUILDDIR/SOURCES/"
cp -r icons "$BUILDDIR/SOURCES/"
cp rpm/harbour-whatsapp.spec "$BUILDDIR/SPECS/"

cd "$BUILDDIR"
rpmbuild -bb SPECS/harbour-whatsapp.spec

echo ""
echo "✅ RPM built:"
find RPMS -name "*.rpm"
