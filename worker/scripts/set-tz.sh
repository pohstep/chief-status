#!/bin/sh
# Ask for a time zone and write TZ in wrangler.toml.
# Usage, from the worker folder: ./scripts/set-tz.sh [America/Los_Angeles]

set -eu

cd "$(dirname "$0")/.."
file="wrangler.toml"

if [ "$#" -gt 1 ]; then
	echo "Usage: ./scripts/set-tz.sh [Time/Zone]" >&2
	exit 1
fi

if [ "$#" -eq 1 ]; then
	tz=$1
else
	printf "Time zone (for example America/Los_Angeles): "
	read -r tz
fi

case "$tz" in
*[!A-Za-z0-9_+/-]* | "" | /* | */ | */*/*)
	echo "Use a time zone like America/Los_Angeles or UTC." >&2
	exit 1
	;;
esac

if ! grep -q '^TZ = ' "$file"; then
	echo "Could not find TZ in wrangler.toml." >&2
	exit 1
fi

tmp="$(mktemp)"
awk -v tz="$tz" '
	/^TZ = / { print "TZ = \"" tz "\""; next }
	{ print }
' "$file" >"$tmp"
mv "$tmp" "$file"
echo "TZ is $tz"
