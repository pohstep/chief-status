#!/bin/bash
# Build Chief Status, put it in ~/Applications, and open it at login.
# Usage: ./install.sh [https://your-worker.workers.dev/status]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -gt 1 ]; then
	echo "Usage: ./install.sh [feed-address]"
	exit 1
fi

if [ "$(uname)" != "Darwin" ]; then
	echo "This installs the menu bar app on a Mac. The feed itself is deployed from the worker folder."
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
	echo "Run this, click Install, wait until it finishes, then run ./install.sh again:"
	echo "  xcode-select --install"
	exit 1
fi

if command -v xcrun >/dev/null 2>&1; then
	SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
	export SDKROOT
fi

xml_escape() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

normalize_feed() {
	feed=$(printf '%s' "$1" | tr -d '[:space:]')
	case "$feed" in
	http://* | https://*) ;;
	*)
		echo "The address needs to start with https://" >&2
		exit 1
		;;
	esac
	feed="${feed%/}"
	case "$feed" in
	*/status) ;;
	*) feed="${feed}/status" ;;
	esac
	printf '%s' "$feed"
}

CONFIG_DIR="${HOME}/Library/Application Support/Chief Status"
CONFIG="${CONFIG_DIR}/config.plist"
mkdir -p "$CONFIG_DIR"

write_plist() {
	escaped="$(xml_escape "$1")"
	# Re-running install with an address must not turn a saved alert back off.
	alert="false"
	if [ -f "$CONFIG" ] && grep -A1 "<key>alertOnFailure</key>" "$CONFIG" | grep -q "<true/>"; then
		alert="true"
	fi
	cat >"$CONFIG" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>feedURL</key>
	<string>${escaped}</string>
	<key>alertOnFailure</key>
	<${alert}/>
</dict>
</plist>
EOF
}

if [ "$#" -eq 1 ]; then
	write_plist "$(normalize_feed "$1")"
fi

echo "Building Chief Status for Apple silicon and Intel. This can take a minute."
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

DEST="${HOME}/Applications/Chief Status.app"
mkdir -p "${HOME}/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
codesign --force --sign - "$DEST/Contents/MacOS/ChiefStatus"
codesign --force --sign - "$DEST"

# Open at login is Settings → Open at login inside the app.
# An older install.sh wrote ~/Library/LaunchAgents/com.chiefstatus.menubar.plist,
# which kept starting the app after that switch was turned off. Remove it.
UID_NUM="$(id -u)"
OLD_PLIST="${HOME}/Library/LaunchAgents/com.chiefstatus.menubar.plist"
launchctl bootout "gui/${UID_NUM}/com.chiefstatus.menubar" 2>/dev/null || true
rm -f "$OLD_PLIST"

old="$(pgrep -f "${DEST}/Contents/MacOS/ChiefStatus" || true)"
if [ -n "$old" ]; then
	kill $old 2>/dev/null || true
	sleep 0.4
fi

open "$DEST" || true

sleep 1
echo
if pgrep -f "${DEST}/Contents/MacOS/ChiefStatus" >/dev/null; then
	echo "Chief Status is in the menu bar."
else
	echo "Chief Status is installed. If you don't see the face, open Chief Status from Applications."
fi
echo
echo "Grey means everyone is idle or finished."
echo "Orange means someone is working."
echo "Red means someone failed."
echo "Click the face to see the list."
echo
if [ -f "$CONFIG" ]; then
	echo "The feed address is in:"
	echo "  ${CONFIG}"
	if grep -q "REPLACE-ME" "$CONFIG"; then
		echo
		echo "That file still has a placeholder address."
		echo "Click the face and paste the real one."
	fi
else
	echo "Click the face and paste your feed address."
	echo "Or run ./install.sh again with the address on the end."
fi
echo
echo "To open it every time you log in, click the cube, open Settings, and turn on Open at login."
