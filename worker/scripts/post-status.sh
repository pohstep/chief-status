#!/bin/sh
# Post one bot status line to the Chief Status feed.
#
#   export CHIEF_STATUS_URL="https://chief-status.<your-subdomain>.workers.dev"
#   export CHIEF_STATUS_TOKEN="the password you gave the worker"
#   export CHIEF_STATUS_BOT_URL="https://example.com/agent1"   # optional chat link
#   export CHIEF_STATUS_BOT_COLOR="#3B82F6"                    # optional #RRGGBB
#   ./post-status.sh Agent1 working "drafting the homepage"
#   ./post-status.sh Agent1 needs_input "approve the homepage copy" --approval
#
# started_at is sent for "working" and "needs_input". It is the job clock.
# The feed records last_posted_at itself, and the 404 uses that, so a long job
# that keeps posting does not go black. done, failed and idle let the feed keep
# the job clock, which is what today's durations are based on.
#
# STATUS is one of: idle, working, failed, done, needs_input
#   needs_input means the bot is waiting on you.
#   Add --approval, or set CHIEF_STATUS_APPROVAL=1, when it needs an approval
#   rather than an answer. The task text must say exactly what is needed:
#   the question, or the thing to approve. Do not leave it vague.
# The address can be the worker root or the full /status address.

set -eu

if [ "$#" -lt 3 ]; then
	echo "Usage: post-status.sh BOT STATUS TASK [--approval]" >&2
	echo "  STATUS is idle, working, failed, done, or needs_input" >&2
	echo "  needs_input: the task must say exactly what is needed." >&2
	echo "  --approval (or CHIEF_STATUS_APPROVAL=1) is only for needs_input." >&2
	echo "  Set CHIEF_STATUS_URL and CHIEF_STATUS_TOKEN first." >&2
	exit 1
fi

BOT=$1
STATUS=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
shift 2

# The env var only applies to a needs_input post. --approval on any other status is a mistake.
ENV_APPROVAL=0
case "$(printf '%s' "${CHIEF_STATUS_APPROVAL:-}" | tr '[:upper:]' '[:lower:]')" in
1 | true | yes | on) ENV_APPROVAL=1 ;;
esac
FLAG_APPROVAL=0

TASK=""
for arg in "$@"; do
	if [ "$arg" = "--approval" ]; then
		FLAG_APPROVAL=1
	else
		if [ -n "$TASK" ]; then
			TASK="$TASK $arg"
		else
			TASK=$arg
		fi
	fi
done

case "$STATUS" in
idle | working | failed | done | needs_input) ;;
*)
	echo "Status must be idle, working, failed, done, or needs_input." >&2
	exit 1
	;;
esac

if [ "$FLAG_APPROVAL" -eq 1 ] && [ "$STATUS" != "needs_input" ]; then
	echo "--approval is only for needs_input. The task must say exactly what is needed." >&2
	exit 1
fi

APPROVAL=0
if [ "$STATUS" = "needs_input" ]; then
	if [ "$FLAG_APPROVAL" -eq 1 ] || [ "$ENV_APPROVAL" -eq 1 ]; then
		APPROVAL=1
	fi
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

STARTED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

started_field=""
if [ "$STATUS" = "working" ] || [ "$STATUS" = "needs_input" ]; then
	started_field=$(printf ',"started_at":"%s"' "$STARTED")
fi
url_field=""
if [ -n "${CHIEF_STATUS_BOT_URL:-}" ]; then
	url_field=$(printf ',"url":"%s"' "$(escape "$CHIEF_STATUS_BOT_URL")")
fi
color_field=""
if [ -n "${CHIEF_STATUS_BOT_COLOR:-}" ]; then
	color_field=$(printf ',"color":"%s"' "$(escape "$CHIEF_STATUS_BOT_COLOR")")
fi
approval_field=""
if [ "$APPROVAL" -eq 1 ]; then
	approval_field=',"approval":true'
fi
BODY=$(printf '{"bot":"%s","status":"%s","task":"%s"%s%s%s%s}' \
	"$(escape "$BOT")" \
	"$(escape "$STATUS")" \
	"$(escape "$TASK")" \
	"$started_field" \
	"$url_field" \
	"$color_field" \
	"$approval_field")

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
