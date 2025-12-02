#!/bin/bash
set -e

echo "=== Building WhatsApp for Sailfish OS ==="

SRCDIR="$(pwd)"
BUILDDIR="$HOME/rpmbuild"

# Check if wa-backend exists, if not build it
if [ ! -f "$SRCDIR/wa-backend" ]; then
    echo "Building backend..."
    cd backend
    CGO_CFLAGS="-I/usr/include/sqlcipher" \
    CGO_LDFLAGS="-L/usr/lib64 -lsqlcipher" \
    /usr/local/go/bin/go build -o ../wa-backend .
    cd ..
    echo "✅ Backend built"
fi

# Build RPM
echo "Building RPM..."

rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR/BUILD"
mkdir -p "$BUILDDIR/RPMS"
mkdir -p "$BUILDDIR/SOURCES"
mkdir -p "$BUILDDIR/SPECS"
mkdir -p "$BUILDDIR/SRPMS"

cp -r "$SRCDIR/qml" "$BUILDDIR/SOURCES/"
cp "$SRCDIR/wa-backend" "$BUILDDIR/SOURCES/"
cp "$SRCDIR/start_backend.py" "$BUILDDIR/SOURCES/"
cp "$SRCDIR/harbour-whatsapp.desktop" "$BUILDDIR/SOURCES/"
cp -r "$SRCDIR/icons" "$BUILDDIR/SOURCES/"
cp "$SRCDIR/rpm/harbour-whatsapp.spec" "$BUILDDIR/SPECS/"

cd "$BUILDDIR"
rpmbuild -bb SPECS/harbour-whatsapp.spec

echo ""
echo "✅ RPM built:"
find RPMS -name "*.rpm"
