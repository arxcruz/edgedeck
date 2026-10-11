#!/usr/bin/env bash
# Builds build/EdgeDeck.app and installs it to /Applications.
#
# Signing: a stable identity keeps macOS privacy permissions (Accessibility) across
# rebuilds; ad-hoc signatures change every build, so the permission is lost each time.
# Uses $SIGN_IDENTITY if set ("-" for ad-hoc), else the first "Apple Development"
# certificate (created by signing in to Xcode with an Apple ID), else ad-hoc.
#
# ARCHS="arm64 x86_64" builds a universal app (default: this Mac's architecture).
# VERSION=1.2.3 sets the app's version (default: the one in Resources/Info.plist).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)
fi
echo "Signing with: ${SIGN_IDENTITY:-ad-hoc}"

ARCH_FLAGS=()
CLANG_ARCHS=()
for arch in ${ARCHS:-}; do ARCH_FLAGS+=(--arch "$arch"); CLANG_ARCHS+=(-arch "$arch"); done
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN=$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)
APP=build/EdgeDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/EdgeDeck" "$APP/Contents/MacOS/EdgeDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
# App icon, drawn by scripts/make-icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Now Playing helper, loaded into /usr/bin/perl at runtime (see Helpers/EdgeDeckMedia.m).
clang ${CLANG_ARCHS[@]+"${CLANG_ARCHS[@]}"} -dynamiclib -O2 -fobjc-arc -framework Foundation Helpers/EdgeDeckMedia.m \
    -o "$APP/Contents/Resources/EdgeDeckMedia.dylib"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

# Install to /Applications, so Open at Login always points at the same copy.
# NO_INSTALL=1 skips it (e.g. for snapshot runs).
if [ "${NO_INSTALL:-}" != 1 ]; then
    rm -rf /Applications/EdgeDeck.app
    ditto "$APP" /Applications/EdgeDeck.app
    echo "Installed /Applications/EdgeDeck.app"
fi
