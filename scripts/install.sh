#!/bin/bash
# Builds Typ.app and installs it into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=.build/Typ.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Typ "$APP/Contents/MacOS/Typ"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/sensevoice_server.py "$APP/Contents/Resources/"
cp Resources/tray.png "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/tray@2x.png "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/logo.png "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/mushroom.png "$APP/Contents/Resources/" 2>/dev/null || true

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif [ ! -f build/AppIcon.icns ]; then
    rm -rf build/AppIcon.iconset
    swift scripts/make_icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
    cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# A stable local identity keeps macOS permissions (Accessibility, Input Monitoring) across rebuilds;
# ad-hoc signatures change every build and reset them.
IDENTITY=$(security find-identity -p codesigning | awk '/"Typ Local Signing"/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --identifier local.typ.app "$APP"
else
    echo "warning: 'Typ Local Signing' identity not found, signing ad-hoc (permissions reset on each rebuild)"
    codesign --force --sign - --identifier local.typ.app "$APP"
fi

pkill -x Typ 2>/dev/null || true
sleep 0.5
rm -rf /Applications/Typ.app
cp -R "$APP" /Applications/Typ.app
swift -e 'import AppKit; NSWorkspace.shared.setIcon(NSImage(contentsOfFile: "/Applications/Typ.app/Contents/Resources/AppIcon.icns"), forFile: "/Applications/Typ.app", options: [])' 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Typ.app 2>/dev/null || true
rm -rf "$APP"
echo "Installed /Applications/Typ.app"
