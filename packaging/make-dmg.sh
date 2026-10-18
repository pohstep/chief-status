#!/bin/bash
# Build a universal Chief Status.app and pack it into a .dmg.
# The disk image holds the app and a shortcut to /Applications.
# Run this on a Mac with the Command Line Tools. It does not install the app.
# Usage: ./packaging/make-dmg.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(uname)" != "Darwin" ]; then
	echo "This builds the Mac app. Run it on a Mac."
	exit 1
fi

version="$(sw_vers -productVersion)"
major="${version%%.*}"
if [ "$major" -lt 13 ]; then
	echo "Chief Status needs macOS 13 or newer. This Mac is on ${version}."
	exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
	echo "Apple's command line tools are not installed yet."
	echo "Run this, click Install, wait until it finishes, then run this script again:"
	echo "  xcode-select --install"
	exit 1
fi

if ! command -v lipo >/dev/null 2>&1 || ! command -v hdiutil >/dev/null 2>&1; then
	echo "lipo and hdiutil come with the Command Line Tools. Install those, then try again."
	exit 1
fi

if command -v xcrun >/dev/null 2>&1; then
	SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
	export SDKROOT
fi

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/menubar/Info.plist")"

echo "Building Chief Status ${APP_VERSION} for Apple silicon and Intel."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

SOURCES=(
	"$ROOT/menubar/Sources/Config.swift"
	"$ROOT/menubar/Sources/Icon.swift"
	"$ROOT/menubar/Sources/StatusModel.swift"
	"$ROOT/menubar/Sources/PopoverView.swift"
	"$ROOT/menubar/Sources/main.swift"
)

compile_slice() {
	local arch="$1"
	local out="$2"
	swiftc \
		-target "${arch}-apple-macos13" \
		-O \
		-framework AppKit \
		-framework SwiftUI \
		-framework UserNotifications \
		-framework ServiceManagement \
		-o "$out" \
		"${SOURCES[@]}"
}

if ! compile_slice arm64 "$BUILD/ChiefStatus-arm64"; then
	echo "The Apple silicon build failed. The messages above are from the compiler."
	exit 1
fi
if ! compile_slice x86_64 "$BUILD/ChiefStatus-x86_64"; then
	echo "The Intel build failed. The messages above are from the compiler."
	exit 1
fi
lipo -create "$BUILD/ChiefStatus-arm64" "$BUILD/ChiefStatus-x86_64" -output "$BUILD/ChiefStatus"
echo "Universal binary:"
lipo -info "$BUILD/ChiefStatus"

APP="$BUILD/Chief Status.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/ChiefStatus" "$APP/Contents/MacOS/ChiefStatus"
chmod +x "$APP/Contents/MacOS/ChiefStatus"
cp "$ROOT/menubar/Info.plist" "$APP/Contents/Info.plist"

if command -v iconutil >/dev/null 2>&1 && [ -d "$ROOT/menubar/AppIcon.iconset" ]; then
	iconutil -c icns "$ROOT/menubar/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" || true
fi

codesign --force --sign - "$APP/Contents/MacOS/ChiefStatus"
codesign --force --sign - "$APP"
xattr -cr "$APP" 2>/dev/null || true

STAGE="$(mktemp -d)"
trap 'rm -rf "$BUILD" "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Chief Status.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$ROOT/dist"
DMG="$ROOT/dist/Chief-Status-${APP_VERSION}.dmg"
rm -f "$DMG"
hdiutil create \
	-volname "Chief Status" \
	-srcfolder "$STAGE" \
	-ov \
	-format UDZO \
	"$DMG"

echo
echo "Wrote ${DMG}"
echo "SHA-256 (paste this into packaging/homebrew/Casks/chief-status.rb before publishing the tap):"
shasum -a 256 "$DMG"
