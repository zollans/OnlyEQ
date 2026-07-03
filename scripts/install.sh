#!/bin/bash
# OnlyEQ installer — downloads the latest release, installs to /Applications,
# and clears the quarantine flag (the app is ad-hoc signed, not notarized,
# so this avoids the "unidentified developer" Gatekeeper block).
#
#   curl -fsSL https://raw.githubusercontent.com/zollans/OnlyEQ/main/scripts/install.sh | bash
set -euo pipefail

REPO="zollans/OnlyEQ"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching latest OnlyEQ release…"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -o '"browser_download_url": *"[^"]*OnlyEQ\.app\.zip"' \
      | grep -o 'https://[^"]*')
if [ -z "$URL" ]; then
  echo "Couldn't find a release download. See https://github.com/$REPO" >&2
  exit 1
fi

curl -fSL --progress-bar "$URL" -o "$TMP/OnlyEQ.app.zip"

echo "Installing to /Applications…"
ditto -x -k "$TMP/OnlyEQ.app.zip" "$TMP/extract"
pkill -x OnlyEQ 2>/dev/null || true
rm -rf /Applications/OnlyEQ.app
ditto "$TMP/extract/OnlyEQ.app" /Applications/OnlyEQ.app

# Not notarized: strip quarantine and re-sign ad hoc so Gatekeeper allows it.
xattr -dr com.apple.quarantine /Applications/OnlyEQ.app 2>/dev/null || true
codesign --force --deep --sign - /Applications/OnlyEQ.app >/dev/null 2>&1 || true

open /Applications/OnlyEQ.app
echo "✓ OnlyEQ installed — look for it in your menu bar."
echo "  First run: allow System Audio access when prompted (macOS 14.4+ required)."
