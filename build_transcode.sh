#!/bin/zsh
# Builds Phantom Transcode.app from the SwiftPM package.
# A dedicated .cine → ProRes/H.264/HEVC converter (GPU debayer + hardware
# encode), separate from Phantom Control.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product PhantomTranscode

# Generate the app icon once (original art: lens ring + play triangle).
if [ ! -f AppIcon.icns ]; then
    swift make_icon.swift /tmp/pt_icon_1024.png
    ICONSET=/tmp/PhantomTranscode.iconset
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for sz in 16 32 64 128 256 512; do
        sips -z $sz $sz /tmp/pt_icon_1024.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        d=$((sz*2)); sips -z $d $d /tmp/pt_icon_1024.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    cp /tmp/pt_icon_1024.png "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o AppIcon.icns
fi

APP="Phantom Transcode.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/PhantomTranscode" "$APP/Contents/MacOS/Phantom Transcode"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Phantom Transcode</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.bleckley.phantomtranscode</string>
    <key>CFBundleName</key>
    <string>Phantom Transcode</string>
    <key>CFBundleDisplayName</key>
    <string>Phantom Transcode</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Vision Research Cine</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>cine</string></array>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Stable identity keeps macOS approvals across rebuilds.
if security find-identity -p codesigning -v 2>/dev/null | grep -q "Phantom Control Dev"; then
    codesign --force --sign "Phantom Control Dev" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $PWD/$APP"
