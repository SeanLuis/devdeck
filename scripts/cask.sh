#!/bin/bash
# Points the Homebrew cask at a published release: scripts/cask.sh 0.1.6
# Downloads that release's DevDeck.zip, takes its checksum and rewrites Casks/devdeck.rb.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/cask.sh <version>}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/DevDeck.zip" "https://github.com/SeanLuis/devdeck/releases/download/v$VERSION/DevDeck.zip"
SHA="$(shasum -a 256 "$TMP/DevDeck.zip" | cut -d' ' -f1)"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/devdeck.rb
echo "Casks/devdeck.rb -> $VERSION ($SHA)"
