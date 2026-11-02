#!/bin/bash
# Point the Homebrew cask in zollans/homebrew-tap at a published release.
# Run after `gh release create`: the checksum comes from GitHub's digest of
# the uploaded OnlyEQ.app.zip, so the cask matches what users download.
#
#   ./scripts/bump-cask.sh VERSION
set -euo pipefail

VERSION="${1:?usage: ./scripts/bump-cask.sh VERSION}"
DIGEST=$(gh release view "v$VERSION" -R zollans/OnlyEQ --json assets \
    --jq '.assets[] | select(.name == "OnlyEQ.app.zip") | .digest')
SHA256="${DIGEST#sha256:}"
if [ -z "$DIGEST" ] || [ "$SHA256" = "$DIGEST" ]; then
    echo "No sha256 digest for OnlyEQ.app.zip in release v$VERSION" >&2
    exit 1
fi

TAP="$(mktemp -d)"
trap 'rm -rf "$TAP"' EXIT
gh repo clone zollans/homebrew-tap "$TAP" -- --quiet
CASK="$TAP/Casks/onlyeq.rb"
sed -i '' -E \
    -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" \
    "$CASK"

if git -C "$TAP" diff --quiet; then
    echo "Cask already points at $VERSION"
    exit 0
fi
git -C "$TAP" commit -q -am "onlyeq $VERSION"
git -C "$TAP" push -q
echo "Updated zollans/homebrew-tap to OnlyEQ $VERSION ($SHA256)"
