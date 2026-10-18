#!/bin/bash
# Take Chief Status out of the menu bar and out of login items.
# The feed address file is left in place.

set -euo pipefail

APP="${HOME}/Applications/Chief Status.app"
PLIST="${HOME}/Library/LaunchAgents/com.chiefstatus.menubar.plist"
UID_NUM="$(id -u)"

launchctl bootout "gui/${UID_NUM}/com.chiefstatus.menubar" 2>/dev/null || true

if [ -d "$APP" ]; then
	old="$(pgrep -f "${APP}/Contents/MacOS/ChiefStatus" || true)"
	if [ -n "$old" ]; then
		kill $old 2>/dev/null || true
		sleep 0.3
	fi
	rm -rf "$APP"
fi

rm -f "$PLIST"

echo "Chief Status is no longer set to open at login."
echo "The feed address is still in:"
echo "  ${HOME}/Library/Application Support/Chief Status/config.plist"
