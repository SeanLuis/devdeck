#!/bin/zsh
# Builds DevDeck.app (release), signs it and installs it to ~/Applications.
#
# Options (environment variables):
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   sign for distribution (hardened runtime + timestamp).
#                                                             Without it the app is signed ad-hoc, for local use.
#   UNIVERSAL=1      build for Apple silicon and Intel
#   SKIP_INSTALL=1   leave the app in build/ and do not copy it to ~/Applications
#   APP_VERSION=1.2.3
set -euo pipefail
cd "${0:A:h}/.."
APP=build/DevDeck.app
FLAGS=(-c release -debug-info-format none)
if [[ -n "${UNIVERSAL:-}" ]]; then FLAGS+=(--arch arm64 --arch x86_64); fi
swift build "${FLAGS[@]}"
BIN=$(swift build "${FLAGS[@]}" --show-bin-path)/DevDeck

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
# Version shown in the app: APP_VERSION, or the latest git tag, so a local build does not look older than the release.
# A build with commits after the last tag is ahead of that release: 0.1.2 + 3 commits → 0.1.3-dev,
# so the updater never offers a release that is older than what is installed.
if [[ -z "${APP_VERSION:-}" ]]; then
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
  if [[ -n "$LAST_TAG" ]]; then
    APP_VERSION="${LAST_TAG#v}"
    if [[ "$(git rev-list "$LAST_TAG"..HEAD --count 2>/dev/null)" != "0" ]]; then
      APP_VERSION="${APP_VERSION%.*}.$(( ${APP_VERSION##*.} + 1 ))-dev"
    fi
  fi
fi
: "${APP_VERSION:=0.1.0}"
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
  <key>CFBundleShortVersionString</key><string>${APP_VERSION:-0.1.0}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local developer tool</string>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Distribution: Developer ID, hardened runtime and a secure timestamp, as notarization requires.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict "$APP"
if [[ -n "${SKIP_INSTALL:-}" ]]; then
  echo "Built: $APP"
  exit 0
fi
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/DevDeck.app"
cp -R "$APP" "$HOME/Applications/DevDeck.app"
echo "Installed: $HOME/Applications/DevDeck.app"
