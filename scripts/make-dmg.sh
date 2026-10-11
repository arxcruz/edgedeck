#!/usr/bin/env bash
# Builds a universal, ad-hoc signed EdgeDeck.app and packs it into build/EdgeDeck-<version>.dmg
# (the app plus an Applications shortcut to drag it onto). Used by the release workflow; never
# signs with a personal certificate.
#
# VERSION=1.2.3 sets the app's version (default: the one in Resources/Info.plist).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)}
SIGN_IDENTITY=- ARCHS="arm64 x86_64" VERSION="$VERSION" NO_INSTALL=1 ./scripts/build.sh

STAGING=build/dmg
DMG="build/EdgeDeck-$VERSION.dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto build/EdgeDeck.app "$STAGING/EdgeDeck.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "EdgeDeck $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGING"
echo "Built $DMG"
