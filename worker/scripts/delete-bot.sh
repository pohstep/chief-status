#!/bin/sh
# Remove one bot (and its jobs for today) from the Chief Status feed.
#
#   export CHIEF_STATUS_URL="https://chief-status.<your-subdomain>.workers.dev"
#   export CHIEF_STATUS_TOKEN="the password you gave the worker"
#   ./delete-bot.sh Agent9
#
# It uses the same password as post-status.sh. A bot that posts again comes back.

set -eu

if [ "$#" -ne 1 ]; then
	echo "Usage: delete-bot.sh BOT" >&2
	echo "  Set CHIEF_STATUS_URL and CHIEF_STATUS_TOKEN first." >&2
	exit 1
fi

if [ -z "${CHIEF_STATUS_URL:-}" ]; then
	echo "Set CHIEF_STATUS_URL to your worker address." >&2
	exit 1
fi
if [ -z "${CHIEF_STATUS_TOKEN:-}" ]; then
	echo "Set CHIEF_STATUS_TOKEN to the worker password." >&2
	exit 1
fi

BASE=${CHIEF_STATUS_URL%/}
case "$BASE" in
*/status) URL=$BASE ;;
*) URL="$BASE/status" ;;
esac

# Percent-encode the name so spaces and quotes survive the path.
NAME=$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g')

tmp=$(mktemp)
code=$(curl -sS -o "$tmp" -w "%{http_code}" -X DELETE "$URL/$NAME" \
	-H "Authorization: Bearer ${CHIEF_STATUS_TOKEN}") || {
	rm -f "$tmp"
	echo "Couldn't reach the feed." >&2
	exit 1
}

cat "$tmp"
printf '\n'
rm -f "$tmp"

if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
	exit 1
fi
