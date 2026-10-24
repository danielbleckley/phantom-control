#!/bin/zsh
# Builds Phantom Control.app from the SwiftPM package.
set -e
cd "$(dirname "$0")"

# Serialize builds. Two builds racing on `rm -rf .app` + cp + codesign can leave
# a corrupt signature → macOS kills the app on launch with "Code Signature
# Invalid" (EXC_BAD_ACCESS / CODESIGNING Invalid Page). The lock prevents it.
LOCK="/tmp/phantomcontrol_build.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "ERROR: another build is in progress (lock: $LOCK). Aborting to avoid corrupting the code signature." >&2
    exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

CONFIG="${1:-release}"

# Versioning. VERSION holds the marketing version (bump by hand, e.g. 0.3.1).
# .build_number auto-increments every build so each one is uniquely identifiable
# — testers quote "0.3.0 (build 42)" and you know exactly which binary they have.
SHORT_VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
BUILD_NUMBER=$(( $(cat .build_number 2>/dev/null || echo 0) + 1 ))
echo "$BUILD_NUMBER" > .build_number
echo "Building Phantom Control $SHORT_VERSION (build $BUILD_NUMBER)"

# UNIVERSAL=1 builds one binary that runs natively on BOTH Apple Silicon and
# Intel Macs (verified: the Intel slice renders byte-identical under Rosetta).
# Multi-arch SwiftPM builds need full Xcode's build service, not just the
# Command Line Tools — point DEVELOPER_DIR at Xcode without touching
# xcode-select. Day-to-day dev builds stay native-only (half the build time).
BUILT_BIN=".build/$CONFIG/PhantomApp"
if [ "${UNIVERSAL:-0}" = "1" ]; then
    XC="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
    if [ -n "$XC" ]; then
        echo "  · universal build (arm64 + x86_64) via $XC"
        DEVELOPER_DIR="$XC/Contents/Developer" \
            swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product PhantomApp
        BUILT_BIN=".build/apple/Products/${(C)CONFIG}/PhantomApp"
    else
        echo "  · WARNING: UNIVERSAL=1 but no Xcode found — building native-only" >&2
        swift build -c "$CONFIG" --product PhantomApp
    fi
else
    swift build -c "$CONFIG" --product PhantomApp
fi

APP="Phantom Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT_BIN" "$APP/Contents/MacOS/Phantom Control"
lipo -info "$APP/Contents/MacOS/Phantom Control" 2>/dev/null | sed 's/^/  · /'

# Bundle the user guide so Help ▸ Phantom Control Help can open it.
[ -f HELP.md ] && cp HELP.md "$APP/Contents/Resources/HELP.md"
# Bundle the changelog so Help ▸ Release Notes can open it.
[ -f CHANGELOG.md ] && cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Phantom Control</string>
    <key>CFBundleIdentifier</key>
    <string>com.bleckley.phantomcontrol</string>
    <key>CFBundleName</key>
    <string>Phantom Control</string>
    <key>CFBundleDisplayName</key>
    <string>Phantom Control</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>Phantom Control uses your USB-C SDI capture device as the camera monitor.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Phantom Control talks to Phantom cameras on your local Ethernet network.</string>
</dict>
</plist>
PLIST

# App icon: drop a 1024x1024 AppIcon.png in this folder and it flows everywhere —
# the macOS .icns (Dock/Spotlight/Finder) and the phone home-screen touch icon.
if [ -f AppIcon.png ]; then
    ISET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ISET"
    for s in 16 32 128 256 512; do
        sips -z $s $s AppIcon.png --out "$ISET/icon_${s}x${s}.png" >/dev/null 2>&1
        d=$((s * 2)); sips -z $d $d AppIcon.png --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ISET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
        && echo "  · bundled AppIcon.icns"
    sips -z 180 180 AppIcon.png --out "$APP/Contents/Resources/apple-touch-icon.png" >/dev/null 2>&1
else
    echo "  · (no AppIcon.png found — using the default icon)"
fi

# Strip local/internal symbols so the shipped binary stops handing out a
# readable map of every function and parameter name (downloadMagTake,
# MetalDebayer.render, …). `-x` removes only NON-global symbols — everything
# the dynamic linker actually needs is kept, so the app runs identically; it's
# just far harder to reverse-engineer. MUST run before codesign (stripping
# invalidates a signature). The un-stripped copy stays in .build/ for
# symbolicating crash logs if ever needed.
BIN="$APP/Contents/MacOS/Phantom Control"
SYMS_BEFORE=$(nm "$BIN" 2>/dev/null | wc -l | tr -d ' ')
strip -x "$BIN"
SYMS_AFTER=$(nm "$BIN" 2>/dev/null | wc -l | tr -d ' ')
echo "  · stripped internal symbols: $SYMS_BEFORE → $SYMS_AFTER"

# Stable identity keeps macOS camera/network approvals across rebuilds.
if security find-identity -p codesigning -v 2>/dev/null | grep -q "Phantom Control Dev"; then
    codesign --force --sign "Phantom Control Dev" "$APP"
else
    codesign --force --sign - "$APP"
fi

# Catch a bad/partial signature here, instead of macOS killing the app on launch.
if ! codesign --verify --strict "$APP" 2>/dev/null; then
    echo "ERROR: code signature failed verification — the app would crash on launch. Not shipping." >&2
    exit 1
fi
echo "Built $PWD/$APP"
