#!/bin/bash
# Build OnlyEQ.app from the SwiftPM package (no Xcode required).
#   ./scripts/build-app.sh            debug build, host arch
#   ./scripts/build-app.sh release    universal (arm64 + x86_64) release build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/OnlyEQ.app"

if [ "$CONFIG" = "release" ]; then
    # CLT has no xcbuild, so multi-arch needs per-triple builds + lipo.
    swift build -c release --triple arm64-apple-macosx14.4
    swift build -c release --triple x86_64-apple-macosx14.4
    mkdir -p build
    lipo -create \
        .build/arm64-apple-macosx/release/OnlyEQ \
        .build/x86_64-apple-macosx/release/OnlyEQ \
        -output build/OnlyEQ-universal
    BIN="build/OnlyEQ-universal"
    RESOURCE_BUNDLE=".build/arm64-apple-macosx/release/OnlyEQ_OnlyEQ.bundle"
else
    swift build -c "$CONFIG"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/OnlyEQ"
    RESOURCE_BUNDLE="$(swift build -c "$CONFIG" --show-bin-path)/OnlyEQ_OnlyEQ.bundle"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/"
cp "$BIN" "$APP/Contents/MacOS/OnlyEQ"
[ -d "$RESOURCE_BUNDLE" ] && cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc sign so TCC (System Audio Recording) can track the app identity.
codesign --force --sign - "$APP"

echo "Built $APP"
