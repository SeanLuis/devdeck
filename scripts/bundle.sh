#!/bin/zsh
# Builds DevDeck.app (release), signs it ad-hoc and installs it to ~/Applications.
set -euo pipefail
cd "${0:A:h}/.."
APP=build/DevDeck.app
swift build -c release -debug-info-format none
BIN=$(swift build -c release -debug-info-format none --show-bin-path)/DevDeck

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset
cp "$BIN" "$APP/Contents/MacOS/DevDeck"

# Icon
"$BIN" --render-icon build/icon-1024.png
for size in 16 32 128 256 512; do
  sips -z $size $size build/icon-1024.png --out build/AppIcon.iconset/icon_${size}x${size}.png >/dev/null
  sips -z $((size*2)) $((size*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${size}x${size}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

VERSION=$(git describe --tags --always 2>/dev/null || echo 0.1.0)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DevDeck</string>
  <key>CFBundleDisplayName</key><string>DevDeck</string>
  <key>CFBundleIdentifier</key><string>dev.devdeck.app</string>
  <key>CFBundleExecutable</key><string>DevDeck</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local developer tool</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/DevDeck.app"
cp -R "$APP" "$HOME/Applications/DevDeck.app"
echo "Installed: $HOME/Applications/DevDeck.app"
