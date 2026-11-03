#!/bin/zsh
# Builds Hive.app and installs it to /Applications.
set -e
cd "$(dirname "$0")"

VERSION=2.1
BUILD=6
# Reverse-DNS identifier macOS uses for permissions and settings. Override with BUNDLE_ID=… ./build.sh
BUNDLE_ID=${BUNDLE_ID:-io.github.hive-terminal}

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift wurde nicht gefunden. Installiere die Entwicklerwerkzeuge mit:"
  echo "  xcode-select --install"
  echo "und starte ./build.sh danach erneut."
  exit 1
fi

echo "→ Baue Hive …"
swift build -c release
APP=build/Hive.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hive "$APP/Contents/MacOS/"

# App icon: render once from Scripts/make-icon.swift, then build all sizes into an .icns.
[ -f Resources/icon-1024.png ] || swift Scripts/make-icon.swift Resources/icon-1024.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hive</string>
  <key>CFBundleDisplayName</key><string>Hive</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Hive</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Claude-Sessions arbeiten mit Dateien auf deinem Schreibtisch.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Claude-Sessions arbeiten mit Dateien in deinen Dokumenten.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Claude-Sessions arbeiten mit Dateien in deinen Downloads.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Claude-Sessions arbeiten mit Dateien auf externen Laufwerken.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Claude-Sessions arbeiten mit Dateien auf Netzlaufwerken.</string>
  <key>NSAppleEventsUsageDescription</key><string>Claude-Sessions können andere Apps steuern, wenn du es verlangst.</string>
</dict>
</plist>
PLIST

# Sign with a stable local identity so macOS remembers granted permissions across rebuilds.
# If that is not possible, fall back to an ad-hoc signature (the app works, macOS just asks again after updates).
if IDENTITY=$(./Scripts/setup-signing.sh) && [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "Hinweis: Kein lokales Signatur-Zertifikat – signiere ad-hoc."
  codesign --force --deep --sign - "$APP"
fi

rm -rf /Applications/Hive.app
cp -R "$APP" /Applications/
echo "✓ Installiert: /Applications/Hive.app"

# Inside a Hive session, restarting the app would end this very session.
if [ -n "$HIVE" ]; then
  echo "Läuft innerhalb von Hive – bitte die App selbst neu starten (⌘Q, dann Hive öffnen)."
else
  pkill -f "Hive.app/Contents/MacOS/Hive" && sleep 1 || true
  open /Applications/Hive.app
fi
