#!/bin/sh
# Post one bot status line to the Chief Status feed.
#
#   export CHIEF_STATUS_URL="https://chief-status.<your-subdomain>.workers.dev"
#   export CHIEF_STATUS_TOKEN="the password you gave the worker"
#   ./post-status.sh Agent1 working "drafting the homepage"
#
# STATUS is one of: idle, working, failed, done
# The address can be the worker root or the full /status address.

set -eu

if [ "$#" -lt 3 ]; then
	echo "Usage: post-status.sh BOT STATUS TASK" >&2
	echo "  STATUS is idle, working, failed, or done" >&2
	echo "  Set CHIEF_STATUS_URL and CHIEF_STATUS_TOKEN first." >&2
	exit 1
fi

BOT=$1
STATUS=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
shift 2
TASK=$*

case "$STATUS" in
idle | working | failed | done) ;;
*)
	echo "Status must be idle, working, failed, or done." >&2
	exit 1
	;;
esac

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

STARTED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

BODY=$(printf '{"bot":"%s","status":"%s","task":"%s","started_at":"%s"}' \
	"$(escape "$BOT")" \
	"$(escape "$STATUS")" \
	"$(escape "$TASK")" \
	"$STARTED")

tmp=$(mktemp)
code=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$URL" \
	-H "Authorization: Bearer ${CHIEF_STATUS_TOKEN}" \
	-H "Content-Type: application/json" \
	--data "$BODY") || {
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
